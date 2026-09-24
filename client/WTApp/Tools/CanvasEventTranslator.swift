import AppKit
import WTGeometry
import WTRender

/// Turns AppKit's view coordinates and event fields into `CanvasEvent`s.  Pure: the canvas
/// view hands over numbers, so the translation is tested without events or windows.
///
/// `CanvasView` is not flipped (its layer tree must not be geometry-flipped, see
/// `TiledCanvasLayer`), so AppKit gives y-up points; view space is y-down.
enum CanvasEventTranslator {
    /// AppKit view point (y up, origin bottom-left) → view point (y down, origin top-left).
    static func viewPoint(fromAppKit point: CGPoint, viewHeight: Double) -> Point {
        Point(x: Double(point.x), y: viewHeight - Double(point.y))
    }

    static func event(
        appKitPoint: CGPoint, viewHeight: Double, viewport: Viewport, modifierFlags: NSEvent.ModifierFlags,
        pressure: Float, clickCount: Int, timestamp: TimeInterval, isTablet: Bool = false
    ) -> CanvasEvent {
        let viewPoint = viewPoint(fromAppKit: appKitPoint, viewHeight: viewHeight)
        return CanvasEvent(
            pasteboardPoint: viewport.toPasteboard(viewPoint),
            viewPoint: viewPoint,
            modifiers: KeyEquivalentResolver.modifiers(modifierFlags),
            pressure: normalizedPressure(pressure, isTablet: isTablet),
            clickCount: max(clickCount, 1),
            timestamp: timestamp,
            isTablet: isTablet
        )
    }

    /// A mouse press reports 1; a tablet reports its pressure; zero from a mouse (a drag
    /// event with no pressure data) reads as 1.
    static func normalizedPressure(_ pressure: Float, isTablet: Bool) -> Double {
        let value = Double(pressure)
        guard value.isFinite else { return 1 }
        if isTablet { return min(max(value, 0), 1) }
        return value > 0 ? min(value, 1) : 1
    }

    /// Lines to points for a wheel mouse without precise deltas.
    static let pointsPerLine = 10.0

    /// A scroll-wheel event's pan in view points (the delta to scroll by: content moves the
    /// other way).  Shift on a wheel mouse turns vertical into horizontal.
    static func scrollDelta(deltaX: Double, deltaY: Double, hasPreciseDeltas: Bool, shift: Bool) -> Vector {
        let scale = hasPreciseDeltas ? 1 : pointsPerLine
        var dx = -deltaX * scale
        var dy = -deltaY * scale
        if shift, !hasPreciseDeltas, dx == 0 {
            dx = dy
            dy = 0
        }
        return Vector(dx: dx, dy: dy)
    }

    /// Option-scroll zoom: the factor one scroll event multiplies the zoom by.
    static func scrollZoomFactor(deltaY: Double, hasPreciseDeltas: Bool) -> Double {
        let lines = hasPreciseDeltas ? deltaY / pointsPerLine : deltaY
        return pow(1.1, lines)
    }

    /// Pinch: `NSEvent.magnification` is the change as a fraction.
    static func pinchFactor(magnification: Double) -> Double {
        max(1 + magnification, 0.01)
    }

    /// The key a key-down means for shortcut lookup; nil for multi-character input.
    static func shortcut(charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) -> KeyEquivalent? {
        guard let characters = charactersIgnoringModifiers else { return nil }
        return KeyEquivalentResolver.keyEquivalent(charactersIgnoringModifiers: characters, modifierFlags: modifierFlags)
    }

    /// The Space bar, which pushes the Hand (and with Command the Zoom tool).
    static let spaceKeyCode: UInt16 = 49
    static let escapeKeyCode: UInt16 = 53
}
