import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Comment tool (kbd:[C]; comments.adoc, "Adding a comment"): a click on an object starts a
/// thread attached to it, a click on empty space a point pin; a click on a pin opens its thread;
/// dragging a pin (one the caller may move) drops it on another object or on empty space.  A
/// viewer's clicks do nothing.
@MainActor
final class CommentTool: Tool {
    static let id: ToolID = "comment"
    /// A press that moves less than this (view points) is a click.
    static let dragThreshold = 3.0

    let lookup: @MainActor (DocumentHandle) -> WindowComments?
    private(set) var context: ToolContext?
    /// The pin being pressed or dragged, and where the press started.
    private(set) var pressed: (thread: OpID, start: Point)?
    /// Where a dragged pin is (pasteboard), for the overlay.
    private(set) var dragPoint: Point?

    init(lookup: @escaping @MainActor (DocumentHandle) -> WindowComments?) {
        self.lookup = lookup
    }

    static func descriptor(lookup: @escaping @MainActor (DocumentHandle) -> WindowComments?) -> ToolDescriptor {
        ToolDescriptor(id: id, title: "Comment", symbolName: "text.bubble", shortcut: KeyEquivalent("c"), helpSlug: "comments") {
            CommentTool(lookup: lookup)
        }
    }

    var comments: WindowComments? { context.flatMap { lookup($0.document) } }
    var cursor: NSCursor { comments?.permissions.canComment == false ? .operationNotAllowed : .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage("Click an object or an empty spot to comment; drag a pin to move it")
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context, let comments else { return }
        if let thread = comments.thread(atView: e.viewPoint, viewport: context.host.viewport) {
            pressed = (thread.id, e.viewPoint)
        }
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let pressed, let comments, let thread = comments.model[pressed.thread], comments.permissions.canMove(thread) else { return }
        if dragPoint != nil || hypot(e.viewPoint.x - pressed.start.x, e.viewPoint.y - pressed.start.y) > Self.dragThreshold {
            dragPoint = e.pasteboardPoint
            context?.host.setNeedsOverlayDisplay()
        }
    }

    func mouseUp(_ e: CanvasEvent) {
        guard let context, let comments else { return }
        defer {
            pressed = nil
            dragPoint = nil
            context.host.setNeedsOverlayDisplay()
        }
        if let pressed {
            if dragPoint != nil {
                comments.movePin(pressed.thread, to: e.pasteboardPoint, on: anchor(at: e.viewPoint, context: context))
            } else {
                comments.open(pressed.thread)
            }
            return
        }
        guard comments.permissions.canComment else { return }
        comments.begin(at: e.pasteboardPoint, on: anchor(at: e.viewPoint, context: context))
    }

    /// The top-level object under `viewPoint`, if any.
    func anchor(at viewPoint: Point, context: ToolContext) -> OpID? {
        context.selection.pick(at: viewPoint, viewport: context.host.viewport, subselect: false)?.id.opID
    }

    func flagsChanged(_ e: CanvasEvent) {}

    func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 53, let comments, comments.pending != nil else { return false }
        comments.discardPending()
        return true
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let dragPoint, let pressed, let comments, let thread = comments.model[pressed.thread] else { return }
        WindowComments.drawPin(in: ctx, at: viewport.toView(dragPoint), label: "\(thread.number)", color: WindowComments.color(of: thread.opener.author),
                               unread: false, open: true)
    }

    func cancel() {
        pressed = nil
        dragPoint = nil
    }

    var hasSomethingToCancel: Bool { pressed != nil || comments?.pending != nil }
}

extension CommentTool: PointerTracking {
    /// Hovering a pin shows its first line.
    func pointerMoved(_ e: CanvasEvent) {
        guard let context, let comments else { return }
        comments.hovered = comments.thread(atView: e.viewPoint, viewport: context.host.viewport)?.id
    }
}

/// The renderer's colour, named apart from SwiftUI's for the files that import both.
typealias PinColor = Color

extension CanvasView {
    /// The scale an overlay layer of the canvas draws at: its window's backing scale.
    var overlayScale: CGFloat { window?.backingScaleFactor ?? 2 }
}
