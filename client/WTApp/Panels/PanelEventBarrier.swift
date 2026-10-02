import AppKit

/// The root of something the window lays over the canvas -- a dock, a cluster of panels (docked
/// or floating), a dock handle, the status bar -- where every mouse, scroll and trackpad gesture
/// event that reaches it unhandled stops.
///
/// Found in use (2026-10-02): AppKit passes an event no view takes on up the responder chain,
/// and from the content view it reaches the view underneath -- the canvas, which runs under the
/// docks (D-077).  A SwiftUI button (the Tools panel's) passes its mouse-down on as well, without
/// the mouse-up.  So a click on a tool pressed the canvas under the panel and left it pressed (a
/// drag that never ended, auto-scrolling toward the panel), a right-click on a panel opened the
/// canvas's context menu, and a scroll over a title bar panned the artboard.  The events end here
/// instead; the controls inside still handle theirs first.
@MainActor
class PanelEventBarrierView: NSView {
    /// The events the barrier stopped (tests and diagnostics).
    private(set) var stoppedEvents = 0

    private func stop(_ event: NSEvent) { stoppedEvents += 1 }

    override func mouseDown(with event: NSEvent) { stop(event) }
    override func mouseDragged(with event: NSEvent) { stop(event) }
    override func mouseUp(with event: NSEvent) { stop(event) }
    override func rightMouseDown(with event: NSEvent) { stop(event) }
    override func rightMouseDragged(with event: NSEvent) { stop(event) }
    override func rightMouseUp(with event: NSEvent) { stop(event) }
    override func otherMouseDown(with event: NSEvent) { stop(event) }
    override func otherMouseDragged(with event: NSEvent) { stop(event) }
    override func otherMouseUp(with event: NSEvent) { stop(event) }
    override func scrollWheel(with event: NSEvent) { stop(event) }
    override func magnify(with event: NSEvent) { stop(event) }
    override func rotate(with event: NSEvent) { stop(event) }
    override func smartMagnify(with event: NSEvent) { stop(event) }
    override func swipe(with event: NSEvent) { stop(event) }
    override func pressureChange(with event: NSEvent) { stop(event) }
}
