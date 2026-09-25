import AppKit
import SwiftUI

/// An angle dial (the Halftones panel's, halftones.adoc; PRINT-010; and the effect dialogs'): a round
/// control whose pointer follows the mouse around its centre, 0° pointing right and angles
/// counter-clockwise; kbd:[Shift] snaps to 15° steps.  The dial previews while it is dragged and
/// commits once on mouse-up, so a drag is one change.
final class PointerDialControl: NSControl {
    /// The angle shown, degrees in 0..<360.
    var angle: Double = 0 {
        didSet { needsDisplay = true }
    }

    /// Whether the value is mixed across the selection (no pointer drawn).
    var isMixed = false {
        didSet { needsDisplay = true }
    }

    /// Called with the angle when a drag or click ends.
    var onCommit: ((Double) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The angle (degrees, 0..<360, counter-clockwise from the positive x axis) of `point`
    /// around `center`, snapped to 15° when `snap`.
    static func angle(of point: CGPoint, around center: CGPoint, snap: Bool) -> Double {
        let radians = atan2(point.y - center.y, point.x - center.x)
        var degrees = radians * 180 / .pi
        if snap { degrees = (degrees / 15).rounded() * 15 }
        return (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    /// Tracks a press at `point` (view coordinates): the angle follows it.
    func track(_ point: CGPoint, shift: Bool) {
        isMixed = false
        angle = Self.angle(of: point, around: center, snap: shift)
    }

    /// Ends a press: the angle is committed.
    func finish() {
        onCommit?(angle)
    }

    override func mouseDown(with event: NSEvent) {
        track(convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        track(convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        track(convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift))
        finish()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.drawDial(in: ctx, bounds: bounds, angle: isMixed ? nil : angle)
    }

    /// The dial: a ring, a tick every 45° and the pointer (none when mixed).
    static func drawDial(in ctx: CGContext, bounds: CGRect, angle: Double?) {
        let radius = min(bounds.width, bounds.height) / 2 - 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        for step in 0..<8 {
            let a = Double(step) * .pi / 4
            ctx.move(to: CGPoint(x: center.x + cos(a) * (radius - 3), y: center.y + sin(a) * (radius - 3)))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        }
        ctx.strokePath()
        if let angle {
            let a = angle * .pi / 180
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: center)
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * (radius - 2), y: center.y + sin(a) * (radius - 2)))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { isMixed ? "Mixed" : "\(Int(angle.rounded()))°" }
    override func accessibilityPerformIncrement() -> Bool { step(15) }
    override func accessibilityPerformDecrement() -> Bool { step(-15) }

    /// Steps the angle by `delta` degrees and commits it (VoiceOver's increment and decrement).
    @discardableResult
    func step(_ delta: Double) -> Bool {
        isMixed = false
        angle = ((angle + delta).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        finish()
        return true
    }
}

/// The dial in SwiftUI: shows `angle` (nil: mixed), commits through `commit`.
struct PointerDial: NSViewRepresentable {
    let angle: Double?
    let identifier: String
    let commit: (Double) -> Void

    func makeNSView(context: Context) -> PointerDialControl {
        let control = PointerDialControl()
        control.setAccessibilityIdentifier(identifier)
        update(control)
        return control
    }

    func updateNSView(_ control: PointerDialControl, context: Context) {
        update(control)
    }

    func update(_ control: PointerDialControl) {
        control.isMixed = angle == nil
        control.angle = angle ?? 0
        control.onCommit = commit
    }
}
