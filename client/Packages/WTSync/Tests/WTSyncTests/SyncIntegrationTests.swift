import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// Two sync clients against the real compose server (`docker compose up -d`): pipelined pushes,
/// a bulk upload and convergence.  Runs only with `WT_SYNC_IT=1`; the API at `WT_SYNC_API`
/// (default http://localhost:8080) and Keycloak at `WT_SYNC_KEYCLOAK` (default
/// http://localhost:8180) must be up.  Signs in as the compose realm's `alice`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WT_SYNC_IT"] == "1"), .timeLimit(.minutes(5)))
struct SyncIntegrationTests {
    static let environment = ProcessInfo.processInfo.environment
    static let api = URL(string: environment["WT_SYNC_API"] ?? "http://localhost:8080")!
    static let keycloak = URL(string: environment["WT_SYNC_KEYCLOAK"] ?? "http://localhost:8180")!
    /// The server refuses a `wt-device` that is not a UUID (TEST-001 finding d); both peers are
    /// this one test device.
    static let identity = GRPCSyncTransport<HTTP2ClientTransport.Posix>.Identity(clientVersion: "0.0.1/1",
                                                                                 deviceID: "5ec0a1b2-7e57-4d0e-9a1c-000000000001")

    /// Resource-owner password grant against the compose realm (the `wiretuner-mac` client allows
    /// it), shared by both peers and retried: Keycloak answers concurrent grants unevenly.
    actor PasswordTokens: TokenProvider {
        static let shared = PasswordTokens()
        private var token: String?

        func accessToken(forceRefresh: Bool) async throws -> String {
            if let token, !forceRefresh { return token }
            var request = URLRequest(url: SyncIntegrationTests.keycloak.appending(path: "realms/wiretuner/protocol/openid-connect/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("grant_type=password&client_id=wiretuner-mac&username=alice&password=testpass&scope=openid".utf8)
            for _ in 0..<5 {
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let fresh = json?["access_token"] as? String {
                    token = fresh
                    return fresh
                }
                print("token grant refused: \(String(decoding: data, as: UTF8.self))")
                try await Task.sleep(for: .milliseconds(500))
            }
            throw TokenFailure.signInRequired
        }
    }

    static func uuidV7() -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> (8 * (5 - index))) & 0xFF)
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }

    /// Creates a document in alice's own space and returns its id.
    static func createDocument(token: String) async throws -> String {
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: api.host!, port: api.port ?? 80), transportSecurity: .plaintext)
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        return try await withGRPCClient(transport: transport) { client in
            let me = try await Wiretuner_Account_V1_AccountService.Client(wrapping: client)
                .me(Wiretuner_Account_V1_MeRequest(), metadata: metadata)
            var create = Wiretuner_Docs_V1_CreateRequest()
            create.documentID = uuidV7()
            create.spaceID = me.account.id
            create.name = "Sync integration \(Date())"
            let created = try await Wiretuner_Docs_V1_DocumentService.Client(wrapping: client).create(create, metadata: metadata)
            return created.document.id.isEmpty ? create.documentID : created.document.id
        }
    }

    struct Peer {
        let store: LocalStore
        let transport: GRPCSyncTransport<HTTP2ClientTransport.Posix>
        let client: SyncClient

        init(documentID: String, url: URL, replicas: Replicas) async throws {
            store = try await LocalStore.open(documentID: documentID, at: url, options: options(replicas: replicas))
            transport = try GRPCSyncTransport.http2(api: SyncIntegrationTests.api, identity: SyncIntegrationTests.identity)
            client = SyncClient(store: store, transport: transport, tokens: PasswordTokens.shared)
        }

        func edit(_ count: Int, from start: Int) async throws {
            for index in start..<(start + count) {
                _ = try await store.perform(createLayer("IT\(index)"), recording: Fixture.recording())
            }
            await client.localChangesAvailable()
        }

        func close() async throws {
            await client.stop()
            await transport.close()
            try await store.close()
        }
    }

    @Test func twoClientsConvergeThroughTheComposeServer() async throws {
        let scratch = Scratch()
        let documentID = try await Self.createDocument(token: try await PasswordTokens.shared.accessToken(forceRefresh: false))
        let seed = UInt64.random(in: 1_000...UInt64(1) << 40)
        let a = try await Peer(documentID: documentID, url: scratch.url("a"), replicas: Replicas(from: seed))
        let b = try await Peer(documentID: documentID, url: scratch.url("b"), replicas: Replicas(from: seed + 1_000))
        let trailA = Collector(a.client.transitions())
        let trailB = Collector(b.client.transitions())
        await a.client.start()
        await b.client.start()
        do {
            try await eventually("both sessions up", timeout: .seconds(60)) {
                let stateA = await a.client.state
                let stateB = await b.client.state
                return stateA == .saved && stateB == .saved
            }
        } catch {
            Issue.record("A: \(trailA.all.map { "\($0.to) (\($0.cause))" }) B: \(trailB.all.map { "\($0.to) (\($0.cause))" })")
            throw error
        }
        let start = ContinuousClock.now
        try await a.edit(40, from: 0)          // pipelined PushChange
        try await b.edit(10, from: 100)
        try await a.edit(250, from: 1_000)     // over the bulk threshold: PushChanges
        try await eventually("converged", timeout: .seconds(120)) {
            let outboxA = try await a.store.outboxCount()
            let outboxB = try await b.store.outboxCount()
            let seqA = await a.store.lastServerSeq
            let seqB = await b.store.lastServerSeq
            return outboxA == 0 && outboxB == 0 && seqA == seqB && seqA >= 300
        }
        let hashA = await a.store.read { $0.stateHash }
        let hashB = await b.store.read { $0.stateHash }
        #expect(hashA == hashB)
        #expect(await a.store.lastServerSeq == 300)
        print("sync integration: 300 changes from two clients converged in \(ContinuousClock.now - start)")
        try await a.close()
        try await b.close()
    }
}
