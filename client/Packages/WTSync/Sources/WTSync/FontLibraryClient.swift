import CryptoKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import WTProto

/// The calls of `FontLibraryService` (font-substitution.adoc, "Team font library"; TXT-002's
/// server half).  `GRPCFontLibraryTransport` is the network one; tests supply fakes.
public protocol FontLibraryTransport: Sendable {
    /// A client-streaming upload: `header`, then the chunks as `chunks` yields them.
    func uploadFont(_ header: Wiretuner_Account_V1_UploadFontHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String)
        async throws -> Wiretuner_Account_V1_UploadFontResponse
    func listFonts(_ request: Wiretuner_Account_V1_ListFontsRequest, token: String) async throws
        -> Wiretuner_Account_V1_ListFontsResponse
    func fetchFont(_ request: Wiretuner_Account_V1_FetchFontRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Account_V1_FetchFontResponse, any Error>
    func removeFont(_ request: Wiretuner_Account_V1_RemoveFontRequest, token: String) async throws
        -> Wiretuner_Account_V1_RemoveFontResponse
}

/// `FontLibraryTransport` over grpc-swift 2, with the metadata of api-conventions.adoc (the
/// bearer token, `wt-client`, `wt-device`, a fresh `wt-request-id`); rejections arrive as
/// `SyncCallError`s as they do from `GRPCSyncTransport`.
public final class GRPCFontLibraryTransport<Transport: ClientTransport>: FontLibraryTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Account_V1_FontLibraryService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Account_V1_FontLibraryService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    private func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw GRPCSyncTransport<Transport>.mapped(error)
        }
    }

    public func uploadFont(_ header: Wiretuner_Account_V1_UploadFontHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String)
        async throws -> Wiretuner_Account_V1_UploadFontResponse {
        try await unary {
            try await service.uploadFont(metadata: metadata(token)) { writer in
                try await writer.write(.with { $0.header = header })
                for try await chunk in chunks {
                    try await writer.write(.with { $0.chunk = chunk })
                }
            }
        }
    }

    public func listFonts(_ request: Wiretuner_Account_V1_ListFontsRequest, token: String) async throws
        -> Wiretuner_Account_V1_ListFontsResponse {
        try await unary { try await service.listFonts(request, metadata: metadata(token)) }
    }

    public func fetchFont(_ request: Wiretuner_Account_V1_FetchFontRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Account_V1_FetchFontResponse, any Error> {
        let metadata = metadata(token)
        return AsyncThrowingStream { [service] continuation in
            let task = Task {
                do {
                    try await service.fetchFont(request, metadata: metadata) { response in
                        for try await message in response.messages {
                            continuation.yield(message)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: GRPCSyncTransport<Transport>.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func removeFont(_ request: Wiretuner_Account_V1_RemoveFontRequest, token: String) async throws
        -> Wiretuner_Account_V1_RemoveFontResponse {
        try await unary { try await service.removeFont(request, metadata: metadata(token)) }
    }
}

/// A team's font library on this Mac (font-substitution.adoc, "Team font library"): the catalog
/// the last successful `ListFonts` returned is kept as a file, so the families the library offers
/// are known offline, and every fetched font file is kept in the content-addressed `BlobCache`
/// (the same cache as document blobs, where an embedded copy of the same font is the same file),
/// so a font once fetched activates offline.  A listing sends the cached catalog's `version` as
/// `known_version`, so an unchanged catalog costs one small answer.
///
/// WTText's `FontManager` takes `catalog(team:).families` as `teamLibraryFamilies`; when it
/// reports a family in `teamLibraryPending`, `files(forFamily:team:)` fetches that family's files
/// and `activate(fontsAt:source: .teamLibrary)` registers them.
public actor FontLibraryClient {
    /// A team's catalog.
    public struct Catalog: Hashable, Sendable {
        public let fonts: [Wiretuner_Account_V1_TeamFont]
        /// The server's catalog version it was listed at; 0 when never listed.
        public let version: UInt64
        /// Whether it came from the server just now (false: from the cache, or nothing cached).
        public let isCurrent: Bool

        /// Every family some face of the catalog belongs to.
        public var families: Set<String> {
            Set(fonts.flatMap { $0.faces.map(\.family) })
        }

        /// The fonts with a face of `family` (ignoring case).
        public func fonts(inFamily family: String) -> [Wiretuner_Account_V1_TeamFont] {
            fonts.filter { $0.faces.contains { $0.family.caseInsensitiveCompare(family) == .orderedSame } }
        }
    }

    /// A listing restarts at most this many times when the catalog changes while it pages.
    static let listingAttempts = 3

    private let transport: any FontLibraryTransport
    private let token: @Sendable () async throws -> String
    private let cache: BlobCache
    private let directory: URL

    /// A client over `transport` keeping catalogs in `directory` and font files in `cache`;
    /// `token` supplies the bearer token.
    public init(transport: any FontLibraryTransport, cache: BlobCache, directory: URL,
                token: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.cache = cache
        self.directory = directory
        self.token = token
    }

    /// `~/Library/Application Support/WireTuner/Fonts/team`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Fonts", "team")
    }

    // MARK: Catalog

    /// The catalog of `team`: from the server when it answers (and cached), else the cached one.
    public func catalog(team: String) async -> Catalog {
        let cached = cachedCatalog(team: team)
        do {
            var listing = try await list(team: team, known: cached.version)
            var attempts = 1
            while listing.moved, attempts < Self.listingAttempts {
                listing = try await list(team: team, known: 0)
                attempts += 1
            }
            guard let response = listing.response else {
                return Catalog(fonts: cached.fonts, version: cached.version, isCurrent: true)
            }
            write(response, to: catalogFile(team))
            return Catalog(fonts: response.fonts, version: response.version, isCurrent: true)
        } catch {
            return cached
        }
    }

    /// Every page of the catalog; `response` nil when `known` is current, `moved` when the version
    /// changed between pages (the fonts are then a mix of two versions).
    private func list(team: String, known: UInt64) async throws -> (response: Wiretuner_Account_V1_ListFontsResponse?, moved: Bool) {
        var all = Wiretuner_Account_V1_ListFontsResponse()
        var cursor = ""
        var moved = false
        repeat {
            var request = Wiretuner_Account_V1_ListFontsRequest()
            request.teamID = team
            request.cursor = cursor
            request.pageSize = 50
            request.knownVersion = cursor.isEmpty ? known : 0
            let page = try await transport.listFonts(request, token: token())
            if page.unchanged { return (nil, false) }
            if cursor.isEmpty {
                all.version = page.version
            } else if page.version != all.version {
                moved = true
            }
            all.fonts += page.fonts
            cursor = page.nextCursor
        } while !cursor.isEmpty
        return (all, moved)
    }

    /// The last catalog listed for `team` (empty when never listed), not current.
    public func cachedCatalog(team: String) -> Catalog {
        let cached = read(Wiretuner_Account_V1_ListFontsResponse.self, from: catalogFile(team))
        return Catalog(fonts: cached?.fonts ?? [], version: cached?.version ?? 0, isCurrent: false)
    }

    // MARK: Font files

    /// The cached file of `font`, if it was fetched (or embedded, or uploaded) here.
    public nonisolated func cachedFile(for font: Wiretuner_Account_V1_TeamFont) -> URL? {
        let hash = BlobCache.hex(font.sha256)
        return cache.contains(hash) ? cache.url(for: hash) : nil
    }

    /// The file of `font`: from the cache, else fetched, verified against its hash, and cached.
    public func file(for font: Wiretuner_Account_V1_TeamFont) async throws -> URL {
        if let cached = cachedFile(for: font) { return cached }
        let hash = BlobCache.hex(font.sha256)
        let temporary = try cache.temporaryURL()
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var hasher = SHA256()
        var request = Wiretuner_Account_V1_FetchFontRequest()
        request.teamID = font.teamID
        request.sha256 = font.sha256
        let bearer = try await token()
        for try await response in transport.fetchFont(request, token: bearer) {
            if case .chunk(let chunk)? = response.frame {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
        }
        let actual = BlobCache.hex(hasher.finalize())
        guard actual == hash else { throw BlobCache.Failure.hashMismatch(expected: hash, actual: actual) }
        return try cache.adopt(temporary, as: hash)
    }

    /// The files of every font of the cached catalog of `team` with a face of `family`, fetched
    /// when not cached: what `FontManager.activate(fontsAt:source:)` takes for a pending family.
    public func files(forFamily family: String, team: String) async throws -> [URL] {
        var urls: [URL] = []
        for font in cachedCatalog(team: team).fonts(inFamily: family) {
            urls.append(try await file(for: font))
        }
        return urls
    }

    // MARK: Managing (team admins)

    /// Uploads the font file at `url` to `team`'s library under `name` (the file's name when nil);
    /// the file is kept in the cache too.  The server refuses a file that is not a font or whose
    /// licence does not allow embedding (`SyncCallError` code 3, `VALIDATION_FAILED`).
    public func upload(fileAt url: URL, name: String? = nil, team: String) async throws -> Wiretuner_Account_V1_TeamFont {
        let (hash, size) = try cache.insert(contentsOf: url)
        var header = Wiretuner_Account_V1_UploadFontHeader()
        header.teamID = team
        header.sha256 = BlobCache.bytes(hex: hash)
        header.size = UInt64(size)
        header.fileName = name ?? url.lastPathComponent
        let chunks = BlobChunks.read(cache.url(for: hash), chunkSize: 1 << 20)
        return try await transport.uploadFont(header, chunks: chunks, token: token()).font
    }

    /// Removes `font` from its team's library; the cached file stays (documents may embed it).
    public func remove(_ font: Wiretuner_Account_V1_TeamFont) async throws {
        var request = Wiretuner_Account_V1_RemoveFontRequest()
        request.teamID = font.teamID
        request.sha256 = font.sha256
        _ = try await transport.removeFont(request, token: token())
    }

    // MARK: Cache files

    /// A file name from an id: only letters, digits and `-` survive.
    private static func fileName(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
    }

    private func catalogFile(_ team: String) -> URL {
        directory.appending(component: "team-\(Self.fileName(team)).binpb")
    }

    private func read<M: SwiftProtobuf.Message>(_ type: M.Type, from url: URL) -> M? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? M(serializedBytes: data)
    }

    private func write(_ message: some SwiftProtobuf.Message, to url: URL) {
        guard let data = try? message.serializedData() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension GRPCFontLibraryTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCFontLibraryTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCFontLibraryTransport(transport: transport, identity: identity)
    }
}
