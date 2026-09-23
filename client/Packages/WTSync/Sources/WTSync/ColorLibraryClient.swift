import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import WTProto

/// The calls of `ColorLibraryService` (exporting-colors.adoc, "Team color libraries"; COLOR-020
/// built the server).  `GRPCColorLibraryTransport` is the network one; tests supply fakes.
public protocol ColorLibraryTransport: Sendable {
    func publishColorLibrary(_ request: Wiretuner_Docs_V1_PublishColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_PublishColorLibraryResponse
    func unpublishColorLibrary(_ request: Wiretuner_Docs_V1_UnpublishColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_UnpublishColorLibraryResponse
    func listColorLibraries(_ request: Wiretuner_Docs_V1_ListColorLibrariesRequest, token: String) async throws
        -> Wiretuner_Docs_V1_ListColorLibrariesResponse
    func fetchColorLibrary(_ request: Wiretuner_Docs_V1_FetchColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_FetchColorLibraryResponse
}

/// `ColorLibraryTransport` over grpc-swift 2, with the metadata of api-conventions.adoc (the
/// bearer token, `wt-client`, `wt-device`, a fresh `wt-request-id`); rejections arrive as
/// `SyncCallError`s as they do from `GRPCSyncTransport`.
public final class GRPCColorLibraryTransport<Transport: ClientTransport>: ColorLibraryTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Docs_V1_ColorLibraryService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Docs_V1_ColorLibraryService.Client(wrapping: client)
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

    public func publishColorLibrary(_ request: Wiretuner_Docs_V1_PublishColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_PublishColorLibraryResponse {
        try await unary { try await service.publishColorLibrary(request, metadata: metadata(token)) }
    }

    public func unpublishColorLibrary(_ request: Wiretuner_Docs_V1_UnpublishColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_UnpublishColorLibraryResponse {
        try await unary { try await service.unpublishColorLibrary(request, metadata: metadata(token)) }
    }

    public func listColorLibraries(_ request: Wiretuner_Docs_V1_ListColorLibrariesRequest, token: String) async throws
        -> Wiretuner_Docs_V1_ListColorLibrariesResponse {
        try await unary { try await service.listColorLibraries(request, metadata: metadata(token)) }
    }

    public func fetchColorLibrary(_ request: Wiretuner_Docs_V1_FetchColorLibraryRequest, token: String) async throws
        -> Wiretuner_Docs_V1_FetchColorLibraryResponse {
        try await unary { try await service.fetchColorLibrary(request, metadata: metadata(token)) }
    }
}

/// Team colour libraries on this Mac (exporting-colors.adoc, "Client", `ColorLibraryClient`;
/// COLOR-021's sync half): *Team Libraries* lists what the last successful `List` returned, each
/// library's last fetched colours are cached as files, and adding from a cached library works
/// offline.  A fetch sends the cached `published_seq` as `known_seq`, so an unchanged library
/// comes back without its colours and the cache answers.  The update dot shows only after a
/// `List` succeeded, for a cached library whose `updated_ms` has moved past the cached one.
public actor ColorLibraryClient {
    /// One library of a team as the submenu shows it.
    public struct Entry: Hashable, Sendable {
        public let info: Wiretuner_Docs_V1_ColorLibraryInfo
        /// Its colours are cached here (adding from it works offline).
        public let isCached: Bool
        /// The update dot: a newer version than the cached one was published.
        public let hasUpdate: Bool
    }

    /// A team's libraries.
    public struct Listing: Hashable, Sendable {
        public let libraries: [Entry]
        /// Whether this listing came from the server just now (false: from the cache).
        public let isCurrent: Bool
    }

    private let transport: any ColorLibraryTransport
    private let token: @Sendable () async throws -> String
    private let directory: URL

    /// A client over `transport` caching in `directory`; `token` supplies the bearer token.
    public init(transport: any ColorLibraryTransport, directory: URL, token: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.directory = directory
        self.token = token
    }

    /// `~/Library/Application Support/WireTuner/Colors/team`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Colors", "team")
    }

    // MARK: Listing

    /// The libraries of `team`: from the server when it answers (the listing is cached), else the
    /// last cached listing with no update dots.
    public func libraries(team: String) async -> Listing {
        do {
            var libraries: [Wiretuner_Docs_V1_ColorLibraryInfo] = []
            var cursor = ""
            repeat {
                var request = Wiretuner_Docs_V1_ListColorLibrariesRequest()
                request.teamID = team
                request.cursor = cursor
                request.pageSize = 50
                let response = try await transport.listColorLibraries(request, token: token())
                libraries += response.libraries
                cursor = response.nextCursor
            } while !cursor.isEmpty
            var listing = Wiretuner_Docs_V1_ListColorLibrariesResponse()
            listing.libraries = libraries
            write(listing, to: listFile(team))
            return Listing(libraries: libraries.map { entry($0, current: true) }, isCurrent: true)
        } catch {
            let cached = read(Wiretuner_Docs_V1_ListColorLibrariesResponse.self, from: listFile(team))?.libraries ?? []
            return Listing(libraries: cached.map { entry($0, current: false) }, isCurrent: false)
        }
    }

    private func entry(_ info: Wiretuner_Docs_V1_ColorLibraryInfo, current: Bool) -> Entry {
        let cached = cachedFetch(info.documentID)
        return Entry(info: info, isCached: cached != nil, hasUpdate: current && cached.map { info.updatedMs > $0.library.updatedMs } ?? false)
    }

    // MARK: Fetching

    /// The colours of the library document `documentID`: fetched (with the cached version as
    /// `known_seq`) and cached, or -- when the server cannot be reached -- the cached colours.
    /// Throws when neither is available.
    public func library(_ documentID: String) async throws -> Wiretuner_Lib_V1_ColorLibrary {
        let cached = cachedFetch(documentID)
        var request = Wiretuner_Docs_V1_FetchColorLibraryRequest()
        request.documentID = documentID
        request.knownSeq = cached?.library.publishedSeq ?? 0
        let response: Wiretuner_Docs_V1_FetchColorLibraryResponse
        do {
            response = try await transport.fetchColorLibrary(request, token: token())
        } catch {
            guard let cached else { throw error }
            return cached.colors
        }
        var stored = response
        if !response.hasColors, let cached, cached.library.publishedSeq == response.library.publishedSeq {
            stored.colors = cached.colors
        }
        write(stored, to: libraryFile(documentID))
        return stored.colors
    }

    /// The cached colours of `documentID`, if it was ever fetched here.
    public func cachedLibrary(_ documentID: String) -> Wiretuner_Lib_V1_ColorLibrary? {
        cachedFetch(documentID)?.colors
    }

    /// Forgets a library's cached colours (it was unpublished, or the user removed it).
    public func forget(_ documentID: String) {
        try? FileManager.default.removeItem(at: libraryFile(documentID))
    }

    // MARK: Publishing

    /// *Make Team Color Library…* and *Publish Library Version*: publishes `documentID` (to
    /// `team` when it is a personal document; `mode` unspecified keeps the current mode; a
    /// `serverSeq` of 0 is the head).
    public func publish(_ documentID: String, team: String = "", name: String = "", mode: Wiretuner_Docs_V1_ColorLibraryMode = .unspecified,
                        serverSeq: UInt64 = 0) async throws -> Wiretuner_Docs_V1_ColorLibraryInfo {
        var request = Wiretuner_Docs_V1_PublishColorLibraryRequest()
        request.documentID = documentID
        request.teamID = team
        request.name = name
        request.mode = mode
        request.serverSeq = serverSeq
        return try await transport.publishColorLibrary(request, token: token()).library
    }

    /// Stops publishing `documentID` as a library (consumers keep their swatches).
    public func unpublish(_ documentID: String) async throws {
        var request = Wiretuner_Docs_V1_UnpublishColorLibraryRequest()
        request.documentID = documentID
        _ = try await transport.unpublishColorLibrary(request, token: token())
    }

    // MARK: Cache files

    private func cachedFetch(_ documentID: String) -> Wiretuner_Docs_V1_FetchColorLibraryResponse? {
        read(Wiretuner_Docs_V1_FetchColorLibraryResponse.self, from: libraryFile(documentID))
    }

    /// A file name from an id: only letters, digits and `-` survive.
    private static func fileName(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
    }

    private func libraryFile(_ documentID: String) -> URL {
        directory.appending(component: "library-\(Self.fileName(documentID)).binpb")
    }

    private func listFile(_ team: String) -> URL {
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

extension GRPCColorLibraryTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCColorLibraryTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCColorLibraryTransport(transport: transport, identity: identity)
    }
}
