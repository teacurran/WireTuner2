import Foundation
import SwiftProtobuf
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// DATA-010's client half: `DataSourceClient` over `DataSourceService` -- paged fetches resumed
/// from their cursor, the offline cache, assets, `wt.fetch` with the consent rule, credentials
/// and hosts -- and `GRPCDataSourceTransport` end to end over the in-process transport.
@Suite(.timeLimit(.minutes(2))) struct DataSourceClientTests {
    /// A `DataSourceService` in memory: `pages` pages of two records each; `dropAfter` drops the
    /// stream (UNAVAILABLE) after that many pages of the first call.
    final class FakeData: DataSourceTransport, Sendable {
        struct State {
            var pages = 3
            var dropAfter: Int?
            var fetches: [Wiretuner_Data_V1_FetchRequest] = []
            var proxies: [Wiretuner_Data_V1_ProxyRequest] = []
            var allowed: Set<String> = ["api.example.com"]
            var tokens: [String] = []
            var failure: (any Error)?
            var credentials: [String: Wiretuner_Data_V1_Credential] = [:]
        }

        let state = Mutex(State())

        private func check(_ token: String) throws {
            try state.withLock { state in
                state.tokens.append(token)
                if let failure = state.failure { throw failure }
            }
        }

        func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
            let (pages, drop, failure) = state.withLock { state -> (Int, Int?, (any Error)?) in
                state.fetches.append(request)
                let drop = state.dropAfter
                state.dropAfter = nil
                return (state.pages, drop, state.failure)
            }
            return AsyncThrowingStream { continuation in
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                let start = Int(request.cursor) ?? 0
                for page in start..<pages {
                    if let drop, page - start == drop {
                        continuation.finish(throwing: SyncCallError(code: SyncCallError.unavailable, message: "gone"))
                        return
                    }
                    continuation.yield(.with { $0.progress = .with { $0.pageNumber = UInt32(page + 1); $0.records = UInt64(page * 2) } })
                    continuation.yield(.with { response in
                        response.page.pageNumber = UInt32(page + 1)
                        response.page.records = (0..<2).map { index in .with { $0.values = ["name": "r\(page * 2 + index)"] } }
                        response.page.nextCursor = page + 1 < pages ? String(page + 1) : ""
                    })
                }
                continuation.yield(Wiretuner_Data_V1_FetchResponse())
                continuation.finish()
            }
        }

        func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse {
            try check(token)
            return .with { $0.blobSha256 = Data(repeating: 1, count: 32); $0.mediaType = "image/png"; $0.size = UInt64(request.url.count) }
        }

        func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse {
            try check(token)
            let host = URL(string: request.url)?.host ?? ""
            let allowed = state.withLock { state in
                state.proxies.append(request)
                return state.allowed.contains(host)
            }
            guard allowed else { throw DataServiceError.hostNotAllowed(host: host, admins: "") }
            return .with { $0.status = 200; $0.headers = ["content-type": "application/json"]; $0.body = Data("{\"ok\":true}".utf8) }
        }

        func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse {
            try check(token)
            return state.withLock { state in
                let all = state.credentials.values.sorted { $0.name < $1.name }
                let start = Int(request.cursor) ?? 0
                var response = Wiretuner_Data_V1_ListCredentialsResponse()
                if start < all.count {
                    response.credentials = [all[start]]
                    response.nextCursor = start + 1 < all.count ? String(start + 1) : ""
                }
                return response
            }
        }

        func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse {
            try check(token)
            let credential = Wiretuner_Data_V1_Credential.with { $0.name = request.name; $0.kind = request.kind; $0.host = request.host }
            state.withLock { $0.credentials[request.name] = credential }
            return .with { $0.credential = credential }
        }

        func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse {
            try check(token)
            return .with { response in response.deleted = state.withLock { $0.credentials.removeValue(forKey: request.name) != nil } }
        }

        func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse {
            try check(token)
            return state.withLock { state in
                let all = state.allowed.sorted()
                let start = Int(request.cursor) ?? 0
                var response = Wiretuner_Data_V1_ListAllowedHostsResponse()
                if start < all.count {
                    response.hosts = [.with { $0.host = all[start] }]
                    response.nextCursor = start + 1 < all.count ? String(start + 1) : ""
                }
                return response
            }
        }

        func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse {
            try check(token)
            state.withLock { _ = $0.allowed.insert(request.host) }
            return .with { $0.host.host = request.host }
        }

        func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse {
            try check(token)
            return .with { response in response.deleted = state.withLock { $0.allowed.remove(request.host) != nil } }
        }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "wt-datasource-\(UUID().uuidString)")
    }

    /// A document with fields `name` and `city` (mapped to `$.address.city`) and an HTTP source.
    static func document() throws -> (DataModel, DataSourceInfo) {
        var core = DocumentCore(state: EngineState(), replica: 0xA)
        let recording = DocumentCore.Recording(limit: 10, now: Date())
        _ = try core.perform(AddFields([.init("name"), .init("city"), .init("name2")]), recording: recording)
        _ = try core.perform(AddSource(name: "API", kind: .http) { $0.http.url = "https://api.example.com/people" }, recording: recording)
        var model = DataModel(core.state)
        _ = try core.perform(SetMapping(model.activeSource!.id, field: model.fields[1].id, path: "$.address.city"), recording: recording)
        _ = try core.perform(SetMapping(model.activeSource!.id, field: model.fields[2].id, path: "name"), recording: recording)
        model = DataModel(core.state)
        return (model, model.activeSource!)
    }

    @Test func fetchStreamsPagesResumesAndCaches() async throws {
        let fake = FakeData()
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = DataSourceClient(transport: fake, directory: directory, token: { "tok" })
        let (model, source) = try Self.document()
        let request = DataSourceClient.request(documentID: "doc-1", source: source, model: model, params: ["since": "2026"])
        #expect(request.paths == ["name", "$.address.city"] && request.params == ["since": "2026"] && request.source.timeoutS == 30)
        // A drop after page 2 resumes from its cursor: no record repeated or missed.
        fake.state.withLock { $0.dropAfter = 2 }
        var records: [String] = []
        var events: [DataFetchEvent] = []
        for try await event in await client.fetch(request) {
            events.append(event)
            if case .page(let page, _) = event { records += page.compactMap { $0["name"] } }
        }
        #expect(records == ["r0", "r1", "r2", "r3", "r4", "r5"] && events.contains(.resumed(attempt: 1)))
        #expect(fake.state.withLock { $0.fetches.map(\.cursor) } == ["", "2"])
        #expect(events.contains { if case .progress = $0 { true } else { false } })
        // fetchAll caches; the cache answers offline.
        let table = try await client.fetchAll(documentID: "doc-1", source: source, model: model)
        #expect(table.records.count == 6 && table.columns == ["name", "$.address.city"])
        #expect(await client.cachedRecords(documentID: "doc-1", source: source.id)?.records.count == 6)
        await client.forget(documentID: "doc-1", source: source.id)
        #expect(await client.cachedRecords(documentID: "doc-1", source: source.id) == nil)
        // Offline before any page: fails with offline (nothing to resume).
        fake.state.withLock { $0.failure = SyncCallError(code: SyncCallError.unavailable, message: "down") }
        await #expect(throws: DataServiceError.offline) { for try await _ in await client.fetch(request) {} }
        // A rejection ends the stream with its mapped error.
        fake.state.withLock { $0.failure = SyncCallError(code: 7, reason: .hostNotAllowed, message: "no") }
        await #expect(throws: DataServiceError.hostNotAllowed(host: "", admins: "")) { for try await _ in await client.fetch(request) {} }
        // Resumes are capped.
        fake.state.withLock { $0.failure = nil }
        let stubborn = DataSourceClient(transport: Dropping(), directory: directory, maxResumes: 2, token: { "tok" })
        await #expect(throws: DataServiceError.offline) { for try await _ in await stubborn.fetch(request) {} }
        #expect(try DataSourceClient.defaultDirectory().path.hasSuffix("WireTuner/DataSources"))
    }

    /// Every stream yields one page, then drops.
    final class Dropping: DataSourceTransport, Sendable {
        func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.with { $0.page.nextCursor = "more" })
                continuation.finish(throwing: DataServiceError.offline)
            }
        }
        func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse { .init() }
        func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse { throw URLError(.badURL) }
        func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse { .init() }
        func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse { .init() }
        func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse { .init() }
        func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse { .init() }
        func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse { .init() }
        func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse { .init() }
    }

    @Test func assetsProxyCredentialsAndHosts() async throws {
        let fake = FakeData()
        let client = DataSourceClient(transport: fake, directory: Self.directory(), token: { "tok" })
        let asset = try await client.fetchAsset(documentID: "doc-1", url: "https://img.example.com/a.png", credential: "cdn")
        #expect(asset.blobSha256.count == 32 && asset.size == 29)
        let response = try await client.proxy(documentID: "doc-1", ScriptFetchRequest(method: "POST", url: "https://api.example.com/x", headers: ["A": "1"],
                                                                                        body: Data("b".utf8), credential: "api", timeout: 500))
        #expect(response.status == 200 && response.body == Data("{\"ok\":true}".utf8))
        let sent = try #require(fake.state.withLock { $0.proxies.last })
        #expect(sent.method == "POST" && sent.headers == ["A": "1"] && sent.credentialName == "api" && sent.timeoutS == 120 && sent.documentID == "doc-1")
        // Credentials: put, list (paged), delete; secrets never come back.
        for name in ["b", "a"] {
            let put = try await client.putCredential(.with { $0.name = name; $0.kind = .bearer; $0.host = "api.example.com"; $0.token = "secret" })
            #expect(put.name == name)
        }
        #expect(try await client.credentials(documentID: "doc-1").map(\.name) == ["a", "b"])
        var scope = Wiretuner_Data_V1_Scope()
        scope.teamID = "team"
        #expect(try await client.deleteCredential(scope: scope, name: "a"))
        #expect(try await !client.deleteCredential(scope: scope, name: "a"))
        // Hosts.
        try await client.putAllowedHost(scope: scope, host: "b.example.com")
        #expect(try await client.allowedHosts(documentID: "doc-1").map(\.host) == ["api.example.com", "b.example.com"])
        #expect(try await client.deleteAllowedHost(scope: scope, host: "b.example.com"))
        // A token failure or rejection is mapped.
        fake.state.withLock { $0.failure = SyncCallError(code: 8, message: "slow down", retryAfter: .seconds(2)) }
        await #expect(throws: DataServiceError.rateLimited(retryAfter: .seconds(2))) { try await client.fetchAsset(documentID: "d", url: "https://x") }
        let broken = DataSourceClient(transport: fake, directory: Self.directory(), token: { throw TokenFailure.signInRequired })
        await #expect(throws: DataServiceError.self) { try await broken.credentials(documentID: "d") }
        #expect(fake.state.withLock { $0.tokens }.allSatisfy { $0 == "tok" })
    }

    @Test func errorMapping() {
        #expect(DataServiceError.from(SyncCallError(code: 7, reason: .hostNotAllowed), metadata: ["host": "h", "admins": "A, B"]) == .hostNotAllowed(host: "h", admins: "A, B"))
        #expect(DataServiceError.from(SyncCallError(code: 5, reason: .credentialMissing)) == .credentialMissing)
        #expect(DataServiceError.from(SyncCallError(code: 9, reason: .responseTooLarge)) == .responseTooLarge)
        #expect(DataServiceError.from(SyncCallError(code: 14, reason: .upstreamError, message: "tls")) == .upstream("tls"))
        #expect(DataServiceError.from(SyncCallError(code: 14)) == .offline)
        #expect(DataServiceError.from(SyncCallError(code: 3, message: "bad")) == .rejected(code: 3, message: "bad"))
        if case .rejected(let code, _) = DataServiceError.from(URLError(.badURL) as any Error) { #expect(code == 2) } else { Issue.record("rejected") }
        #expect(DataServiceError.from(DataServiceError.offline as any Error) == .offline)
        let cases: [(DataServiceError, ScriptFetchError)] = [
            (.offline, .offline), (.hostNotAllowed(host: "h", admins: "a"), .hostNotAllowed(host: "h", admins: "a")), (.credentialMissing, .credentialMissing("")),
            (.responseTooLarge, .responseTooLarge), (.upstream("u"), .upstream("u")), (.rateLimited(retryAfter: .milliseconds(1500)), .rateLimited(retryAfter: 1.5)),
            (.rateLimited(retryAfter: nil), .rateLimited(retryAfter: nil)), (.rejected(code: 1, message: "m"), .failed("m")),
        ]
        for (error, script) in cases { #expect(error.scriptError == script) }
        #expect(DataSourceClient.key("a/b-1", OpID(counter: 2, replica: 3)) == "ab-1-2-3")
    }

    @Test func scriptFetcherConsentsOncePerHostOnPersonalDocuments() async throws {
        let fake = FakeData()
        let client = DataSourceClient(transport: fake, directory: Self.directory(), token: { "tok" })
        let asked = Mutex<[String]>([])
        let fetcher = DataScriptFetcher(client: client, documentID: "doc-1", personalAccount: "acct-1") { host in
            asked.withLock { $0.append(host) }
            return true
        }
        let results = try await Task.detached {
            (try fetcher.fetch(ScriptFetchRequest(url: "https://new.example.com/a")), try fetcher.fetch(ScriptFetchRequest(url: "https://new.example.com/b")))
        }.value
        #expect(results.0.status == 200 && results.1.status == 200 && asked.withLock { $0 } == ["new.example.com"])
        #expect(fake.state.withLock { $0.allowed.contains("new.example.com") })
        // Denied: the fetch fails with the documented message; a team document never asks.
        let denying = DataScriptFetcher(client: client, documentID: "doc-1", personalAccount: "acct-1") { _ in false }
        let team = DataScriptFetcher(client: client, documentID: "doc-1", personalAccount: nil) { _ in
            Issue.record("a team document never shows the consent sheet")
            return true
        }
        for fetcher in [denying, team] {
            let error = await Task.detached { () -> (any Error)? in
                do { _ = try fetcher.fetch(ScriptFetchRequest(url: "https://other.example.com")); return nil } catch { return error }
            }.value
            #expect(error as? ScriptFetchError == .hostNotAllowed(host: "other.example.com", admins: ""))
        }
        // Allowed but the retry fails: the retry's error.
        let flaky = DataScriptFetcher(client: DataSourceClient(transport: RetryFails(), directory: Self.directory(), token: { "t" }), documentID: "d",
                                      personalAccount: "a") { _ in true }
        let flakyError = await Task.detached { () -> (any Error)? in
            do { _ = try flaky.fetch(ScriptFetchRequest(url: "https://x.example.com")); return nil } catch { return error }
        }.value
        #expect(flakyError as? ScriptFetchError == .offline)
    }

    /// Refuses the host, then is offline for the permit.
    final class RetryFails: DataSourceTransport, Sendable {
        func fetch(_ request: Wiretuner_Data_V1_FetchRequest, token: String) -> AsyncThrowingStream<Wiretuner_Data_V1_FetchResponse, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func fetchAsset(_ request: Wiretuner_Data_V1_FetchAssetRequest, token: String) async throws -> Wiretuner_Data_V1_FetchAssetResponse { .init() }
        func proxy(_ request: Wiretuner_Data_V1_ProxyRequest, token: String) async throws -> Wiretuner_Data_V1_ProxyResponse {
            throw DataServiceError.hostNotAllowed(host: "x.example.com", admins: "")
        }
        func listCredentials(_ request: Wiretuner_Data_V1_ListCredentialsRequest, token: String) async throws -> Wiretuner_Data_V1_ListCredentialsResponse { .init() }
        func putCredential(_ request: Wiretuner_Data_V1_PutCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_PutCredentialResponse { .init() }
        func deleteCredential(_ request: Wiretuner_Data_V1_DeleteCredentialRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteCredentialResponse { .init() }
        func listAllowedHosts(_ request: Wiretuner_Data_V1_ListAllowedHostsRequest, token: String) async throws -> Wiretuner_Data_V1_ListAllowedHostsResponse { .init() }
        func putAllowedHost(_ request: Wiretuner_Data_V1_PutAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_PutAllowedHostResponse {
            throw SyncCallError(code: SyncCallError.unavailable)
        }
        func deleteAllowedHost(_ request: Wiretuner_Data_V1_DeleteAllowedHostRequest, token: String) async throws -> Wiretuner_Data_V1_DeleteAllowedHostResponse { .init() }
    }

    @Test func scriptRunsFetchThroughTheService() async throws {
        let fake = FakeData()
        let client = DataSourceClient(transport: fake, directory: Self.directory(), token: { "tok" })
        let fetcher = DataScriptFetcher(client: client, documentID: "doc-1", personalAccount: nil)
        let target = CoreScriptTarget(DocumentCore(state: EngineState(), replica: 0xA))
        let result = await ScriptRunner(limits: ScriptLimits(wallClock: 10, memory: 1 << 30)).runDetached("""
        const res = await wt.fetch("https://api.example.com/data", { credential: "api" });
        console.log(res.status, (await res.json()).ok);
        """, name: "Fetch", target: target, fetcher: fetcher)
        #expect(result.error == nil && result.console.last?.text == "200 true" && result.hosts == ["api.example.com"])
        #expect(fake.state.withLock { $0.proxies.first?.credentialName } == "api")
    }

    // MARK: gRPC

    typealias Method = Wiretuner_Data_V1_DataSourceService.Method

    static func router(_ fake: FakeData, calls: FakeGRPCService.Calls) -> RPCRouter<InProcessTransport.Server> {
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func token(_ metadata: Metadata) -> String {
            calls.metadata.withLock { $0.append(metadata) }
            return String((metadata[stringValues: "authorization"].first(where: { _ in true }) ?? "").dropFirst("Bearer ".count))
        }
        @Sendable func status(_ error: any Error) -> any Error {
            switch error {
            case DataServiceError.hostNotAllowed(let host, let admins):
                return GoogleRPCStatus(code: .permissionDenied, message: "host", details: [.errorInfo(reason: "HOST_NOT_ALLOWED", domain: "wiretuner.app",
                                                                                                      metadata: ["host": host, "admins": admins])])
            case let error as SyncCallError:
                return FakeGRPCService.status(error)
            default:
                return error
            }
        }
        func unary<Input: SwiftProtobuf.Message, Output: SwiftProtobuf.Message>(
            _ descriptor: MethodDescriptor, _: Input.Type, _: Output.Type, _ body: @escaping @Sendable (Input, String) async throws -> Output
        ) {
            router.registerHandler(forMethod: descriptor, deserializer: ProtobufDeserializer<Input>(), serializer: ProtobufSerializer<Output>()) { request, _ in
                let single = try await ServerRequest(stream: request)
                do {
                    return StreamingServerResponse(single: ServerResponse(message: try await body(single.message, token(single.metadata))))
                } catch {
                    throw status(error)
                }
            }
        }
        router.registerHandler(forMethod: Method.Fetch.descriptor, deserializer: ProtobufDeserializer<Method.Fetch.Input>(),
                               serializer: ProtobufSerializer<Method.Fetch.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await response in fake.fetch(single.message, token: bearer) { try await writer.write(response) }
                } catch {
                    throw status(error)
                }
                return [:]
            }
        }
        unary(Method.FetchAsset.descriptor, Method.FetchAsset.Input.self, Method.FetchAsset.Output.self) { try await fake.fetchAsset($0, token: $1) }
        unary(Method.Proxy.descriptor, Method.Proxy.Input.self, Method.Proxy.Output.self) { try await fake.proxy($0, token: $1) }
        unary(Method.ListCredentials.descriptor, Method.ListCredentials.Input.self, Method.ListCredentials.Output.self) { try await fake.listCredentials($0, token: $1) }
        unary(Method.PutCredential.descriptor, Method.PutCredential.Input.self, Method.PutCredential.Output.self) { try await fake.putCredential($0, token: $1) }
        unary(Method.DeleteCredential.descriptor, Method.DeleteCredential.Input.self, Method.DeleteCredential.Output.self) { try await fake.deleteCredential($0, token: $1) }
        unary(Method.ListAllowedHosts.descriptor, Method.ListAllowedHosts.Input.self, Method.ListAllowedHosts.Output.self) { try await fake.listAllowedHosts($0, token: $1) }
        unary(Method.PutAllowedHost.descriptor, Method.PutAllowedHost.Input.self, Method.PutAllowedHost.Output.self) { try await fake.putAllowedHost($0, token: $1) }
        unary(Method.DeleteAllowedHost.descriptor, Method.DeleteAllowedHost.Input.self, Method.DeleteAllowedHost.Output.self) { try await fake.deleteAllowedHost($0, token: $1) }
        return router
    }

    @Test func everyCallRunsOverGRPC() async throws {
        let fake = FakeData()
        let recorded = FakeGRPCService.Calls()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: Self.router(fake, calls: recorded))
        let (model, source) = try Self.document()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCDataSourceTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let client = DataSourceClient(transport: transport, directory: Self.directory(), token: { "tok" })
            fake.state.withLock { $0.dropAfter = 1 }
            let table = try await client.fetchAll(documentID: "doc-1", source: source, model: model)
            #expect(table.records.count == 6)
            #expect(try await client.fetchAsset(documentID: "doc-1", url: "https://a").mediaType == "image/png")
            #expect(try await client.proxy(documentID: "doc-1", ScriptFetchRequest(url: "https://api.example.com/p")).status == 200)
            _ = try await client.putCredential(.with { $0.name = "c"; $0.kind = .bearer })
            #expect(try await client.credentials(documentID: "doc-1").count == 1)
            #expect(try await client.deleteCredential(scope: .with { $0.teamID = "t" }, name: "c"))
            try await client.putAllowedHost(scope: .with { $0.accountID = "a" }, host: "h.example.com")
            #expect(try await client.allowedHosts(documentID: "doc-1").count == 2)
            #expect(try await client.deleteAllowedHost(scope: .with { $0.accountID = "a" }, host: "h.example.com"))
            // Rejections carry the reason and its metadata.
            await #expect(throws: DataServiceError.hostNotAllowed(host: "evil.example", admins: "")) {
                try await client.proxy(documentID: "doc-1", ScriptFetchRequest(url: "https://evil.example/x"))
            }
            fake.state.withLock { $0.failure = SyncCallError(code: SyncCallError.unavailable, message: "down") }
            await #expect(throws: DataServiceError.offline) { for try await _ in await client.fetch(DataSourceClient.request(documentID: "d", source: source, model: model, params: [:])) {} }
            await #expect(throws: DataServiceError.offline) { try await client.credentials(documentID: "doc-1") }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-client"]) == ["macos/1.0/1"] && Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
        #expect(GRPCDataSourceTransport<InProcessTransport.Client>.mapped(URLError(.badURL)) is URLError)
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let plain = try GRPCDataSourceTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await plain.close()
        let tls = try GRPCDataSourceTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
        let hostless = try GRPCDataSourceTransport.http2(api: URL(string: "grpc:/path")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await hostless.close()
    }
}
