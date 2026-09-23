import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import WTProto

/// `DocumentService`, `TeamService.ListTeams` and `BlobService.Download` over grpc-swift 2's
/// HTTP/2 transport, one connection per call like `GRPCAccountClient` (SYNC-001's long-lived
/// client serves the document session).  Every request builder and response mapping lives in
/// `LibraryRequests` and the proto initializers, so each call here is one line.
struct GRPCLibraryClient: LibraryDocumentClient, TeamListClient, BlobDownloadClient {
    typealias Documents = Wiretuner_Docs_V1_DocumentService.Client<HTTP2ClientTransport.Posix>
    typealias Teams = Wiretuner_Account_V1_TeamService.Client<HTTP2ClientTransport.Posix>
    typealias Blobs = Wiretuner_Blob_V1_BlobService.Client<HTTP2ClientTransport.Posix>

    let api: URL
    let clientVersion: String
    let deviceID: String

    var endpoint: (host: String, port: Int, tls: Bool) {
        GRPCAccountClient(api: api, clientVersion: clientVersion, deviceID: deviceID).endpoint
    }

    /// One call on a fresh connection; the response maps itself (`LibraryResponse`).
    private func call<Response: LibraryResponse>(
        _ accessToken: String, _ body: (GRPCClient<HTTP2ClientTransport.Posix>, Metadata) async throws -> Response
    ) async throws -> Response.Mapped {
        let endpoint = self.endpoint
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: endpoint.host, port: endpoint.port), transportSecurity: endpoint.tls ? .tls : .plaintext
        )
        let metadata = CallMetadata(accessToken: accessToken, clientVersion: clientVersion, deviceID: deviceID).metadata
        return try await withGRPCClient(transport: transport) { client in try await body(client, metadata) }.mapped
    }

    // MARK: DocumentService

    func list(_ request: LibraryListRequest, accessToken: String) async throws -> LibraryPage {
        let message = LibraryRequests.list(request)
        let page = try await call(accessToken) { try await Documents(wrapping: $0).list(message, metadata: $1) }
        return request.scope == .sharedWithMe ? page.markedShared : page
    }

    func get(documentID: String, accessToken: String) async throws -> LibraryDocument {
        try await call(accessToken) { try await Documents(wrapping: $0).get(.with { $0.documentID = documentID }, metadata: $1) }
    }

    func search(query: String, spaceID: String, cursor: String?, accessToken: String) async throws -> LibrarySearchPage {
        let message = LibraryRequests.search(query: query, spaceID: spaceID, cursor: cursor)
        return try await call(accessToken) { try await Documents(wrapping: $0).search(message, metadata: $1) }
    }

    func create(_ document: LibraryDocument, accessToken: String) async throws -> LibraryDocument {
        let message = LibraryRequests.create(document)
        return try await call(accessToken) { try await Documents(wrapping: $0).create(message, metadata: $1) }
    }

    func rename(documentID: String, name: String, accessToken: String) async throws -> LibraryDocument {
        try await call(accessToken) { try await Documents(wrapping: $0).rename(.with { $0.documentID = documentID; $0.name = name }, metadata: $1) }
    }

    func trash(documentID: String, accessToken: String) async throws -> LibraryDocument {
        try await call(accessToken) { try await Documents(wrapping: $0).trash(.with { $0.documentID = documentID }, metadata: $1) }
    }

    func duplicate(documentID: String, newDocumentID: String, name: String, accessToken: String) async throws -> LibraryDocument {
        let message = LibraryRequests.duplicate(documentID: documentID, newDocumentID: newDocumentID, name: name)
        return try await call(accessToken) { try await Documents(wrapping: $0).duplicate(message, metadata: $1) }
    }

    func move(documentID: String, spaceID: String, folderID: String?, accessToken: String) async throws -> LibraryDocument {
        let message = LibraryRequests.move(documentID: documentID, spaceID: spaceID, folderID: folderID)
        return try await call(accessToken) { try await Documents(wrapping: $0).moveToFolder(message, metadata: $1) }
    }

    func createFolder(spaceID: String, parentFolderID: String?, name: String, accessToken: String) async throws -> LibraryFolder {
        let message = LibraryRequests.createFolder(spaceID: spaceID, parentFolderID: parentFolderID, name: name)
        return try await call(accessToken) { try await Documents(wrapping: $0).createFolder(message, metadata: $1) }
    }

    func renameFolder(folderID: String, name: String, accessToken: String) async throws -> LibraryFolder {
        try await call(accessToken) { try await Documents(wrapping: $0).renameFolder(.with { $0.folderID = folderID; $0.name = name }, metadata: $1) }
    }

    func deleteFolder(folderID: String, accessToken: String) async throws {
        try await call(accessToken) { try await Documents(wrapping: $0).deleteFolder(.with { $0.folderID = folderID }, metadata: $1) }
    }

    // MARK: TeamService

    func listTeams(accessToken: String) async throws -> [LibrarySpace] {
        try await call(accessToken) { try await Teams(wrapping: $0).listTeams(.with { $0.pageSize = 50 }, metadata: $1) }
    }

    // MARK: BlobService

    func download(documentID: String, sha256: Data, accessToken: String) async throws -> Data {
        let message = LibraryRequests.download(documentID: documentID, sha256: sha256)
        return try await call(accessToken) { try await Blobs(wrapping: $0).download(message, metadata: $1, onResponse: LibraryRequests.collect) }
    }
}
