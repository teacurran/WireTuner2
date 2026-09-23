import AppKit
import WTGeometry
import WTRender

/// Which continuous inputs are in progress on the canvas: pinch, two-finger rotate, and a
/// trackpad scroll with its momentum.  The canvas brackets the whole span with
/// `MetalTileCanvas.beginGesture`/`endGesture`, so the tiles are drawn through the changing
/// transform and re-rasterised when the last input settles (client.adoc, "Metal tile
/// renderer").  Pure: fed phases, not events, so it is tested without a trackpad.
struct CanvasGestureTracker: Equatable, Sendable {
    enum Source: Hashable, Sendable {
        case magnify, rotate, scroll, animation
    }

    /// What the canvas must tell the renderer after an update.
    enum Edge: Equatable, Sendable {
        case began, ended
    }

    private(set) var active: Set<Source> = []

    var isActive: Bool { !active.isEmpty }

    /// Folds one event's phases in.  A wheel mouse's discrete scroll (no phases) changes
    /// nothing.  Returns `.began` when the first input starts and `.ended` when the last stops.
    mutating func update(_ source: Source, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase = []) -> Edge? {
        let wasActive = isActive
        if Self.isRunning(phase) || Self.isRunning(momentumPhase) {
            active.insert(source)
        } else if Self.isStopping(momentumPhase) || (Self.isStopping(phase) && momentumPhase.isEmpty) {
            active.remove(source)
        }
        return edge(from: wasActive)
    }

    /// Starts or stops `source` outright (a programmatic animation).
    mutating func set(_ source: Source, running: Bool) -> Edge? {
        let wasActive = isActive
        if running { active.insert(source) } else { active.remove(source) }
        return edge(from: wasActive)
    }

    private func edge(from wasActive: Bool) -> Edge? {
        switch (wasActive, isActive) {
        case (false, true): .began
        case (true, false): .ended
        default: nil
        }
    }

    static func isRunning(_ phase: NSEvent.Phase) -> Bool {
        !phase.intersection([.began, .changed, .stationary, .mayBegin]).isEmpty
    }

    static func isStopping(_ phase: NSEvent.Phase) -> Bool {
        !phase.intersection([.ended, .cancelled]).isEmpty
    }
}

/// The canvas-rotation arithmetic (document-view.adoc, "Rotating the canvas"; BASIC-034).
enum CanvasRotation {
    /// The menu commands' step and the Shift snap.
    static let step = 15.0
    /// How long a menu rotation or Reset animates.
    static let animationDuration = 0.15

    /// The angle a two-finger rotate lands on: the angle at the start of the gesture plus the
    /// rotation accumulated so far, rounded to 15° while Shift is held.
    static func gestureAngle(start: Double, accumulated: Double, snapping: Bool) -> Double {
        let raw = start + accumulated
        return Viewport.normalizedDegrees(snapping ? (raw / step).rounded() * step : raw)
    }

    /// The shortest signed turn from `from` to `to` in degrees, in (-180, 180].
    static func shortestTurn(from: Double, to: Double) -> Double {
        Viewport.normalizedDegrees(to - from)
    }

    /// The viewport `fraction` of the way from `start` to the angle `target`, turning the short
    /// way about the view centre.  Zoom and the centre's pasteboard point stay put.
    static func interpolated(_ start: Viewport, toDegrees target: Double, fraction: Double) -> Viewport {
        let turn = shortestTurn(from: start.rotationDegrees, to: target)
        let clamped = min(max(fraction, 0), 1)
        return start.rotated(toDegrees: start.rotationDegrees + turn * clamped)
    }

    /// The compass label: the size of the turn ("45°" either way; the needle shows the
    /// direction), or nil when the canvas is straight (the compass hides).
    static func compassTitle(_ degrees: Double) -> String? {
        let normalized = Viewport.normalizedDegrees(degrees)
        guard abs(normalized) >= 0.05 else { return nil }
        let rounded = (abs(normalized) * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))°" : String(format: "%.1f°", rounded)
    }
}

/// Smart zoom (two-finger double-tap): fit the object under the pointer, else the page under
/// it; the next smart zoom returns to where the first one started.
struct SmartZoomState: Equatable, Sendable {
    /// The viewport before the last smart zoom in, while it is still the one to return to.
    private(set) var returnViewport: Viewport?

    /// Where a smart zoom goes from `viewport`.  `target` is the rectangle to fit (object or
    /// page); nil fits nothing and leaves the view alone.
    mutating func toggle(from viewport: Viewport, target: Rect?, navigation: CanvasNavigation) -> Viewport {
        if let back = returnViewport {
            returnViewport = nil
            var restored = back
            restored.size = viewport.size
            return navigation.clamped(restored)
        }
        guard let target else { return viewport }
        returnViewport = viewport
        return navigation.fit(viewport, rect: target)
    }

    /// Any other navigation forgets the way back.
    mutating func reset() { returnViewport = nil }
}
