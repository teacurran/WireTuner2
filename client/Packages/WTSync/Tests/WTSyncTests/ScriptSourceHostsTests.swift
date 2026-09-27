import Foundation
import GRPCCore
import GRPCInProcessTransport
import Synchronization
import Testing
import WTCRDT
import WTModel
import WTProto
@testable import WTSync

/// DATA-015's WTSync remainder (data-merge.adoc, "Credentials and hosts sheets", DATA-015's *Done
/// when*): a script source's `wt.fetch` hosts are kept in the local store, and its fetches go
/// through `Proxy` -- with the document, the credential name and the token -- never a socket of
/// the script's own.
@Suite(.timeLimit(.minutes(2))) struct ScriptSourceHostsTests {
    @Test func hostsAreKeptPerSourceInTheLocalStore() async throws {
        let scratch = Scratch()
        let source = OpID(counter: 7, replica: 0xA)
        let other = OpID(counter: 8, replica: 0xA)
        var store = try await LocalStore.open(documentID: "doc", at: scratch.url("doc"), options: options())
        #expect(try await store.scriptHosts(source: source).isEmpty, "never ran here")
        try await store.setScriptHosts(["API.example.com", "b.example.com", "api.example.com", ""], source: source)
        try await store.setScriptHosts(["c.example.com"], source: other)
        try await store.close()
        // Reopened (a relaunch): each source's hosts are there.
        store = try await LocalStore.open(documentID: "doc", at: scratch.url("doc"), options: options())
        #expect(try await store.scriptHosts(source: source) == ["api.example.com", "b.example.com"])
        #expect(try await store.scriptHosts(source: other) == ["c.example.com"])
        // The next run replaces the previous one's.
        try await store.setScriptHosts([], source: source)
        #expect(try await store.scriptHosts(source: source).isEmpty)
        try await store.close()
        #expect(ScriptSourceHosts.key(source) == "data.script_hosts.7-10")
        #expect(ScriptSourceHosts.decode(Data("{}".utf8)).isEmpty && ScriptSourceHosts.decode(nil).isEmpty)
    }

    /// Records every request a `URLSession` would make in this process: a direct connection from
    /// the script would show here.
    final class DirectRequests: URLProtocol, @unchecked Sendable {
        static let seen = Mutex<[URL]>([])
        override class func canInit(with request: URLRequest) -> Bool {
            if let url = request.url { seen.withLock { $0.append(url) } }
            return false
        }
    }

    @Test func aScriptSourceFetchesThroughProxyWithTheCredential() async throws {
        URLProtocol.registerClass(DirectRequests.self)
        defer { URLProtocol.unregisterClass(DirectRequests.self) }
        DirectRequests.seen.withLock { $0 = [] }
        let fake = DataSourceClientTests.FakeData()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: DataSourceClientTests.router(fake, calls: FakeGRPCService.Calls()))
        var core = DocumentCore(state: EngineState(), replica: 0xA)
        let recording = DocumentCore.Recording(limit: 10, now: Date(timeIntervalSince1970: 1_000_000))
        let script = try #require(try core.perform(SaveScript(name: "Remote", source: """
        export async function records() {
          const sockets = ["fetch", "XMLHttpRequest", "WebSocket"].map((name) => {
            try { globalThis[name]("https://api.example.com/people"); return "open"; } catch (error) { return error.name; }
          }).join(",");
          const res = await wt.fetch("https://api.example.com/people", { credential: "crm" });
          const body = await res.json();
          return [{ ok: String(body.ok), sockets }];
        }
        """), recording: recording)?.change?.createdObjects.first)
        let state = core.state
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCDataSourceTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let client = DataSourceClient(transport: transport, directory: DataSourceClientTests.directory(), token: { "tok" })
            let fetcher = DataScriptFetcher(client: client, documentID: "doc-1", personalAccount: nil)
            let result = try await Task.detached { try ScriptRecordSource.records(script: script, state: state, fetcher: fetcher) }.value
            #expect(result.table.records.first?.values == ["ok": "true", "sockets": "SandboxError,SandboxError,SandboxError"], "the runtime has no network of its own")
            #expect(result.hosts == ["api.example.com"])
            group.cancelAll()
        }
        // The audit row: one Proxy call naming the document, the URL and the credential, with the token.
        let proxies = fake.state.withLock { $0.proxies }
        #expect(proxies.count == 1)
        #expect(proxies.first?.documentID == "doc-1" && proxies.first?.url == "https://api.example.com/people" && proxies.first?.credentialName == "crm")
        #expect(fake.state.withLock { $0.tokens }.contains("tok"))
        #expect(DirectRequests.seen.withLock { $0 }.allSatisfy { $0.host != "api.example.com" }, "no direct connection")
    }
}
