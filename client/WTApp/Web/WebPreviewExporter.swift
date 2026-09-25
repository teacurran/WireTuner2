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
        let exportPages = document.pageList.exportPages
        let request = ExportSnapshot.Request(name: document.title, pages: exportPages, scope: .pages(indices), includePageBoundary: true,
                                             pageColor: .white, animation: true)
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("preview-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        let blobs = blobs
        var scene = ExportSnapshot.capture(document.state, request: request, builder: builder, blob: { blobs.cached($0) }).scene
        scene.textLinks = ExportSnapshot.textLinks(document.state, engine: document.textEngine)
        return scene
    }

    func exportPreview(of document: DocumentHandle, pageIndex: Int, into directory: URL) throws -> URL {
        let count = document.pageList.exportPages.count
        let all = Self.hasInteractions(document)
        let current = min(max(pageIndex, 0), max(count - 1, 0))
        let indices = all ? Array(0..<count) : [current]
        let settings = HTMLSettings(document.state).selected.settings
        let bundle = try HTMLPublisher(settings: settings).publish(scene(of: document, pages: indices))
        let written = try bundle.write(to: directory)
        // The current page's file: `index.html` holds the first page (or all of them, stacked).
        let page = all && current > 0 ? "page-\(current + 1).html" : "index.html"
        let name = written.contains(page) ? page : "index.html"
        return directory.appending(path: name)
    }
}
