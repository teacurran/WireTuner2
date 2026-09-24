import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Testing
import WTCRDT
import WTModel
import WTProto
import WTSync
@testable import WTTestSupport

/// The simulator against the compose server (docs/spec/testing.adoc, "Multi-client simulation"):
/// the same clients and network proxies, with `GRPCSyncTransport` behind each proxy instead of the
/// in-process server's wire.  Runs only with `WT_SIM_COMPOSE=1` and `docker compose up -d`; the API
/// at `WT_SYNC_API` (default http://localhost:8080) and Keycloak at `WT_SYNC_KEYCLOAK` (default
/// http://localhost:8180).  Every client signs in as the compose realm's `alice`, each from its
/// own device.  `WT_SIM_COMPOSE_RESTART=1` also restarts the api and valkey containers mid-run
/// (`docker compose restart`), which needs the `docker` CLI on the PATH.
///
/// The checks read the clients only -- the compose server's log is not read -- and the scenarios
/// that need the server scripted (retirement, roles, token lifetimes, a Postgres failover, which
/// the compose stack has no replica for) run against the in-process server only.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WT_SIM_COMPOSE"] == "1"), .serialized, .timeLimit(.minutes(10)))
struct ComposeSimulationTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let api = URL(string: environment["WT_SYNC_API"] ?? "http://localhost:8080")!
    nonisolated static let keycloak = URL(string: environment["WT_SYNC_KEYCLOAK"] ?? "http://localhost:8180")!
    nonisolated static let alice = SimUser(id: "alice", name: "alice")

    /// Resource-owner password grant against the compose realm, shared by every client and
    /// retried (Keycloak answers concurrent grants unevenly).
    actor PasswordTokens: TokenProvider {
        static let shared = PasswordTokens()
        private var token: String?

        func accessToken(forceRefresh: Bool) async throws -> String {
            if let token, !forceRefresh { return token }
            var request = URLRequest(url: ComposeSimulationTests.keycloak.appending(path: "realms/wiretuner/protocol/openid-connect/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("grant_type=password&client_id=wiretuner-mac&username=alice&password=testpass&scope=openid".utf8)
            for _ in 0..<5 {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let fresh = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String {
                    token = fresh
                    return fresh
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw TokenFailure.signInRequired
        }
    }

    /// The shared tokens, refused while the client's link is cut.
    struct LinkedTokens: TokenProvider {
        let link: NetworkLink

        func accessToken(forceRefresh: Bool) async throws -> String {
            guard !link.isPartitioned else { throw URLError(.notConnectedToInternet) }
            return try await PasswordTokens.shared.accessToken(forceRefresh: forceRefresh)
        }
    }

    nonisolated static func uuidV7() -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> (8 * (5 - index))) & 0xFF)
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            .joined(separator: "-")
    }

    /// A new document in alice's own space.
    nonisolated static func createDocument() async throws -> String {
        let token = try await PasswordTokens.shared.accessToken(forceRefresh: false)
        let transport = try HTTP2ClientTransport.Posix(target: .dns(host: api.host!, port: api.port ?? 80), transportSecurity: .plaintext)
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/0.0.1/1", forKey: "wt-client")
        metadata.addString(Simulation.deviceID(for: "simulation"), forKey: "wt-device")
        return try await withGRPCClient(transport: transport) { client in
            let me = try await Wiretuner_Account_V1_AccountService.Client(wrapping: client).me(Wiretuner_Account_V1_MeRequest(), metadata: metadata)
            var create = Wiretuner_Docs_V1_CreateRequest()
            create.documentID = uuidV7()
            create.spaceID = me.account.id
            create.name = "Simulation \(Date())"
            let created = try await Wiretuner_Docs_V1_DocumentService.Client(wrapping: client).create(create, metadata: metadata)
            return created.document.id.isEmpty ? create.documentID : created.document.id
        }
    }

    nonisolated static func backend(_ clock: SimClock) -> SimulationBackend {
        SimulationBackend(
            name: "compose",
            // Each client's own device, the UUID `Simulation.deviceID(for:)` derived (the server
            // refuses a `wt-device` that is not a UUID).
            upstream: { _, device in
                try GRPCSyncTransport.http2(api: api, identity: .init(clientVersion: "0.0.1/1", deviceID: device))
            },
            tokens: { _, link, _ in LinkedTokens(link: link) },
            createDocument: { _ in try await createDocument() },
            setRole: { _, _, _ in throw Simulation.Failure(description: "roles are not scripted against the compose server") })
    }

    static func simulation(_ name: String, seed: UInt64) async throws -> Simulation {
        try await Simulation(name: name, seed: Simulation.seed(seed), scale: 0.01, owner: alice) { backend($0) }
    }

    /// `docker compose restart <service>` from the repository root.
    static func restart(_ service: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose", "restart", service]
        process.currentDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../../..").standardized
        try process.run()
        process.waitUntilExit()
    }

    /// Scenario 1 against the compose server: three people on one path with 200 ms latency and
    /// reordered pipelined pushes (native) or batches (gateway).
    @Test(arguments: PushMode.allCases) func threeUsersEditOnePath(mode: PushMode) async throws {
        let sim = try await Self.simulation("compose-one-path-\(mode)", seed: 111)
        defer { Task { await sim.shutdown() } }
        let conditions = LinkConditions(latency: .milliseconds(200), jitter: .milliseconds(80), reorder: 0.35,
                                        reorderWindow: .milliseconds(900), streamDrop: 0.004)
        var people: [SimClient] = []
        for name in ["ana", "ben", "cy"] {
            people.append(try await sim.addClient(name, user: Self.alice, gateway: mode.gateway, conditions: conditions))
        }
        let path = try await Workload.createPath(people[0], points: 12)
        try await sim.settle()
        var random = sim.random.fork(1)
        let restarts = Self.environment["WT_SIM_COMPOSE_RESTART"] == "1"
        try await sim.steps(100, every: .seconds(3)) { step in
            for person in people where random.chance(0.8) {
                for _ in 0..<random.within(1...3) { await Workload.editPath(person, path.node, &random) }
            }
            if restarts && step == 30 { try Self.restart("api") }
            if restarts && step == 60 { try Self.restart("valkey") }
        }
        try await sim.settle(timeout: .seconds(180))
        try await sim.expectConverged()
        print(await sim.summary())
    }

    /// Scenario 4 against the compose server: a cloned store on another device draws the real
    /// server's `REPLICA_CONFLICT` and rotates; no id collides.
    @Test func aClonedStoreRotates() async throws {
        let sim = try await Self.simulation("compose-clone", seed: 444)
        defer { Task { await sim.shutdown() } }
        let ana = try await sim.addClient("ana", user: Self.alice)
        let shapes = try await Workload.createShapes(ana, count: 5)
        try await sim.settle()
        ana.goOffline()
        var random = sim.random.fork(4)
        for _ in 0..<3 { await Workload.move(ana, shapes, &random) }
        let clone = try sim.copyStore(of: ana, as: "clone")
        let replica = await ana.store.replica
        ana.goOnline()
        try await sim.settle([ana])
        let cloned = try await sim.addClient("ana-clone", user: Self.alice, device: "clone", hardware: "MAC-ana", store: clone)
        await Workload.move(cloned, [shapes[0]], &random)
        try await sim.settle(timeout: .seconds(120))
        try await sim.expectConverged()
        #expect(cloned.events.contains { if case .replicaRotated(replica, _) = $0 { true } else { false } })
    }
}
