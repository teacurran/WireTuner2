import Foundation
import WTGeometry
import WTRender

/// What a document window restores when the document is opened again on this Mac: the frame
/// and the view's `ViewState` (document-view.adoc, "Data model"): magnification, scroll
/// position, rotation, drawing mode, the snap toggles, page rulers and the current page
/// (workspace.adoc, "Magnification and the canvas").  Local only: never part of the document.
struct DocumentWindowState: Codable, Equatable, Sendable {
    /// Window frame in screen points; nil when unknown.
    var frame: LayoutRect?
    var zoom: Double
    var scrollX: Double
    var scrollY: Double
    /// BASIC-034 writes it; restored with the rest so the angle survives reopening.
    var rotationDegrees: Double
    var viewMode: ViewMode
    /// The snap toggles (BASIC-009); nil in files written before them.
    var snap: SnapSettings?
    /// `ViewState.current_page`: the page's frame until pages have ids, so a page deleted
    /// meanwhile falls back to the nearest remaining one by pasteboard distance (BASIC-016).
    var currentPageFrame: LayoutRect?
    /// `ViewState.page_rulers` (View > Page Rulers > Show); nil reads as shown.
    var pageRulers: Bool?

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

    /// The index of the page nearest the saved current page among `pages` (nil when there
    /// are none or nothing was saved): the saved page itself when it still exists.
    func currentPageIndex(among pages: [Rect]) -> Int? {
        guard let frame = currentPageFrame, !pages.isEmpty else { return nil }
        let centre = Point(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        return pages.indices.min { pages[$0].center.distance(to: centre) < pages[$1].center.distance(to: centre) }
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

/// One window of the session at quit (workspace.adoc, `WindowState`): restored when the app
/// relaunches, keyed by document id.
struct WindowState: Codable, Equatable, Sendable {
    var documentID: String
    /// The name to show until the document is loaded.
    var title: String
    var frame: LayoutRect?
    /// Windows with the same number were tabs of one window.
    var tabGroup: Int
    var tabIndex: Int
    /// Was the key window at quit.
    var key: Bool
}

/// The session as one JSON file beside the window states (`WireTuner/Session.json`).
struct SessionStore: Sendable {
    static let fileName = "Session.json"

    let url: URL

    static var defaultURL: URL {
        WindowStateStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The saved session; empty when there is none or it is unreadable.
    func load() -> [WindowState] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WindowState].self, from: data)) ?? []
    }

    func save(_ states: [WindowState]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(states).write(to: url, options: .atomic)
    }
}
