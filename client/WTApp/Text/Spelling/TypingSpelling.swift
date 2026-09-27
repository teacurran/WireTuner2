import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// *Check spelling while typing* on the canvas (editing-text.adoc, "Checking spelling"; TYPE-014):
/// the Text tool's block has its questionable words underlined in red, the check run again only
/// when the block changes.
@MainActor
final class TypingSpelling {
    /// Weak: the underlines can be asked for after the window closed.
    weak var window: DocumentWindowController?
    var checker: @MainActor () -> SpellingChecker
    var isOn: @MainActor () -> Bool
    private var cache: (node: OpID, revision: Int, issues: [SpellingIssue])?

    init(window: DocumentWindowController, checker: @escaping @MainActor () -> SpellingChecker, isOn: @escaping @MainActor () -> Bool) {
        self.window = window
        self.checker = checker
        self.isOn = isOn
    }

    /// The issues of the Text tool's block (cached per block and session revision).
    func issues() -> [SpellingIssue] {
        guard isOn(), let session = window?.objectEditing.textSession, let node = session.node, let text = session.text else { return [] }
        if let cache, cache.node == node, cache.revision == session.revision { return cache.issues }
        let issues = checker().issues(in: text)
        cache = (node, session.revision, issues)
        return issues
    }

    /// The underlines, one per line of each issue, view points.
    func underlines(viewport: Viewport) -> [(from: Point, to: Point)] {
        guard let session = window?.objectEditing.textSession, let layout = session.layout else { return [] }
        let toView = session.toPasteboard.concatenating(viewport.pasteboardToView)
        return issues().flatMap { issue in
            layout.selection(from: issue.range.lowerBound, to: issue.range.upperBound).map { quad in
                let corners = quad.corners
                return (toView.apply(corners[3]), toView.apply(corners[2]))
            }
        }
    }

    func draw(in ctx: CGContext, viewport: Viewport) {
        let lines = underlines(viewport: viewport)
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        for line in lines {
            ctx.move(to: line.from.cgPoint)
            ctx.addLine(to: line.to.cgPoint)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
