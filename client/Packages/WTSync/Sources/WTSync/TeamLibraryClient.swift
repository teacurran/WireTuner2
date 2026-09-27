import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import SwiftProtobuf
import WTCRDT
import WTModel
import WTProto

/// The calls of `LibraryService` (sharing.adoc, "Team libraries"; COLLAB-012 built the server).
/// `GRPCTeamLibraryTransport` is the network one; tests supply fakes.
public protocol TeamLibraryTransport: Sendable {
    func setLibrary(_ request: Wiretuner_Docs_V1_SetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_SetLibraryResponse
    func listLibraries(_ request: Wiretuner_Docs_V1_ListLibrariesRequest, token: String) async throws -> Wiretuner_Docs_V1_ListLibrariesResponse
    func getLibrary(_ request: Wiretuner_Docs_V1_GetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_GetLibraryResponse
}

/// `TeamLibraryTransport` over grpc-swift 2 with the metadata of api-conventions.adoc; rejections
/// arrive as `SyncCallError`s as they do from `GRPCSyncTransport`.
public final class GRPCTeamLibraryTransport<Transport: ClientTransport>: TeamLibraryTransport {
    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Docs_V1_LibraryService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Docs_V1_LibraryService.Client(wrapping: client)
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

    public func setLibrary(_ request: Wiretuner_Docs_V1_SetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_SetLibraryResponse {
        try await unary { try await service.setLibrary(request, metadata: metadata(token)) }
    }

    public func listLibraries(_ request: Wiretuner_Docs_V1_ListLibrariesRequest, token: String) async throws -> Wiretuner_Docs_V1_ListLibrariesResponse {
        try await unary { try await service.listLibraries(request, metadata: metadata(token)) }
    }

    public func getLibrary(_ request: Wiretuner_Docs_V1_GetLibraryRequest, token: String) async throws -> Wiretuner_Docs_V1_GetLibraryResponse {
        try await unary { try await service.getLibrary(request, metadata: metadata(token)) }
    }
}

extension GRPCTeamLibraryTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCTeamLibraryTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCTeamLibraryTransport(transport: transport, identity: identity)
    }
}

/// The team libraries of this Mac's account (library.adoc, "Team libraries" and "Offline
/// behavior"; LIB-016's sync half): the libraries each team lists -- the last listing cached as a
/// file, so the Library panel still names them offline -- and each library's merged state for the
/// *Team libraries* folders, *Place* and *Update from Library* (`LibraryStoreOpening`).  A
/// library's state comes from this Mac when its store is here at the library's head (or offline, at
/// whatever head it has), else from the server at head (the newest snapshot, then the changes after
/// it), kept for the session.  Offline, a library with no state here is not offered.
public actor TeamLibraryClient: LibraryStoreOpening {
    /// A team's libraries as last listed.
    public struct Listing: Hashable, Sendable {
        public let libraries: [Wiretuner_Docs_V1_Library]
        /// Whether every team answered just now (false: some came from the cache).
        public let isCurrent: Bool
    }

    /// A library document's state on this Mac and the server seq it has reached.
    public typealias LocalState = @Sendable (String) async throws -> (state: EngineState, serverSeq: UInt64)?

    private let transport: any TeamLibraryTransport
    private let sync: (any SyncTransport)?
    private let directory: URL
    private let local: LocalState
    private let token: @Sendable () async throws -> String
    private var teams: [String] = []
    private var fetched: [String: LibrarySource] = [:]
    /// Whether the last listing reached the server.
    public private(set) var isOnline = false

    /// A client over `transport` (and `sync` for reading libraries at head) caching listings in
    /// `directory`; `local` reads a library's state on this Mac; `token` supplies the bearer token.
    public init(transport: any TeamLibraryTransport, sync: (any SyncTransport)?, directory: URL, local: @escaping LocalState,
                token: @escaping @Sendable () async throws -> String) {
        self.transport = transport
        self.sync = sync
        self.directory = directory
        self.local = local
        self.token = token
    }

    /// `~/Library/Application Support/WireTuner/Libraries`.
    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(components: "WireTuner", "Libraries")
    }

    /// A library's state from its local store at `location(documentID)`, when that file exists.
    public static func cachedStore(location: @escaping @Sendable (String) throws -> URL, options: LocalStore.Options = LocalStore.Options()) -> LocalState {
        { documentID in
            let url = try location(documentID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let store = try await LocalStore.open(documentID: documentID, at: url, options: options)
            let state = await store.read { $0 }
            let seq = await store.lastServerSeq
            try await store.close()
            return (state, seq)
        }
    }

    // MARK: Listing

    /// The libraries of `teams`, by name: each team's from the server when it answers (the listing
    /// is cached), else its last cached listing.
    public func libraries(teams: [String]) async -> Listing {
        self.teams = teams
        var all: [Wiretuner_Docs_V1_Library] = []
        var current = true
        for team in teams {
            do {
                var libraries: [Wiretuner_Docs_V1_Library] = []
                var cursor = ""
                repeat {
                    var request = Wiretuner_Docs_V1_ListLibrariesRequest()
                    request.teamID = team
                    request.cursor = cursor
                    request.pageSize = 50
                    let response = try await transport.listLibraries(request, token: token())
                    libraries += response.libraries
                    cursor = response.nextCursor
                } while !cursor.isEmpty
                var listing = Wiretuner_Docs_V1_ListLibrariesResponse()
                listing.libraries = libraries
                write(listing, to: listFile(team))
                all += libraries
            } catch {
                current = false
                all += read(Wiretuner_Docs_V1_ListLibrariesResponse.self, from: listFile(team))?.libraries ?? []
            }
        }
        isOnline = current && !teams.isEmpty
        return Listing(libraries: all.sorted { ($0.name.lowercased(), $0.documentID) < ($1.name.lowercased(), $1.documentID) }, isCurrent: current)
    }

    // MARK: States

    /// Every listed library with a state: this Mac's at the listed head (any head offline), else
    /// the server's at head.  A library that cannot be read is left out.
    public func cachedLibraries() async throws -> [LibrarySource] {
        let listing = await libraries(teams: teams)
        var out: [LibrarySource] = []
        for library in listing.libraries {
            if let source = try? await source(of: library, online: listing.isCurrent) { out.append(source) }
        }
        return out
    }

    /// The state of `library`; nil when it has none here and cannot be read from the server.
    func source(of library: Wiretuner_Docs_V1_Library, online: Bool) async throws -> LibrarySource? {
        let id = library.documentID
        if let known = fetched[id], !online || known.headSeq >= library.headSeq { return known }
        if let here = try await local(id), !online || here.serverSeq >= library.headSeq {
            return LibrarySource(documentID: id, name: library.name, headSeq: here.serverSeq, state: here.state)
        }
        guard online, let sync else { return nil }
        let (state, seq) = try await SymbolSources.cloudHead(documentID: id, transport: sync, token: token())
        let source = LibrarySource(documentID: id, name: library.name, headSeq: seq, state: state)
        fetched[id] = source
        return source
    }

    /// The head of one library now (`GetLibrary`), for the *update available* check.
    public func head(of documentID: String) async throws -> UInt64 {
        var request = Wiretuner_Docs_V1_GetLibraryRequest()
        request.documentID = documentID
        return try await transport.getLibrary(request, token: token()).library.headSeq
    }

    // MARK: Publishing

    /// *Use as Team Library* (`isLibrary`) or its undoing: marks the team document `documentID`.
    @discardableResult
    public func setLibrary(_ documentID: String, isLibrary: Bool, name: String = "") async throws -> Wiretuner_Docs_V1_Library? {
        var request = Wiretuner_Docs_V1_SetLibraryRequest()
        request.documentID = documentID
        request.isLibrary = isLibrary
        request.name = name
        let response = try await transport.setLibrary(request, token: token())
        return response.hasLibrary ? response.library : nil
    }

    // MARK: Cache files

    /// A file name from an id: only letters, digits and `-` survive.
    static func fileName(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
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
