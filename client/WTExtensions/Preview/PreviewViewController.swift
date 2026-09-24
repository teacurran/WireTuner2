import AppKit
import QuickLookUI

/// The Quick Look preview of a `.wiretuner` package (saving.adoc, "Quick Look and Spotlight";
/// IO-034): the title, who exported it and when and the unsynced note over page 1 of
/// `preview.pdf`, or over the thumbnail when the package has no preview (`PackagePeek`).
final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let peek = try PackagePeek(url: url)
        let content = peek.previewView(frame: view.bounds)
        content.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(content)
    }
}
