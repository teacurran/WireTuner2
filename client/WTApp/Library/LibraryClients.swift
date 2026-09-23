import Foundation
import GRPCCore
import SwiftProtobuf
import WTProto

/// The `DocumentService` RPCs the library window uses.  A protocol so `LibraryModel` is
/// tested against fakes rather than a server.
protocol LibraryDocumentClient: Sendable {
    func list(_ request: LibraryListRequest, accessToken: String) async throws -> LibraryPage
    func get(documentID: String, accessToken: String) async throws -> LibraryDocument
    func search(query: String, spaceID: String, cursor: String?, accessToken: String) async throws -> LibrarySearchPage
    /// `Create` with the client-generated UUIDv7 in `document.id`.
    func create(_ document: LibraryDocument, accessToken: String) async throws -> LibraryDocument
    func rename(documentID: String, name: String, accessToken: String) async throws -> LibraryDocument
    func trash(documentID: String, accessToken: String) async throws -> LibraryDocument
    func duplicate(documentID: String, newDocumentID: String, name: String, accessToken: String) async throws -> LibraryDocument
    /// `MoveToFolder`; `folderID` nil moves to the top level of `spaceID`.
    func move(documentID: String, spaceID: String, folderID: String?, accessToken: String) async throws -> LibraryDocument
    func createFolder(spaceID: String, parentFolderID: String?, name: String, accessToken: String) async throws -> LibraryFolder
    func renameFolder(folderID: String, name: String, accessToken: String) async throws -> LibraryFolder
    func deleteFolder(folderID: String, accessToken: String) async throws
}

/// `TeamService.ListTeams`, for the space switcher.
protocol TeamListClient: Sendable {
    func listTeams(accessToken: String) async throws -> [LibrarySpace]
}

/// `BlobService.Download`, for thumbnails.
protocol BlobDownloadClient: Sendable {
    func download(documentID: String, sha256: Data, accessToken: String) async throws -> Data
}

enum LibraryClientError: Error, Equatable, Sendable {
    /// No connection (fakes throw it; the gRPC client reports `RPCError.unavailable`).
    case offline
    /// A download's content does not hash to the key it was asked for.
    case hashMismatch
}

/// Whether an error means "no network" (the library then works from its cache) rather than a
/// refusal worth showing.
enum LibraryConnectivity {
    static func isOffline(_ error: any Error) -> Bool {
        if let error = error as? LibraryClientError { return error == .offline }
        if let error = error as? AuthError { return error == .notSignedIn || error == .sessionExpired }
        if let error = error as? RPCError { return [.unavailable, .deadlineExceeded].contains(error.code) }
        return error is URLError
    }
}

// MARK: Proto mapping

extension LibraryDocument.Role {
    init?(_ role: Wiretuner_Account_V1_DocumentRole) {
        switch role {
        case .owner: self = .owner
        case .editor: self = .editor
        case .commenter: self = .commenter
        case .viewer: self = .viewer
        default: return nil
        }
    }
}

extension LibraryDocument {
    init(_ document: Wiretuner_Docs_V1_Document, sharedWithMe: Bool = false) {
        self.init(
            id: document.id, spaceID: document.spaceID, folderID: document.folderID.isEmpty ? nil : document.folderID,
            name: document.name, role: Role(document.callerRole),
            updatedAt: document.hasUpdatedAt ? document.updatedAt.date : nil,
            thumbnail: document.thumbnailBlob.isEmpty ? nil : document.thumbnailBlob.hexString,
            thumbnailAt: document.hasThumbnailAt ? document.thumbnailAt.date : nil,
            isTrashed: document.hasTrashedAt, isSharedWithMe: sharedWithMe
        )
    }
}

extension LibraryFolder {
    init(_ folder: Wiretuner_Docs_V1_Folder) {
        self.init(id: folder.id, spaceID: folder.spaceID, parentID: folder.parentFolderID.isEmpty ? nil : folder.parentFolderID, name: folder.name)
    }
}

extension LibrarySearchField {
    init(_ field: Wiretuner_Docs_V1_SearchField) {
        switch field {
        case .documentName: self = .documentName
        case .objectName: self = .objectName
        case .text: self = .text
        case .note: self = .note
        case .swatch: self = .swatch
        case .style: self = .style
        case .symbol: self = .symbol
        case .keyword: self = .keyword
        case .page: self = .page
        default: self = .other
        }
    }
}

extension LibrarySearchHit {
    init(_ hit: Wiretuner_Docs_V1_SearchHit) {
        self.init(documentID: hit.documentID, snippets: hit.matches.map { SearchSnippet(field: LibrarySearchField($0.field), highlighted: $0.highlighted) })
    }
}

extension LibraryPage {
    init(_ response: Wiretuner_Docs_V1_ListResponse, sharedWithMe: Bool) {
        self.init(
            documents: response.documents.map { LibraryDocument($0, sharedWithMe: sharedWithMe) },
            folders: response.folders.map(LibraryFolder.init),
            nextCursor: response.nextCursor.isEmpty ? nil : response.nextCursor
        )
    }
}

extension LibrarySpace {
    init(_ team: Wiretuner_Account_V1_Team) {
        self.init(id: team.id, name: team.name, kind: .team)
    }
}

extension LibrarySearchPage {
    init(_ response: Wiretuner_Docs_V1_SearchResponse) {
        self.init(hits: response.hits.map(LibrarySearchHit.init), nextCursor: response.nextCursor.isEmpty ? nil : response.nextCursor)
    }
}

/// A response the gRPC client turns into the app's type with `mapped` (tested on its own
/// with proto messages, so the client's calls stay one line each).
protocol LibraryResponse: Sendable {
    associatedtype Mapped
    var mapped: Mapped { get }
}

extension Wiretuner_Docs_V1_ListResponse: LibraryResponse {
    var mapped: LibraryPage { LibraryPage(self, sharedWithMe: false) }
}

extension Wiretuner_Docs_V1_GetResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_CreateResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_RenameResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_TrashResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_DuplicateResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_MoveToFolderResponse: LibraryResponse {
    var mapped: LibraryDocument { LibraryDocument(document) }
}

extension Wiretuner_Docs_V1_SearchResponse: LibraryResponse {
    var mapped: LibrarySearchPage { LibrarySearchPage(hits: hits.map(LibrarySearchHit.init), nextCursor: nextCursor.isEmpty ? nil : nextCursor) }
}

extension Wiretuner_Docs_V1_CreateFolderResponse: LibraryResponse {
    var mapped: LibraryFolder { LibraryFolder(folder) }
}

extension Wiretuner_Docs_V1_RenameFolderResponse: LibraryResponse {
    var mapped: LibraryFolder { LibraryFolder(folder) }
}

extension Wiretuner_Docs_V1_DeleteFolderResponse: LibraryResponse {
    var mapped: Void { () }
}

extension Wiretuner_Account_V1_ListTeamsResponse: LibraryResponse {
    var mapped: [LibrarySpace] { teams.map(LibrarySpace.init) }
}

/// A download's frames: the content is every chunk in order.
extension Array: LibraryResponse where Element == Wiretuner_Blob_V1_DownloadResponse {
    var mapped: Data { LibraryRequests.content(of: self) }
}

/// The request messages, built apart from the calls so they are tested without a server.
enum LibraryRequests {
    static func list(_ request: LibraryListRequest) -> Wiretuner_Docs_V1_ListRequest {
        var message = Wiretuner_Docs_V1_ListRequest()
        message.spaceID = request.spaceID ?? ""
        switch request.scope {
        case let .folder(folderID):
            message.scope = .folder
            message.folderID = folderID ?? ""
        case .sharedWithMe:
            message.scope = .sharedWithMe
            message.spaceID = ""
        }
        message.cursor = request.cursor ?? ""
        message.pageSize = UInt32(LibraryListRequest.pageSize)
        return message
    }

    static func create(_ document: LibraryDocument) -> Wiretuner_Docs_V1_CreateRequest {
        var message = Wiretuner_Docs_V1_CreateRequest()
        message.documentID = document.id
        message.spaceID = document.spaceID
        message.folderID = document.folderID ?? ""
        message.name = document.name
        message.kind = .illustrationMultiPage
        return message
    }

    static func search(query: String, spaceID: String, cursor: String?) -> Wiretuner_Docs_V1_SearchRequest {
        var message = Wiretuner_Docs_V1_SearchRequest()
        message.query = query
        message.spaceID = spaceID
        message.cursor = cursor ?? ""
        message.pageSize = 50
        return message
    }

    static func duplicate(documentID: String, newDocumentID: String, name: String) -> Wiretuner_Docs_V1_DuplicateRequest {
        var message = Wiretuner_Docs_V1_DuplicateRequest()
        message.documentID = documentID
        message.newDocumentID = newDocumentID
        message.name = name
        return message
    }

    static func move(documentID: String, spaceID: String, folderID: String?) -> Wiretuner_Docs_V1_MoveToFolderRequest {
        var message = Wiretuner_Docs_V1_MoveToFolderRequest()
        message.documentID = documentID
        message.spaceID = spaceID
        message.folderID = folderID ?? ""
        return message
    }

    static func createFolder(spaceID: String, parentFolderID: String?, name: String) -> Wiretuner_Docs_V1_CreateFolderRequest {
        var message = Wiretuner_Docs_V1_CreateFolderRequest()
        message.spaceID = spaceID
        message.parentFolderID = parentFolderID ?? ""
        message.name = name
        return message
    }

    static func download(documentID: String, sha256: Data) -> Wiretuner_Blob_V1_DownloadRequest {
        var message = Wiretuner_Blob_V1_DownloadRequest()
        message.documentID = documentID
        message.sha256 = sha256
        return message
    }

    /// Reads a download stream to the end.
    @Sendable
    static func collect(_ response: StreamingClientResponse<Wiretuner_Blob_V1_DownloadResponse>) async throws -> [Wiretuner_Blob_V1_DownloadResponse] {
        var frames: [Wiretuner_Blob_V1_DownloadResponse] = []
        for try await frame in response.messages { frames.append(frame) }
        return frames
    }

    /// The content of a download stream: every chunk in order (the info frame carries no
    /// bytes).
    static func content(of frames: [Wiretuner_Blob_V1_DownloadResponse]) -> Data {
        var data = Data()
        for frame in frames {
            if case let .chunk(chunk)? = frame.frame { data.append(chunk) }
        }
        return data
    }
}
