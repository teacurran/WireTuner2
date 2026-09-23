import CryptoKit
import Foundation
import GRPCCore
import GRPCInProcessTransport
import GRPCProtobuf
import Synchronization
import Testing
import WTProto
@testable import WTSync

/// TXT-002's team font library, client side: `FontLibraryClient` listing the catalog with a file
/// cache and `known_version`, restarting a listing whose version moved, fetching font files into
/// the blob cache with hash verification, uploading and removing, and offline fallbacks;
/// `GRPCFontLibraryTransport` end to end over the in-process transport.
@Suite(.timeLimit(.minutes(2))) struct FontLibraryClientTests {
    /// A `FontLibraryService` in memory: each team's fonts, their bytes, and a catalog version.
    final class FakeFonts: FontLibraryTransport, Sendable {
        struct State {
            var fonts: [String: [Wiretuner_Account_V1_TeamFont]] = [:]
            var bytes: [Data: Data] = [:]
            var version: UInt64 = 0
            var offline = false
            /// Bumps the version after this many more pages (to move it mid-listing).
            var bumpAfterPages: Int?
            /// Bumps the version after every page.
            var restless = false
            var corrupt = false
            var lists: [Wiretuner_Account_V1_ListFontsRequest] = []
            var tokens: [String] = []
            var removed: [Data] = []
        }

        let state = Mutex(State())

        struct Offline: Error {}

        static func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

        @discardableResult
        func add(_ family: String, styles: [String] = ["Regular"], team: String = "team-1", bytes: Data? = nil) -> Wiretuner_Account_V1_TeamFont {
            let content = bytes ?? Data("\(family) \(styles) \(team)".utf8)
            var font = Wiretuner_Account_V1_TeamFont()
            font.sha256 = Self.sha(content)
            font.teamID = team
            font.fileName = "\(family).ttf"
            font.size = UInt64(content.count)
            font.faces = styles.map { style in .with { $0.family = family; $0.style = style } }
            state.withLock { state in
                state.fonts[team, default: []].append(font)
                state.bytes[font.sha256] = content
                state.version += 1
            }
            return font
        }

        private func check(_ token: String) throws {
            try state.withLock { state in
                state.tokens.append(token)
                if state.offline { throw Offline() }
            }
        }

        func uploadFont(_ header: Wiretuner_Account_V1_UploadFontHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String)
            async throws -> Wiretuner_Account_V1_UploadFontResponse {
            try check(token)
            var content = Data()
            for try await chunk in chunks { content += chunk }
            guard Self.sha(content) == header.sha256 else { throw Offline() }
            var font = add("Uploaded", team: header.teamID, bytes: content)
            font.fileName = header.fileName
            return .with {
                $0.font = font
                $0.version = state.withLock { $0.version }
            }
        }

        func listFonts(_ request: Wiretuner_Account_V1_ListFontsRequest, token: String) async throws
            -> Wiretuner_Account_V1_ListFontsResponse {
            try check(token)
            return state.withLock { state in
                state.lists.append(request)
                var response = Wiretuner_Account_V1_ListFontsResponse()
                response.version = state.version
                if request.cursor.isEmpty, request.knownVersion != 0, request.knownVersion == state.version {
                    response.unchanged = true
                    return response
                }
                // One font per page, to exercise the cursor.
                let all = state.fonts[request.teamID] ?? []
                let start = Int(request.cursor) ?? 0
                if start < all.count {
                    response.fonts = [all[start]]
                    response.nextCursor = start + 1 < all.count ? String(start + 1) : ""
                }
                if state.restless {
                    state.version += 1
                } else if let pages = state.bumpAfterPages {
                    if pages <= 1 {
                        state.version += 1
                        state.bumpAfterPages = nil
                    } else {
                        state.bumpAfterPages = pages - 1
                    }
                }
                return response
            }
        }

        func fetchFont(_ request: Wiretuner_Account_V1_FetchFontRequest, token: String)
            -> AsyncThrowingStream<Wiretuner_Account_V1_FetchFontResponse, any Error> {
            AsyncThrowingStream { continuation in
                do {
                    try check(token)
                    let (font, content) = try state.withLock { state in
                        guard let font = state.fonts[request.teamID]?.first(where: { $0.sha256 == request.sha256 }),
                              var content = state.bytes[request.sha256] else { throw Offline() }
                        if state.corrupt { content.append(0) }
                        return (font, content)
                    }
                    continuation.yield(.with { $0.font = font })
                    var at = 0
                    while at < content.count {
                        let end = min(at + 4, content.count)
                        continuation.yield(.with { $0.chunk = content.subdata(in: at ..< end) })
                        at = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        func removeFont(_ request: Wiretuner_Account_V1_RemoveFontRequest, token: String) async throws
            -> Wiretuner_Account_V1_RemoveFontResponse {
            try check(token)
            return state.withLock { state in
                state.removed.append(request.sha256)
                state.fonts[request.teamID]?.removeAll { $0.sha256 == request.sha256 }
                state.version += 1
                return .with { $0.version = state.version }
            }
        }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(component: "wt-fontlib-\(UUID().uuidString)")
    }

    static func client(_ transport: any FontLibraryTransport, _ root: URL) -> FontLibraryClient {
        FontLibraryClient(transport: transport, cache: BlobCache(directory: root.appending(component: "blobs")),
                          directory: root.appending(component: "fonts"), token: { "tok" })
    }

    @Test func catalogIsListedCachedAndAskedForByVersion() async throws {
        let server = FakeFonts()
        server.add("Inter", styles: ["Regular", "Bold"])
        server.add("Avenir")
        server.add("Elsewhere", team: "team-2")
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = Self.client(server, root)

        #expect(await client.cachedCatalog(team: "team-1") == .init(fonts: [], version: 0, isCurrent: false))
        var catalog = await client.catalog(team: "team-1")
        #expect(catalog.isCurrent && catalog.version == 3)
        #expect(catalog.families == ["Inter", "Avenir"])
        #expect(catalog.fonts(inFamily: "inter").map(\.fileName) == ["Inter.ttf"])
        #expect(catalog.fonts(inFamily: "Futura").isEmpty)

        // Again: known_version is the cached version and the server answers "unchanged".
        catalog = await client.catalog(team: "team-1")
        #expect(catalog.isCurrent && catalog.families == ["Inter", "Avenir"])
        #expect(server.state.withLock { $0.lists.map(\.knownVersion) } == [0, 0, 3])

        // A change: the whole catalog again.
        server.add("Futura")
        catalog = await client.catalog(team: "team-1")
        #expect(catalog.version == 4 && catalog.families.contains("Futura"))

        // Offline: the cached catalog, not current; a team never listed is empty.
        server.state.withLock { $0.offline = true }
        catalog = await client.catalog(team: "team-1")
        #expect(!catalog.isCurrent && catalog.version == 4 && catalog.fonts.count == 3)
        #expect(await client.catalog(team: "never").fonts.isEmpty)
        #expect(server.state.withLock { $0.tokens }.allSatisfy { $0 == "tok" })
        #expect(try FontLibraryClient.defaultDirectory().pathComponents.suffix(3) == ["WireTuner", "Fonts", "team"])
    }

    @Test func aListingWhoseVersionMovesStartsAgain() async throws {
        let server = FakeFonts()
        server.add("A")
        server.add("B")
        server.add("C")
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = Self.client(server, root)

        // The version moves after the first page: the listing starts again and settles.
        server.state.withLock { $0.bumpAfterPages = 1 }
        var catalog = await client.catalog(team: "team-1")
        #expect(catalog.version == 4 && catalog.fonts.count == 3)
        #expect(server.state.withLock { $0.lists.count } == 6)

        // A catalog that keeps moving: after the last attempt the last pass is taken.
        let restless = FakeFonts()
        restless.add("A")
        restless.add("B")
        let moving = Self.client(restless, root.appending(component: "restless"))
        restless.state.withLock { $0.restless = true }
        catalog = await moving.catalog(team: "team-1")
        #expect(catalog.fonts.count == 2)
        #expect(restless.state.withLock { $0.lists.count } == 2 * FontLibraryClient.listingAttempts)
    }

    @Test func fontFilesAreFetchedVerifiedAndCached() async throws {
        let server = FakeFonts()
        let inter = server.add("Inter", styles: ["Regular", "Bold"], bytes: Data("inter font bytes".utf8))
        server.add("Avenir")
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = Self.client(server, root)
        _ = await client.catalog(team: "team-1")

        #expect(client.cachedFile(for: inter) == nil)
        let urls = try await client.files(forFamily: "Inter", team: "team-1")
        #expect(urls.count == 1)
        #expect(try Data(contentsOf: urls[0]) == Data("inter font bytes".utf8))
        #expect(client.cachedFile(for: inter) == urls[0])
        #expect(try await client.files(forFamily: "Nothing", team: "team-1").isEmpty)

        // Offline: a cached file still answers; an uncached one throws.
        server.state.withLock { $0.offline = true }
        #expect(try await client.file(for: inter) == urls[0])
        let avenir = await client.cachedCatalog(team: "team-1").fonts(inFamily: "Avenir")[0]
        await #expect(throws: FakeFonts.Offline.self) { try await client.file(for: avenir) }

        // Bytes that do not hash to the font's sha256 are refused and not cached.
        server.state.withLock { $0.offline = false; $0.corrupt = true }
        await #expect(throws: BlobCache.Failure.self) { try await client.file(for: avenir) }
        #expect(client.cachedFile(for: avenir) == nil)
    }

    @Test func adminsUploadAndRemove() async throws {
        let server = FakeFonts()
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = Self.client(server, root)
        let file = root.appending(component: "Mine.otf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3 << 20 | 5).write(to: file)

        let uploaded = try await client.upload(fileAt: file, team: "team-1")
        #expect(uploaded.fileName == "Mine.otf" && uploaded.teamID == "team-1")
        // The uploaded file is in the cache: no fetch needed.
        #expect(client.cachedFile(for: uploaded) != nil)
        let named = try await client.upload(fileAt: file, name: "Renamed.otf", team: "team-2")
        #expect(named.fileName == "Renamed.otf")

        try await client.remove(uploaded)
        #expect(server.state.withLock { $0.removed } == [uploaded.sha256])
        #expect(await client.catalog(team: "team-1").fonts.isEmpty)
    }

    // MARK: gRPC

    typealias Method = Wiretuner_Account_V1_FontLibraryService.Method

    static func router(_ fake: FakeFonts, calls: FakeGRPCService.Calls) -> RPCRouter<InProcessTransport.Server> {
        var router = RPCRouter<InProcessTransport.Server>()
        @Sendable func token(_ metadata: Metadata) -> String {
            calls.metadata.withLock { $0.append(metadata) }
            return String((metadata[stringValues: "authorization"].first(where: { _ in true }) ?? "").dropFirst("Bearer ".count))
        }
        @Sendable func absent() -> any Error {
            FakeGRPCService.status(SyncCallError(code: 5, reason: nil, message: "absent", retryAfter: nil))
        }
        @Sendable func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> StreamingServerResponse<Output> {
            do {
                return StreamingServerResponse(single: ServerResponse(message: try await body()))
            } catch is FakeFonts.Offline {
                throw absent()
            }
        }
        router.registerHandler(forMethod: Method.UploadFont.descriptor, deserializer: ProtobufDeserializer<Method.UploadFont.Input>(),
                               serializer: ProtobufSerializer<Method.UploadFont.Output>()) { request, _ in
            let bearer = token(request.metadata)
            var header = Wiretuner_Account_V1_UploadFontHeader()
            var chunks: [Data] = []
            for try await frame in request.messages {
                switch frame.frame {
                case .header(let value)?: header = value
                case .chunk(let value)?: chunks.append(value)
                case nil: break
                }
            }
            let stream = AsyncThrowingStream<Data, any Error> { continuation in
                chunks.forEach { continuation.yield($0) }
                continuation.finish()
            }
            return try await unary { [header] in try await fake.uploadFont(header, chunks: stream, token: bearer) }
        }
        router.registerHandler(forMethod: Method.ListFonts.descriptor, deserializer: ProtobufDeserializer<Method.ListFonts.Input>(),
                               serializer: ProtobufSerializer<Method.ListFonts.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.listFonts(single.message, token: token(single.metadata)) }
        }
        router.registerHandler(forMethod: Method.FetchFont.descriptor, deserializer: ProtobufDeserializer<Method.FetchFont.Input>(),
                               serializer: ProtobufSerializer<Method.FetchFont.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            let bearer = token(single.metadata)
            return StreamingServerResponse { writer in
                do {
                    for try await frame in fake.fetchFont(single.message, token: bearer) {
                        try await writer.write(frame)
                    }
                } catch is FakeFonts.Offline {
                    throw absent()
                }
                return [:]
            }
        }
        router.registerHandler(forMethod: Method.RemoveFont.descriptor, deserializer: ProtobufDeserializer<Method.RemoveFont.Input>(),
                               serializer: ProtobufSerializer<Method.RemoveFont.Output>()) { request, _ in
            let single = try await ServerRequest(stream: request)
            return try await unary { try await fake.removeFont(single.message, token: token(single.metadata)) }
        }
        return router
    }

    @Test func everyCallRunsOverGRPC() async throws {
        let fake = FakeFonts()
        let inter = fake.add("Inter", bytes: Data("inter over grpc, longer than one chunk".utf8))
        let recorded = FakeGRPCService.Calls()
        let inProcess = InProcessTransport()
        let server = GRPCServer(transport: inProcess.server, router: Self.router(fake, calls: recorded))
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await server.serve() }
            let transport = GRPCFontLibraryTransport(transport: inProcess.client, identity: .init(clientVersion: "1.0/1", deviceID: "device-1"))
            let client = Self.client(transport, root)
            #expect(await client.catalog(team: "team-1").families == ["Inter"])
            #expect(try Data(contentsOf: try await client.file(for: inter)) == Data("inter over grpc, longer than one chunk".utf8))
            let file = root.appending(component: "Up.ttf")
            try Data("uploaded over grpc".utf8).write(to: file)
            #expect(try await client.upload(fileAt: file, team: "team-1").fileName == "Up.ttf")
            try await client.remove(inter)
            // A rejection arrives as a SyncCallError with its code, on unary and streaming calls.
            var missing = inter
            missing.sha256 = Data(repeating: 1, count: 32)
            await #expect(throws: SyncCallError.self) { try await client.file(for: missing) }
            await #expect(throws: SyncCallError.self) {
                _ = try await transport.listFonts(.init(), token: "tok")
                fake.state.withLock { $0.offline = true }
                _ = try await transport.listFonts(.init(), token: "tok")
            }
            server.beginGracefulShutdown()
            await transport.close()
        }
        let calls = recorded.metadata.withLock { $0 }
        #expect(calls.count == 7)
        #expect(calls.allSatisfy { Array($0[stringValues: "wt-client"]) == ["macos/1.0/1"] && Array($0[stringValues: "wt-device"]) == ["device-1"] })
        #expect(calls.allSatisfy { Array($0[stringValues: "authorization"]) == ["Bearer tok"] })
    }

    @Test func http2TransportsAreBuiltFromTheAPIURL() async throws {
        let plain = try GRPCFontLibraryTransport.http2(api: URL(string: "http://localhost:1")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await plain.close()
        let tls = try GRPCFontLibraryTransport.http2(api: URL(string: "https://example.invalid")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await tls.close()
        let hostless = try GRPCFontLibraryTransport.http2(api: URL(string: "grpc:/path")!, identity: .init(clientVersion: "1", deviceID: "d"))
        await hostless.close()
    }
}
