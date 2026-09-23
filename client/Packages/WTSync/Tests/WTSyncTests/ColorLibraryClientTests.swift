import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import Testing
import WTProto
@testable import WTSync

/// COLOR-021's sync half: `ColorLibraryClient` listing and fetching team colour libraries with a
/// file cache, `known_seq`, the update dot and offline fallbacks; `GRPCColorLibraryTransport`
/// end to end over the in-process transport.
@Suite(.timeLimit(.minutes(2))) struct ColorLibraryClientTests {
    /// A `ColorLibraryService` in memory: libraries by document id, each with its colours.
    final class FakeLibraries: ColorLibraryTransport, Sendable {
        struct State {
            var infos: [String: Wiretuner_Docs_V1_ColorLibraryInfo] = [:]
            var colors: [String: Wiretuner_Lib_V1_ColorLibrary] = [:]
            var offline = false
            var fetches: [Wiretuner_Docs_V1_FetchColorLibraryRequest] = []
            var tokens: [String] = []
            var unpublished: [String] = []
        }

        let state = Mutex(State())

        struct Offline: Error {}

        func publish(_ id: String, team: String = "team-1", seq: UInt64, updated: Int64, colors: [String]) {
            state.withLock { state in
                var info = Wiretuner_Docs_V1_ColorLibraryInfo()
                info.documentID = id
                info.teamID = team
                info.name = "Library \(id)"
                info.publishedSeq = seq
                info.updatedMs = updated
                state.infos[id] = info
                var library = Wiretuner_Lib_V1_ColorLibrary()
                library.name = info.name
                library.colors = colors.map { key in
                    var color = Wiretuner_Lib_V1_LibraryColor()
                    color.key = key
                    color.name = key
                    return color
                }
                state.colors[id] = library
            }
        }

        private func check(_ token: String) throws {
            try state.withLock { state in
                state.tokens.append(token)
                if state.offline { throw Offline() }
            }
        }

        func publishColorLibrary(_ request: Wiretuner_Docs_V1_PublishColorLibraryRequest, token: String) async throws
            -> Wiretuner_Docs_V1_PublishColorLibraryResponse {
            try check(token)
            publish(request.documentID, team: request.teamID, seq: request.serverSeq, updated: 1, colors: [])
            return state.withLock { state in .with { $0.library = state.infos[request.documentID]! } }
        }

        func unpublishColorLibrary(_ request: Wiretuner_Docs_V1_UnpublishColorLibraryRequest, token: String) async throws
            -> Wiretuner_Docs_V1_UnpublishColorLibraryResponse {
            try check(token)
            state.withLock { $0.unpublished.append(request.documentID) }
            return .init()
        }

        func listColorLibraries(_ request: Wiretuner_Docs_V1_ListColorLibrariesRequest, token: String) async throws
            -> Wiretuner_Docs_V1_ListColorLibrariesResponse {
            try check(token)
            return state.withLock { state in
                // One library per page, to exercise the cursor.
                let all = state.infos.values.filter { $0.teamID == request.teamID }.sorted { $0.documentID < $1.documentID }
                let start = Int(request.cursor) ?? 0
                var response = Wiretuner_Docs_V1_ListColorLibrariesResponse()
                if start < all.count {
                    response.libraries = [all[start]]
                    response.nextCursor = start + 1 < all.count ? String(start + 1) : ""
                }
                return response
            }
        }

        func fetchColorLibrary(_ request: Wiretuner_Docs_V1_FetchColorLibraryRequest, token: String) async throws
            -> Wiretuner_Docs_V1_FetchColorLibraryResponse {
            try check(token)
            return try state.withLock { state in
                state.fetches.append(request)
                guard let info = state.infos[request.documentID] else { throw Offline() }
                var response = Wiretuner_Docs_V1_FetchColorLibraryResponse()
                response.library = info
                if request.knownSeq != info.publishedSeq {
                    response.colors = state.colors[request.documentID]!
                }
                return response
            }
        }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "wt-colorlib-\(UUID().uuidString)")
    }

    @Test func listFetchCacheAndUpdateDot() async throws {
        let server = FakeLibraries()
        server.publish("a", seq: 5, updated: 100, colors: ["Grape"])
        server.publish("b", seq: 2, updated: 50, colors: ["Plum", "Fig"])
        server.publish("c", team: "team-2", seq: 1, updated: 1, colors: [])
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ColorLibraryClient(transport: server, directory: directory, token: { "tok" })

        var listing = await client.libraries(team: "team-1")
        #expect(listing.isCurrent && listing.libraries.map(\.info.documentID) == ["a", "b"])
        #expect(listing.libraries.allSatisfy { !$0.isCached && !$0.hasUpdate })

        // First fetch: known_seq 0, colours arrive and are cached.
        #expect(try await client.library("a").colors.map(\.key) == ["Grape"])
        #expect(await client.cachedLibrary("a")?.colors.map(\.key) == ["Grape"])
        // Second fetch: known_seq is the cached seq, the server leaves the colours out, the cache answers.
        #expect(try await client.library("a").colors.map(\.key) == ["Grape"])
        #expect(server.state.withLock { $0.fetches.map(\.knownSeq) } == [0, 5])

        listing = await client.libraries(team: "team-1")
        #expect(listing.libraries.first { $0.info.documentID == "a" }.map { $0.isCached && !$0.hasUpdate } == true)
        // A newer version lights the dot; fetching it clears it.
        server.publish("a", seq: 9, updated: 200, colors: ["Grape", "Plum"])
        listing = await client.libraries(team: "team-1")
        #expect(listing.libraries.first { $0.info.documentID == "a" }?.hasUpdate == true)
        #expect(try await client.library("a").colors.count == 2)
        listing = await client.libraries(team: "team-1")
        #expect(listing.libraries.first { $0.info.documentID == "a" }?.hasUpdate == false)

        // Offline: the cached listing, no dots, and cached colours; an uncached library throws.
        server.publish("a", seq: 10, updated: 300, colors: ["Grape"])
        server.state.withLock { $0.offline = true }
        listing = await client.libraries(team: "team-1")
        #expect(!listing.isCurrent && listing.libraries.map(\.info.documentID) == ["a", "b"])
        #expect(listing.libraries.allSatisfy { !$0.hasUpdate })
        #expect(try await client.library("a").colors.count == 2)
        await #expect(throws: FakeLibraries.Offline.self) { try await client.library("b") }
        #expect(await client.libraries(team: "never-listed").libraries.isEmpty)
        #expect(server.state.withLock { $0.tokens }.allSatisfy { $0 == "tok" })

        await client.forget("a")
        #expect(await client.cachedLibrary("a") == nil)
    }

    @Test func publishingAndUnpublishing() async throws {
        let server = FakeLibraries()
        let client = ColorLibraryClient(transport: server, directory: Self.directory(), token: { "tok" })
        let info = try await client.publish("doc-1", team: "team-9", name: "Brand", mode: .manual, serverSeq: 12)
        #expect(info.documentID == "doc-1" && info.teamID == "team-9" && info.publishedSeq == 12)
        try await client.unpublish("doc-1")
        #expect(server.state.withLock { $0.unpublished } == ["doc-1"])
        #expect(try ColorLibraryClient.defaultDirectory().pathComponents.suffix(3) == ["WireTuner", "Colors", "team"])
    }

    // MARK: gRPC

    typealias Method = Wiretuner_Docs_V1_ColorLibraryService.Method

    static func router(_ fake: FakeLibraries, calls: FakeGRPCService.Calls) -> RPCRouter<InProcessTransport.Server> {
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func token(_ request: ServerRequest<some Sendable>) -> String {
            calls.metadata.withLock { $0.append(request.metadata) }
            return String((request.metadata[stringValues: "authorization"].first(where: { _ in true }) ?? "").dropFirst("Bearer ".count))
        }
        @Sendable func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
            do {
                return StreamingServerResponse(single: ServerResponse(message: try await body()))
            } catch is FakeLibraries.Offline {
                throw FakeGRPCService.status(SyncCallError(code: 5, reason: nil, message: "absent", retryAfter: nil))
            }
        }
        router.registerHandler(forMethod: Method.PublishColorLibrary.descriptor, deserializer: ProtobufDeserializer<Method.PublishColorLibrary.Input>(),
                               serializer: ProtobufSerializer<Method.PublishColorLibrary.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.publishColorLibrary(single.message, token: token(single)) }
        }
        router.registerHandler(forMethod: Method.UnpublishColorLibrary.descriptor,
                               deserializer: ProtobufDeserializer<Method.UnpublishColorLibrary.Input>(),
                               serializer: ProtobufSerializer<Method.UnpublishColorLibrary.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.unpublishColorLibrary(single.message, token: token(single)) }
        }
        router.registerHandler(forMethod: Method.ListColorLibraries.descriptor, deserializer: ProtobufDeserializer<Method.ListColorLibraries.Input>(),
                               serializer: ProtobufSerializer<Method.ListColorLibraries.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.listColorLibraries(single.message, token: token(single)) }
        }
        router.registerHandler(forMethod: Method.FetchColorLibrary.descriptor, deserializer: ProtobufDeserializer<Method.FetchColorLibrary.Input>(),
                               serializer: ProtobufSerializer<Method.FetchColorLibrary.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.fetchColorLibrary(single.message, token: token(single)) }
        }
        return router
    }

    @Test func everyCallRunsOverGRPC() async throws {
        let fake = FakeLibraries()
        fake.publish("a", seq: 3, updated: 10, colors: ["Grape"])
        let recorded = FakeGRPCService.Calls()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: Self.router(fake, calls: recorded))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCColorLibraryTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let client = ColorLibraryClient(transport: transport, directory: Self.directory(), token: { "tok" })
            #expect(await client.libraries(team: "team-1").libraries.map(\.info.documentID) == ["a"])
            #expect(try await client.library("a").colors.map(\.key) == ["Grape"])
            #expect(try await client.publish("b").documentID == "b")
            try await client.unpublish("b")
            // A rejection arrives as a SyncCallError with its code.
            await #expect(throws: SyncCallError.self) { try await client.library("missing") }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count == 5)
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-client"]) == ["macos/1.0/1"] && Array($0[stringValues: "wt-device"]) == ["device-1"] })
        #expect(calls.allSatisfy { Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let plain = try GRPCColorLibraryTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await plain.close()
        let tls = try GRPCColorLibraryTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
        let hostless = try GRPCColorLibraryTransport.http2(api: URL(string: "grpc:/path")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await hostless.close()
    }
}
