import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WTSync

/// LIB-016's sync half: team library listings (cached for offline), library states from this Mac
/// or the server at head, `SetLibrary` and `GetLibrary`, and the gRPC transport.
@Suite(.timeLimit(.minutes(2))) struct TeamLibraryClientTests {
    /// `LibraryService` in memory: libraries per team; `offline` fails every call.
    final class FakeService: TeamLibraryTransport, Sendable {
        struct Offline: Error {}
        struct State {
            var libraries: [String: [Wiretuner_Docs_V1_Library]] = [:]
            var offline = false
            var set: [Wiretuner_Docs_V1_SetLibraryRequest] = []
            var tokens: [String] = []
        }

        let state = Mutex(State())

        func add(_ team: String, _ id: String, _ name: String, head: UInt64) {
            state.withLock {
                $0.libraries[team, default: []].append(.with {
                    $0.documentID = id
                    $0.teamID = team
                    $0.name = name
                    $0.headSeq = head
                })
            }
        }

        var offline: Bool {
            get { state.withLock { $0.offline } }
            set { state.withLock { $0.offline = newValue } }
        }

        private func online(_ token: String) throws {
            try state.withLock {
                if $0.offline { throw Offline() }
                $0.tokens.append(token)
            }
        }

        func setLibrary(_ request: Wiretuner_Docs_V1_SetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_SetLibraryResponse {
            try online(token)
            state.withLock { $0.set.append(request) }
            return .with {
                if request.isLibrary {
                    $0.library = .with {
                        $0.documentID = request.documentID
                        $0.name = request.name
                    }
                }
            }
        }

        func listLibraries(_ request: Wiretuner_Docs_V1_ListLibrariesRequest, token: String) async throws -> Wiretuner_Docs_V1_ListLibrariesResponse {
            try online(token)
            let all = state.withLock { $0.libraries[request.teamID] ?? [] }
            // One library per page, to follow the cursor.
            let index = Int(request.cursor) ?? 0
            return .with {
                $0.libraries = index < all.count ? [all[index]] : []
                $0.nextCursor = index + 1 < all.count ? String(index + 1) : ""
            }
        }

        func getLibrary(_ request: Wiretuner_Docs_V1_GetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_GetLibraryResponse {
            try online(token)
            guard let library = state.withLock({ $0.libraries.values.joined().first { $0.documentID == request.documentID } }) else {
                throw Offline()
            }
            return .with { $0.library = library }
        }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "team-libraries-\(UUID().uuidString)")
    }

    @Test func listingsAreCachedAndShownOffline() async throws {
        let service = FakeService()
        service.add("team-1", "b", "Web", head: 3)
        service.add("team-1", "a", "Marketing", head: 5)
        service.add("team-2", "c", "Print", head: 1)
        let client = TeamLibraryClient(transport: service, sync: nil, directory: Self.directory(), local: { _ in nil }, token: { "tok" })
        let online = await client.libraries(teams: ["team-1", "team-2"])
        #expect(online.isCurrent && online.libraries.map(\.name) == ["Marketing", "Print", "Web"])
        #expect(await client.isOnline)
        service.offline = true
        let offline = await client.libraries(teams: ["team-1", "team-2", "team-3"])
        #expect(!offline.isCurrent && offline.libraries.map(\.name) == ["Marketing", "Print", "Web"])
        #expect(await !client.isOnline)
        #expect(try TeamLibraryClient.defaultDirectory().pathComponents.suffix(2) == ["WireTuner", "Libraries"])
        #expect(TeamLibraryClient.fileName("a/b:c-1") == "abc-1")
    }

    @Test func statesComeFromThisMacAtHeadElseFromTheServer() async throws {
        let scratch = Scratch()
        let (_, changes) = try await SymbolSourcesTests.storeWithSymbol(scratch)
        let server = FakeSyncServer()
        for change in changes { _ = try await server.inject(change) }
        let head = UInt64(changes.count)
        let service = FakeService()
        service.add("team-1", server.documentID, "Marketing", head: head)
        var stale = EngineState()
        stale.apply(changes[0], serverSeq: 1)
        let here = Mutex<(state: EngineState, serverSeq: UInt64)?>((stale, 1))
        let client = TeamLibraryClient(transport: service, sync: FakeTransport(server: server), directory: Self.directory(),
                                       local: { id in id == server.documentID ? here.withLock { $0 } : nil }, token: { "token-1" })
        _ = await client.libraries(teams: ["team-1"])

        // This Mac's copy is behind the head: the server's is read (and kept).
        let sources = try await client.cachedLibraries()
        #expect(sources.map(\.name) == ["Marketing"] && sources[0].headSeq == head)
        #expect(Symbols.symbols(in: sources[0].state).count == 1)
        let catalog = try await LibraryCatalog.load(from: client)
        #expect(catalog.sections(.symbol).first?.items.map(\.name) == ["Dot"])

        // Offline: what was read stays; a library read only here is offered at its own head.
        service.offline = true
        #expect(try await client.cachedLibraries().map(\.headSeq) == [head])
        let other = TeamLibraryClient(transport: service, sync: nil, directory: Self.directory(),
                                      local: { id in id == server.documentID ? here.withLock { $0 } : nil }, token: { "tok" })
        #expect(try await other.cachedLibraries().isEmpty, "no team listed yet")
        service.offline = false
        _ = await other.libraries(teams: ["team-1"])
        here.withLock { $0 = ($0!.state, head) }
        let fromHere = try await other.cachedLibraries()
        #expect(fromHere.map(\.headSeq) == [head] && Symbols.symbols(in: fromHere[0].state).isEmpty, "this Mac's store at head")
        here.withLock { $0 = nil }
        #expect(try await other.cachedLibraries().isEmpty, "no sync transport and nothing here")
    }

    @Test func publishingAndTheHead() async throws {
        let service = FakeService()
        service.add("team-1", "a", "Marketing", head: 7)
        let client = TeamLibraryClient(transport: service, sync: nil, directory: Self.directory(), local: { _ in nil }, token: { "tok" })
        #expect(try await client.setLibrary("doc-1", isLibrary: true, name: "Icons")?.name == "Icons")
        #expect(try await client.setLibrary("doc-1", isLibrary: false) == nil)
        #expect(service.state.withLock { $0.set.map(\.isLibrary) } == [true, false])
        #expect(try await client.head(of: "a") == 7)
    }

    @Test func aLocalStoreIsReadWhenItExists() async throws {
        let scratch = Scratch()
        let (url, _) = try await SymbolSourcesTests.storeWithSymbol(scratch)
        let read = TeamLibraryClient.cachedStore(location: { _ in url }, options: options())
        let found = try #require(try await read("doc"))
        #expect(Symbols.symbols(in: found.state).count == 1 && found.serverSeq == 0)
        let absent = scratch.directory.appending(component: "absent.sqlite")
        let missing = TeamLibraryClient.cachedStore(location: { _ in absent }, options: options())
        #expect(try await missing("doc") == nil)
    }

    // MARK: gRPC

    typealias Method = Wiretuner_Docs_V1_LibraryService.Method

    static func router(_ fake: FakeService, calls: FakeGRPCService.Calls) -> RPCRouter<InProcessTransport.Server> {
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func token(_ request: ServerRequest<some Sendable>) -> String {
            calls.metadata.withLock { $0.append(request.metadata) }
            return String((request.metadata[stringValues: "authorization"].first(where: { _ in true }) ?? "").dropFirst("Bearer ".count))
        }
        @Sendable func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
            do {
                return StreamingServerResponse(single: ServerResponse(message: try await body()))
            } catch is FakeService.Offline {
                throw FakeGRPCService.status(SyncCallError(code: 5, reason: nil, message: "absent", retryAfter: nil))
            }
        }
        router.registerHandler(forMethod: Method.SetLibrary.descriptor, deserializer: ProtobufDeserializer<Method.SetLibrary.Input>(),
                               serializer: ProtobufSerializer<Method.SetLibrary.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.setLibrary(single.message, token: token(single)) }
        }
        router.registerHandler(forMethod: Method.ListLibraries.descriptor, deserializer: ProtobufDeserializer<Method.ListLibraries.Input>(),
                               serializer: ProtobufSerializer<Method.ListLibraries.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.listLibraries(single.message, token: token(single)) }
        }
        router.registerHandler(forMethod: Method.GetLibrary.descriptor, deserializer: ProtobufDeserializer<Method.GetLibrary.Input>(),
                               serializer: ProtobufSerializer<Method.GetLibrary.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.getLibrary(single.message, token: token(single)) }
        }
        return router
    }

    @Test func everyCallRunsOverGRPC() async throws {
        let fake = FakeService()
        fake.add("team-1", "a", "Marketing", head: 4)
        let recorded = FakeGRPCService.Calls()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: Self.router(fake, calls: recorded))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCTeamLibraryTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let client = TeamLibraryClient(transport: transport, sync: nil, directory: Self.directory(), local: { _ in nil }, token: { "tok" })
            #expect(await client.libraries(teams: ["team-1"]).libraries.map(\.documentID) == ["a"])
            let head = try await client.head(of: "a")
            let published = try await client.setLibrary("b", isLibrary: true)
            #expect(head == 4 && published?.documentID == "b")
            await #expect(throws: SyncCallError.self) { try await client.head(of: "missing") }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-device"]) == ["device-1"] && Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let plain = try GRPCTeamLibraryTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await plain.close()
        let tls = try GRPCTeamLibraryTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
    }
}
