import AppKit
import Foundation
import GRPCCore
@testable import WireTuner

/// An in-memory `DocumentService`/`TeamService`/`BlobService`/`AccountService` for library
/// tests: no network.  `offline` makes every call fail as a lost connection would.
final class FakeLibraryServer: LibraryDocumentClient, TeamListClient, BlobDownloadClient, AccountClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _offline = false
    private var _documents: [String: LibraryDocument] = [:]
    private var _folders: [String: LibraryFolder] = [:]
    private var _teams: [LibrarySpace] = []
    private var _blobs: [String: Data] = [:]
    private var _hits: [LibrarySearchHit] = []
    private var _calls: [String] = []
    private var _failure: (any Error)?
    private var _pageSize = 100
    var accountID = "a0000000-0000-4000-8000-000000000001"

    init() {}

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var offline: Bool {
        get { locked { _offline } }
        set { locked { _offline = newValue } }
    }

    var calls: [String] { locked { _calls } }
    var documents: [String: LibraryDocument] { locked { _documents } }

    /// The next call throws `error` (once).
    func failNext(with error: any Error) { locked { _failure = error } }
    func setPageSize(_ size: Int) { locked { _pageSize = size } }
    func put(_ document: LibraryDocument) { locked { _documents[document.id] = document } }
    func put(_ folder: LibraryFolder) { locked { _folders[folder.id] = folder } }
    func setTeams(_ teams: [LibrarySpace]) { locked { _teams = teams } }
    func setHits(_ hits: [LibrarySearchHit]) { locked { _hits = hits } }
    func putBlob(_ data: Data, as hash: String? = nil) -> String {
        let key = hash ?? ThumbnailCache.sha256Hex(data)
        locked { _blobs[key] = data }
        return key
    }

    private func enter(_ call: String) throws {
        try locked {
            _calls.append(call)
            if let failure = _failure {
                _failure = nil
                throw failure
            }
            if _offline { throw LibraryClientError.offline }
        }
    }

    private func document(_ id: String) throws -> LibraryDocument {
        guard let document = documents[id] else { throw RPCError(code: .notFound, message: "no document \(id)") }
        return document
    }

    func list(_ request: LibraryListRequest, accessToken: String) async throws -> LibraryPage {
        try enter("list")
        return locked {
            let all: [LibraryDocument]
            let folders: [LibraryFolder]
            switch request.scope {
            case let .folder(folderID):
                all = _documents.values.filter { !$0.isSharedWithMe && !$0.isTrashed && $0.spaceID == request.spaceID && $0.folderID == folderID }
                folders = _folders.values.filter { $0.spaceID == request.spaceID && $0.parentID == folderID }
            case .sharedWithMe:
                all = _documents.values.filter(\.isSharedWithMe)
                folders = []
            }
            let sorted = all.sorted { $0.id < $1.id }
            let start = Int(request.cursor ?? "0") ?? 0
            let end = min(start + _pageSize, sorted.count)
            return LibraryPage(documents: Array(sorted[start..<end]), folders: folders, nextCursor: end < sorted.count ? "\(end)" : nil)
        }
    }

    func get(documentID: String, accessToken: String) async throws -> LibraryDocument {
        try enter("get")
        return try document(documentID)
    }

    func search(query: String, spaceID: String, cursor: String?, accessToken: String) async throws -> LibrarySearchPage {
        try enter("search:\(query)")
        return LibrarySearchPage(hits: locked { _hits }, nextCursor: nil)
    }

    func create(_ document: LibraryDocument, accessToken: String) async throws -> LibraryDocument {
        try enter("create:\(document.name)")
        var created = document
        created.isPendingUpload = false
        put(created)
        return created
    }

    func rename(documentID: String, name: String, accessToken: String) async throws -> LibraryDocument {
        try enter("rename:\(name)")
        var document = try document(documentID)
        document.name = name
        put(document)
        return document
    }

    func trash(documentID: String, accessToken: String) async throws -> LibraryDocument {
        try enter("trash")
        var document = try document(documentID)
        document.isTrashed = true
        put(document)
        return document
    }

    func duplicate(documentID: String, newDocumentID: String, name: String, accessToken: String) async throws -> LibraryDocument {
        try enter("duplicate:\(name)")
        var copy = try document(documentID)
        copy.id = newDocumentID
        copy.name = name
        copy.thumbnail = nil
        put(copy)
        return copy
    }

    func move(documentID: String, spaceID: String, folderID: String?, accessToken: String) async throws -> LibraryDocument {
        try enter("move")
        var document = try document(documentID)
        document.spaceID = spaceID
        document.folderID = folderID
        put(document)
        return document
    }

    func createFolder(spaceID: String, parentFolderID: String?, name: String, accessToken: String) async throws -> LibraryFolder {
        try enter("createFolder:\(name)")
        let folder = LibraryFolder(id: "f-\(name)", spaceID: spaceID, parentID: parentFolderID, name: name)
        put(folder)
        return folder
    }

    func renameFolder(folderID: String, name: String, accessToken: String) async throws -> LibraryFolder {
        try enter("renameFolder:\(name)")
        return try locked {
            guard var folder = _folders[folderID] else { throw RPCError(code: .notFound, message: "") }
            folder.name = name
            _folders[folderID] = folder
            return folder
        }
    }

    func deleteFolder(folderID: String, accessToken: String) async throws {
        try enter("deleteFolder")
        locked { _folders[folderID] = nil }
    }

    func listTeams(accessToken: String) async throws -> [LibrarySpace] {
        try enter("listTeams")
        return locked { _teams }
    }

    func download(documentID: String, sha256: Data, accessToken: String) async throws -> Data {
        try enter("download")
        guard let data = locked({ _blobs[sha256.hexString] }) else { throw RPCError(code: .notFound, message: "") }
        return data
    }

    func me(accessToken: String) async throws -> AccountProfile {
        try enter("me")
        return AccountProfile(email: "p@example.com", displayName: "P", identities: [], devices: [], accountID: accountID)
    }

    /// Library services over this server; `signedIn` false throws `notSignedIn` for a token.
    func services(signedIn: Bool = true) -> LibraryServices {
        LibraryServices(documents: self, teams: self, blobs: self, account: self) {
            guard signedIn else { throw AuthError.notSignedIn }
            return "token"
        }
    }
}

/// A tiny valid PNG (1x1), for thumbnails.
enum TestPNG {
    static let data: Data = {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()
}
