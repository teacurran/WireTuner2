import Foundation
import WTGeometry
import WTRender

/// What a document window restores when the document is opened again on this Mac: frame,
/// magnification, scroll position, rotation and drawing mode (workspace.adoc, "Magnification
/// and the canvas"; `ViewState` and `WindowState` in document-view.adoc and workspace.adoc).
/// Local only: never part of the document.
struct DocumentWindowState: Codable, Equatable, Sendable {
    /// Window frame in screen points; nil when unknown.
    var frame: LayoutRect?
    var zoom: Double
    var scrollX: Double
    var scrollY: Double
    /// BASIC-034 writes it; restored with the rest so the angle survives reopening.
    var rotationDegrees: Double
    var viewMode: ViewMode

    init(frame: LayoutRect? = nil, zoom: Double = 1, scrollX: Double = 0, scrollY: Double = 0, rotationDegrees: Double = 0, viewMode: ViewMode = .preview) {
        self.frame = frame
        self.zoom = zoom
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.rotationDegrees = rotationDegrees
        self.viewMode = viewMode
    }

    init(frame: LayoutRect?, viewport: Viewport, viewMode: ViewMode) {
        self.init(
            frame: frame, zoom: viewport.zoom, scrollX: viewport.scrollOrigin.x, scrollY: viewport.scrollOrigin.y,
            rotationDegrees: viewport.rotationDegrees, viewMode: viewMode
        )
    }

    /// The stored view applied to a viewport of `size`.
    func viewport(size: Size) -> Viewport {
        Viewport(scrollOrigin: Point(x: scrollX, y: scrollY), rotationDegrees: rotationDegrees, zoom: zoom, size: size)
    }
}

/// Window state per document id, as one JSON file in Application Support
/// (`WireTuner/WindowState.json`, inside the sandbox container).  BASIC-016 moves the view
/// state into the local store's `view` table when SYNC-001 lands.
struct WindowStateStore: Sendable {
    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    static let fileName = "WindowState.json"
    static let currentVersion = 1

    private struct File: Codable {
        var version: Int
        var documents: [String: DocumentWindowState]
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: PanelLayoutStore.directoryName).appending(path: fileName)
    }

    /// Every saved state; empty when nothing was saved yet.
    func loadAll() throws -> [String: DocumentWindowState] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.version == Self.currentVersion else { throw Failure.unsupportedVersion(file.version) }
        return file.documents
    }

    /// The state saved for `documentID`; nil when none or the file is unreadable.
    func state(for documentID: String) -> DocumentWindowState? {
        (try? loadAll())?[documentID]
    }

    /// Saves `state` for `documentID`, keeping every other document's.  An unreadable file is
    /// replaced.
    func save(_ state: DocumentWindowState, for documentID: String) throws {
        var documents = (try? loadAll()) ?? [:]
        documents[documentID] = state
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: Self.currentVersion, documents: documents)).write(to: url, options: .atomic)
    }

    func removeState(for documentID: String) throws {
        var documents = try loadAll()
        guard documents.removeValue(forKey: documentID) != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: Self.currentVersion, documents: documents)).write(to: url, options: .atomic)
    }
}
