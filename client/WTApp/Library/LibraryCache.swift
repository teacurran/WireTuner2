import AppKit
import CryptoKit
import Foundation

/// A document opened on this Mac, newest first in `LibraryCacheFile.recents`.
struct LibraryRecent: Codable, Equatable, Sendable {
    var documentID: String
    var openedAt: Date
}

/// The library as last seen, so the window works offline (creating-opening.adoc, "Offline
/// behavior"): spaces, every document and folder listed, recents, and which documents have
/// a copy on this Mac.  Until SYNC-001 gives every opened document a local store, "opened on
/// this Mac" is what makes a document offline-available.
struct LibraryCacheFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// Recents kept locally; menu:File[Open Recent] shows ten of them (DOC-020).
    static let recentsLimit = 50

    var version = LibraryCacheFile.currentVersion
    /// The account id: the personal space.
    var personalSpaceID: String?
    var teams: [LibrarySpace] = []
    var documents: [String: LibraryDocument] = [:]
    var folders: [String: LibraryFolder] = [:]
    var recents: [LibraryRecent] = []
    var offlineAvailable: Set<String> = []

    init() {}

    /// Replaces what a `List` of `scope` in `spaceID` returned last time with `page`'s
    /// documents (a document no longer listed there has moved or gone); keeps local-only
    /// documents waiting to upload.
    mutating func apply(_ page: LibraryPage, scope: LibraryListRequest.Scope, spaceID: String?, firstPage: Bool) {
        if firstPage {
            documents = documents.filter { _, document in
                document.isPendingUpload || !Self.matches(document, scope: scope, spaceID: spaceID)
            }
            if case let .folder(parent) = scope {
                folders = folders.filter { $0.value.spaceID != spaceID || $0.value.parentID != parent }
            }
        }
        for document in page.documents { documents[document.id] = document }
        for folder in page.folders { folders[folder.id] = folder }
    }

    static func matches(_ document: LibraryDocument, scope: LibraryListRequest.Scope, spaceID: String?) -> Bool {
        switch scope {
        case let .folder(folderID): !document.isSharedWithMe && document.spaceID == spaceID && document.folderID == folderID
        case .sharedWithMe: document.isSharedWithMe
        case .templates: !document.isSharedWithMe && document.spaceID == spaceID && document.isTemplate
        }
    }

    /// The cached documents a `List` of `scope` would return, by name.
    func documents(in scope: LibraryListRequest.Scope, spaceID: String?) -> [LibraryDocument] {
        documents.values.filter { !$0.isTrashed && Self.matches($0, scope: scope, spaceID: spaceID) }.sorted(by: Self.byName)
    }

    func folders(in spaceID: String?, parent: String?) -> [LibraryFolder] {
        folders.values.filter { $0.spaceID == spaceID && $0.parentID == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Recently opened documents that are still known and not trashed.
    var recentDocuments: [LibraryDocument] {
        recents.compactMap { documents[$0.documentID] }.filter { !$0.isTrashed }
    }

    /// Records an open: the document moves to the top of the recents and is offline-available.
    mutating func markOpened(_ document: LibraryDocument, at date: Date) {
        documents[document.id] = document
        recents.removeAll { $0.documentID == document.id }
        recents.insert(LibraryRecent(documentID: document.id, openedAt: date), at: 0)
        if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
        offlineAvailable.insert(document.id)
    }

    static func byName(_ lhs: LibraryDocument, _ rhs: LibraryDocument) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}

/// Reads and writes `LibraryCacheFile` as JSON: `~/Library/Application Support/WireTuner/
/// Library.json` (inside the sandbox container).
struct LibraryCacheStore: Sendable {
    static let fileName = "Library.json"

    let url: URL

    static var defaultURL: URL {
        PanelLayoutStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The saved cache; empty when there is none, it is unreadable or another version wrote it.
    func load() -> LibraryCacheFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(LibraryCacheFile.self, from: data),
            file.version == LibraryCacheFile.currentVersion
        else { return LibraryCacheFile() }
        return file
    }

    func save(_ file: LibraryCacheFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}

/// Downloaded thumbnails on disk, one PNG per blob, named by its sha256
/// (`WireTuner/Thumbnails/<hex>.png`).  Content-addressed, so an entry never goes stale; a
/// changed thumbnail is a new hash.  Without a directory (tests) it keeps them in memory.
@MainActor
final class ThumbnailCache {
    static let directoryName = "Thumbnails"

    let directory: URL?
    private var memory: [String: Data] = [:]
    private var images: [String: NSImage] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        PanelLayoutStore.defaultURL.deletingLastPathComponent().appending(path: directoryName)
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    func fileURL(for hash: String) -> URL? {
        directory?.appending(path: "\(hash).png")
    }

    func data(for hash: String) -> Data? {
        if let data = memory[hash] { return data }
        return fileURL(for: hash).flatMap { try? Data(contentsOf: $0) }
    }

    func contains(_ hash: String) -> Bool { data(for: hash) != nil }

    /// Stores `data` under `hash` after checking it hashes to it.
    func store(_ data: Data, for hash: String) throws {
        guard Self.sha256Hex(data) == hash.lowercased() else { throw LibraryClientError.hashMismatch }
        if let url = fileURL(for: hash) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else {
            memory[hash] = data
        }
        images[hash] = nil
    }

    /// The decoded picture, kept after the first read.
    func image(for hash: String) -> NSImage? {
        if let image = images[hash] { return image }
        guard let data = data(for: hash), let image = NSImage(data: data) else { return nil }
        images[hash] = image
        return image
    }
}
