import Foundation
import WTCRDT
import WTInterchange
import WTModel
import WTRender

/// menu:View[Preview in Browser]'s exporter (document-view.adoc, "Preview in Browser"; BASIC-017
/// over WEB-009's publisher): the current page -- or every page when the document has links or
/// an animation, so page links work -- published with the document's selected HTML setting into
/// the preview folder, and the page's file to open.  Local: no network.
@MainActor
final class WebPreviewExporter: BrowserPreviewExporter {
    /// The blobs the snapshot reads.
    var blobs: BlobPlacement
    /// The last export's output warnings and not-yet-downloaded files (WEB-029).
    private(set) var warnings: [String] = []

    init(blobs: BlobPlacement = BlobPlacement()) {
        self.blobs = blobs
    }

    /// Whether the whole document goes: it has links or frames to follow.
    static func hasInteractions(_ document: DocumentHandle) -> Bool {
        let state = document.state
        return !LinkIndex(state).carriers.isEmpty || !AnimationInfo(state).frames(pages: document.pages).isEmpty
    }

    /// The scene of the pages at `indices`.
    func scene(of document: DocumentHandle, pages indices: [Int]) -> ExportScene {
        snapshot(of: document, pages: indices).scene
    }

    /// The snapshot of the pages at `indices` (the scene, and the placed files not on this Mac).
    func snapshot(of document: DocumentHandle, pages indices: [Int]) -> ExportSnapshot {
        let exportPages = document.pageList.exportPages
        let request = ExportSnapshot.Request(name: document.title, pages: exportPages, scope: .pages(indices), includePageBoundary: true,
                                             pageColor: .white, animation: true)
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("preview-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        let blobs = blobs
        var snapshot = ExportSnapshot.capture(document.state, request: request, builder: builder, blob: { blobs.cached($0) })
        snapshot.scene.textLinks = ExportSnapshot.textLinks(document.state, engine: document.textEngine)
        return snapshot
    }

    func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL {
        try exportPreview(of: document, pageIndex: pageIndex, allPages: false, into: directory)
    }

    func exportPreview(of document: DocumentHandle, pageIndex: Int, allPages: Bool, into directory: URL) throws -> URL {
        let count = document.pageList.exportPages.count
        let all = allPages || Self.hasInteractions(document)
        let current = min(max(pageIndex, 0), max(count - 1, 0))
        let indices = all ? Array(0..<count) : [current]
        let settings = HTMLSettings(document.state).selected.settings
        let snapshot = snapshot(of: document, pages: indices)
        let bundle = try HTMLPublisher(settings: settings).publish(snapshot.scene)
        // As the Publish sheet lists them, then what is still downloading (offline or pending).
        warnings = bundle.warnings.sorted.map(\.message) + snapshot.missing.map { "“\($0)” is not downloaded yet; the preview shows its placeholder." }
        let written = try bundle.write(to: directory)
        // The current page's file: `index.html` holds the first page (or all of them, stacked).
        let page = all && current > 0 ? "page-\(current + 1).html" : "index.html"
        let name = written.contains(page) ? page : "index.html"
        return directory.appending(path: name)
    }
}
