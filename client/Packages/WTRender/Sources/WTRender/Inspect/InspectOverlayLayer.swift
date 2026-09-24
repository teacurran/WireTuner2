// The Inspect mode overlay (COLLAB-035; docs/_includes/collaboration/inspect.adoc, "Client"): a
// layer of its own above the canvas that draws `InspectMeasurements` in view space -- the hovered
// outline with its size, gap and edge lines with their lengths, an overlap, a point's
// coordinates -- at a constant on-screen size whatever the zoom.  It redraws on pointer moves only
// when what it shows changed, and it never touches the document's tiles: the tile canvas does not
// know it exists.

import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import WTGeometry

/// Draws measurements into a Core Graphics context in view coordinates (y down).
public enum InspectOverlayRenderer {
    /// Colors and sizes of the overlay.
    public struct Style: Sendable {
        public var outline: Color
        public var measure: Color
        public var overlapFill: Color
        public var labelBackground: Color
        public var labelText: Color
        public var lineWidth: Double
        public var tick: Double
        public var fontSize: Double

        public init(outline: Color, measure: Color, overlapFill: Color, labelBackground: Color, labelText: Color,
                    lineWidth: Double = 1, tick: Double = 4, fontSize: Double = 11) {
            self.outline = outline
            self.measure = measure
            self.overlapFill = overlapFill
            self.labelBackground = labelBackground
            self.labelText = labelText
            self.lineWidth = lineWidth
            self.tick = tick
            self.fontSize = fontSize
        }

        /// Blue outline, red measurements (the guide's screenshot).
        public static let standard = Style(outline: Color(red: 0.1, green: 0.45, blue: 1), measure: Color(red: 0.95, green: 0.2, blue: 0.25),
                                           overlapFill: Color(red: 0.95, green: 0.2, blue: 0.25, alpha: 0.2),
                                           labelBackground: Color(red: 0.95, green: 0.2, blue: 0.25), labelText: Color(white: 1))
    }

    /// Draws `measurements` as seen through `viewport`, values read with `format`.
    public static func draw(_ measurements: InspectMeasurements, format: InspectFormat, viewport: Viewport, in context: CGContext,
                            style: Style = .standard) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(style.lineWidth)
        if let overlap = measurements.overlap {
            context.setFillColor(cg(style.overlapFill))
            polygon(overlap, viewport, context)
            context.fillPath()
            label(format.size(Size(width: overlap.width, height: overlap.height)), at: viewport.toView(overlap.center), style, context)
        }
        if let outline = measurements.outline {
            context.setStrokeColor(cg(style.outline))
            polygon(outline, viewport, context)
            context.strokePath()
            let corner = viewport.toView(Point(x: outline.minX, y: outline.minY))
            label(format.size(Size(width: outline.width, height: outline.height)), at: Point(x: corner.x, y: corner.y - style.fontSize), style, context)
        }
        context.setStrokeColor(cg(style.measure))
        for line in measurements.lines {
            let start = viewport.toView(line.start)
            let end = viewport.toView(line.end)
            context.move(to: CGPoint(x: start.x, y: start.y))
            context.addLine(to: CGPoint(x: end.x, y: end.y))
            // End ticks across the line.
            let length = max(hypot(end.x - start.x, end.y - start.y), .ulpOfOne)
            let normal = Point(x: -(end.y - start.y) / length * style.tick, y: (end.x - start.x) / length * style.tick)
            for tip in [start, end] {
                context.move(to: CGPoint(x: tip.x - normal.x, y: tip.y - normal.y))
                context.addLine(to: CGPoint(x: tip.x + normal.x, y: tip.y + normal.y))
            }
            context.strokePath()
            label(format.string(line.distance), at: viewport.toView(line.middle), style, context)
        }
        if let point = measurements.point {
            let view = viewport.toView(point)
            context.setFillColor(cg(style.measure))
            context.fillEllipse(in: CGRect(x: view.x - 2.5, y: view.y - 2.5, width: 5, height: 5))
            label(format.coordinates(point, origin: measurements.origin), at: Point(x: view.x + 6, y: view.y + 6), style, context)
        }
    }

    /// The rectangle's corners through the viewport (a rotated canvas turns it).
    static func polygon(_ rect: Rect, _ viewport: Viewport, _ context: CGContext) {
        let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
                       Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)].map(viewport.toView)
        context.addLines(between: corners.map { CGPoint(x: $0.x, y: $0.y) })
        context.closePath()
    }

    /// A label centred on `center`: a filled capsule and the text, drawn upright in the y-down
    /// context.
    static func label(_ text: String, at center: Point, _ style: Style, _ context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, style.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(style.labelText),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let box = CGRect(x: center.x - width / 2 - 3, y: center.y - (ascent + descent) / 2 - 2, width: width + 6, height: ascent + descent + 4)
        context.setFillColor(cg(style.labelBackground))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: box.minX + 3, y: box.maxY - 2 - descent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func cg(_ color: Color) -> CGColor {
        CGColor(srgbRed: color.components.x, green: color.components.y, blue: color.components.z, alpha: color.alpha)
    }
}

/// The overlay's layer: set `viewport` and `format`, feed it `show(_:)` on every pointer move
/// (it redraws only when what it shows changed), `frozen` while kbd:[Shift] is down, `clear()`
/// when the pointer leaves.  Its geometry is flipped so it draws in view coordinates.
public final class InspectOverlayLayer: CALayer, @unchecked Sendable {
    /// How the canvas is seen; nil draws nothing.
    public var viewport: Viewport? {
        didSet { if viewport != oldValue { setNeedsDisplay() } }
    }
    public var format = InspectFormat() {
        didSet { if format != oldValue { setNeedsDisplay() } }
    }
    public var overlayStyle = InspectOverlayRenderer.Style.standard
    /// What is shown, and whether it is frozen.
    public private(set) var state = InspectOverlayState()

    override public init() {
        super.init()
        isGeometryFlipped = true
        needsDisplayOnBoundsChange = true
    }

    override public init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? InspectOverlayLayer {
            viewport = other.viewport
            format = other.format
            overlayStyle = other.overlayStyle
            state = other.state
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `measurements` (unless frozen); returns whether the layer will redraw.
    @discardableResult
    public func show(_ measurements: InspectMeasurements) -> Bool {
        guard state.update(measurements) else { return false }
        setNeedsDisplay()
        return true
    }

    /// kbd:[Shift]: keeps what is shown while the pointer moves.
    public var frozen: Bool {
        get { state.frozen }
        set { state.frozen = newValue }
    }

    /// The pointer left the canvas.
    public func clear() {
        state.clear()
        setNeedsDisplay()
    }

    override public func draw(in context: CGContext) {
        guard let viewport, !state.shown.isEmpty else { return }
        InspectOverlayRenderer.draw(state.shown, format: format, viewport: viewport, in: context, style: overlayStyle)
    }
}
