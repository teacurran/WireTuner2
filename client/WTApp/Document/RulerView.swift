import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The ticks of a ruler (rulers.adoc, "Client"; DOC-014): tick spacing from the unit's natural
/// subdivisions (points 1/6/12/72, picas 1/6/12, inches in halves down to sixteenths and finer,
/// millimetres 1/5/10, pixels 1/10/100, decimals for the rest) so labelled ticks are at least 40
/// view points apart and their labels never overlap.
struct RulerScale: Equatable {
    struct Tick: Equatable {
        /// View points along the ruler.
        var position: Double
        /// 0 labelled, 1 half-way, 2 minor.
        var level: Int
        var label: String?
    }

    /// The smallest spacing between labelled ticks, view points.
    static let minimumLabelSpacing = 40.0
    /// The smallest spacing between minor ticks.
    static let minimumTickSpacing = 5.0
    /// What one character of a label takes, view points (9 pt monospaced digits).
    static let characterWidth = 5.6

    /// Units between labelled ticks.
    var step: Double
    /// Minor ticks per labelled step (1: none).
    var divisions: Int

    /// The label steps a unit offers, in that unit, smallest first.
    static func candidates(for unit: LengthUnit) -> [Double] {
        let decimals = (-4...6).flatMap { exponent in [1.0, 2, 5].map { $0 * pow(10, Double(exponent)) } }
        switch unit {
        case .points: return [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 6, 12, 36, 72, 144, 360, 720, 1440, 3600, 7200, 14400, 36000]
        case .picas: return [1.0 / 1200, 1.0 / 600, 1.0 / 240, 1.0 / 120, 1.0 / 60, 1.0 / 24, 1.0 / 12, 0.5, 1, 6, 12, 60, 120, 600, 1200, 6000]
        case .inches: return (-8...12).map { pow(2, Double($0)) }
        case .pixels: return [0.01, 0.1, 1, 10, 100, 1000, 10000, 100_000]
        default: return decimals
        }
    }

    /// How a labelled step is subdivided, most divisions first.
    static func divisions(for unit: LengthUnit) -> [Int] {
        switch unit {
        case .points, .picas: [12, 6, 2]
        case .inches: [8, 4, 2]
        default: [10, 5, 2]
        }
    }

    /// The scale for `unit` at `viewPointsPerUnit`: the smallest candidate step whose labels (the
    /// widest `labelLength(step)` characters long) fit between its labelled ticks.
    static func choose(unit: LengthUnit, viewPointsPerUnit: Double, labelLength: (Double) -> Int) -> RulerScale? {
        guard viewPointsPerUnit.isFinite, viewPointsPerUnit > 0 else { return nil }
        for step in candidates(for: unit) {
            let spacing = step * viewPointsPerUnit
            let needed = max(minimumLabelSpacing, Double(labelLength(step)) * characterWidth + 6)
            guard spacing >= needed else { continue }
            let divisions = divisions(for: unit).first { spacing / Double($0) >= minimumTickSpacing } ?? 1
            return RulerScale(step: step, divisions: divisions)
        }
        return nil
    }

    /// The ticks between view positions `from` and `to` of a ruler where view position `v` reads
    /// `value(v) = offset + slope · v` units; `label` names a value.
    func ticks(from: Double, to: Double, offset: Double, slope: Double, label: (Double) -> String) -> [Tick] {
        guard slope != 0, slope.isFinite, offset.isFinite else { return [] }
        let values = [offset + slope * from, offset + slope * to]
        let minor = step / Double(divisions)
        let first = (values.min()! / minor).rounded(.down)
        let last = (values.max()! / minor).rounded(.up)
        guard last - first < 10_000 else { return [] }
        // Counted in integers: past 2^53 `index += 1` on a Double is a no-op, and a `while index
        // <= last` loop would append the same tick forever.
        var ticks: [Tick] = []
        for offsetIndex in 0...Int(last - first) {
            let index = first + Double(offsetIndex)
            let value = index * minor
            let position = (value - offset) / slope
            let within = Int(index.truncatingRemainder(dividingBy: Double(divisions)) + Double(divisions)) % divisions
            let level = within == 0 ? 0 : (divisions % 2 == 0 && within == divisions / 2 ? 1 : 2)
            if position >= from - 0.5, position <= to + 0.5 {
                ticks.append(Tick(position: position, level: level, label: level == 0 ? label(value) : nil))
            }
        }
        return ticks
    }
}

/// How a ruler reads the view: which pasteboard axis it measures (the one nearest its edge, so a
/// rotated canvas turns the rulers with the pages), in which unit, from which zero point.
struct RulerMapping: Equatable {
    enum Edge {
        case horizontal, vertical
    }

    var edge: Edge
    /// The value in units at view position 0 and per view point.
    var offset: Double
    var slope: Double
    var unit: LengthUnit

    /// The mapping of the ruler along `edge` of a canvas `viewport`, counting from `zero`
    /// (pasteboard) in `units`: x grows to the right, y grows upward (rulers.adoc, "The zero
    /// point").
    init(edge: Edge, viewport: Viewport, zero: Point, units: Units) {
        self.edge = edge
        unit = units.documentUnit
        let perUnit = units.pointsPerUnit(units.documentUnit)
        let across = edge == .horizontal ? viewport.size.height / 2 : viewport.size.width / 2
        func point(_ v: Double) -> Point {
            viewport.toPasteboard(edge == .horizontal ? Point(x: v, y: across) : Point(x: across, y: v))
        }
        let origin = point(0), next = point(1)
        let direction = Vector(dx: next.x - origin.x, dy: next.y - origin.y)
        let measuresX = edge == .horizontal ? abs(direction.dx) >= abs(direction.dy) : abs(direction.dx) > abs(direction.dy)
        if measuresX {
            offset = (origin.x - zero.x) / perUnit
            slope = direction.dx / perUnit
        } else {
            offset = (zero.y - origin.y) / perUnit
            slope = -direction.dy / perUnit
        }
    }

    /// The value at view position `v`, in units.
    func value(at v: Double) -> Double { offset + slope * v }

    /// The view position of `value`.
    func position(of value: Double) -> Double { (value - offset) / slope }
}

/// One ruler along the top or left edge of the canvas (rulers.adoc; DOC-014): ticks and labels in
/// the document's unit from the active page's zero point, a line tracking the pointer and the
/// edges of a selection being dragged.  Dragging out of it adds a guide (grid-guides.adoc,
/// "Adding guides by dragging"): the host turns the drag into a `GuideDrag`.
@MainActor
final class RulerStripView: NSView {
    enum Orientation: String {
        case horizontal, vertical
    }

    /// A drag out of the ruler, in window coordinates.
    enum DragPhase {
        case began, moved, ended
    }

    let orientation: Orientation
    /// Set by the host on every viewport change.
    var viewport: Viewport? {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }
    /// The document's units and the zero point (pasteboard) the ruler counts from.
    var frameOfReference: (units: Units, zero: Point) = (Units(), .zero) {
        didSet { needsDisplay = true }
    }
    /// The pointer over the canvas (pasteboard), tracked by a line; nil off the canvas.
    var pointer: Point? {
        didSet { if pointer != oldValue { needsDisplay = true } }
    }
    /// The bounds of a selection being dragged (pasteboard): lines track its edges.
    var trackedBounds: Rect? {
        didSet { if trackedBounds != oldValue { needsDisplay = true } }
    }
    /// A drag out of the ruler (a new guide).
    var onDrag: (@MainActor (DragPhase, NSPoint, KeyModifiers) -> Void)?

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.ruler)
        setAccessibilityIdentifier("ruler.\(orientation.rawValue)")
        setAccessibilityLabel(orientation == .horizontal ? "Horizontal ruler" : "Vertical ruler")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerStripView is built in code")
    }

    override var isFlipped: Bool { true }

    /// The mapping for the current viewport; nil before the first one.
    var mapping: RulerMapping? {
        viewport.map { RulerMapping(edge: orientation == .horizontal ? .horizontal : .vertical, viewport: $0, zero: frameOfReference.zero,
                                    units: frameOfReference.units) }
    }

    /// The ticks the ruler draws over its length.
    var ticks: [RulerScale.Tick] {
        guard let mapping, let scale = scale(for: mapping) else { return [] }
        let length = Double(orientation == .horizontal ? bounds.width : bounds.height)
        return scale.ticks(from: 0, to: length, offset: mapping.offset, slope: mapping.slope, label: label)
    }

    func scale(for mapping: RulerMapping) -> RulerScale? {
        let length = Double(orientation == .horizontal ? bounds.width : bounds.height)
        let extremes = [mapping.value(at: 0), mapping.value(at: length)]
        return RulerScale.choose(unit: mapping.unit, viewPointsPerUnit: 1 / abs(mapping.slope)) { step in
            extremes.map { self.label(($0 / step).rounded() * step).count }.max() ?? 1
        }
    }

    /// A labelled value (units) as shown: the document's unit formatting, without the suffix.
    func label(_ value: Double) -> String {
        let units = frameOfReference.units
        return units.format(value * units.pointsPerUnit(units.documentUnit))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let thickness = Double(orientation == .horizontal ? bounds.height : bounds.width)
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        for tick in ticks {
            let length = tick.level == 0 ? thickness : tick.level == 1 ? thickness * 0.5 : thickness * 0.3
            line(at: tick.position, length: length, in: ctx)
            if let label = tick.label { draw(label, at: tick.position, attributes: attributes, in: ctx) }
        }
        ctx.strokePath()
        guard let viewport else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for position in trackedPositions(viewport: viewport) { line(at: position, length: thickness, in: ctx) }
        ctx.strokePath()
    }

    /// Where the pointer and the dragged selection's edges cross the ruler, view points.
    func trackedPositions(viewport: Viewport) -> [Double] {
        var points = pointer.map { [$0] } ?? []
        if let bounds = trackedBounds { points += [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY)] }
        return points.map { orientation == .horizontal ? viewport.toView($0).x : viewport.toView($0).y }
    }

    private func line(at position: Double, length: Double, in ctx: CGContext) {
        let thickness = Double(orientation == .horizontal ? bounds.height : bounds.width)
        if orientation == .horizontal {
            ctx.move(to: CGPoint(x: position + 0.5, y: thickness))
            ctx.addLine(to: CGPoint(x: position + 0.5, y: thickness - length))
        } else {
            ctx.move(to: CGPoint(x: thickness, y: position + 0.5))
            ctx.addLine(to: CGPoint(x: thickness - length, y: position + 0.5))
        }
    }

    private func draw(_ label: String, at position: Double, attributes: [NSAttributedString.Key: Any], in ctx: CGContext) {
        let text = label as NSString
        if orientation == .horizontal {
            text.draw(at: NSPoint(x: position + 2, y: 0), withAttributes: attributes)
        } else {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: position - 2)
            ctx.rotate(by: -.pi / 2)
            text.draw(at: NSPoint(x: 0, y: 0), withAttributes: attributes)
            ctx.restoreGState()
        }
    }

    // MARK: Dragging out a guide

    override func mouseDown(with event: NSEvent) {
        onDrag?(.began, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(.moved, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        onDrag?(.ended, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }
}

/// The zero-point marker where the rulers meet (rulers.adoc, "The zero point"): dragging it onto
/// the pasteboard moves the active page's zero point (one change on release, "Move zero point");
/// a double-click resets it.
@MainActor
final class RulerCornerView: NSView {
    /// A drag of the marker, in window coordinates.
    var onDrag: (@MainActor (RulerStripView.DragPhase, NSPoint, KeyModifiers) -> Void)?
    /// A double-click: the active page's zero point goes back to its bottom-left corner.
    var onReset: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("ruler.corner")
        setAccessibilityLabel("Zero point")
        toolTip = "Drag to move the zero point; double-click to reset it"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerCornerView is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: bounds.midX, y: 3))
        ctx.addLine(to: CGPoint(x: bounds.midX, y: bounds.height - 3))
        ctx.move(to: CGPoint(x: 3, y: bounds.midY))
        ctx.addLine(to: CGPoint(x: bounds.width - 3, y: bounds.midY))
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onReset?()
            return
        }
        onDrag?(.began, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(.moved, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        onDrag?(.ended, event.locationInWindow, KeyEquivalentResolver.modifiers(event.modifierFlags))
    }
}

/// Where the zero point lands (rulers.adoc, "The zero point"): with kbd:[Shift] on the active
/// page's nearest corner or its centre; otherwise the snapped pointer.
enum ZeroPointDrop {
    /// The active page's corners and centre.
    static func targets(on page: Page) -> [Point] {
        let rect = page.rect
        return [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.minX, y: rect.maxY),
                Point(x: rect.maxX, y: rect.maxY), rect.center]
    }

    /// The pasteboard point `point` lands on for `page`.
    static func point(_ point: Point, on page: Page, shift: Bool) -> Point {
        guard shift else { return point }
        return targets(on: page).min { $0.distance(to: point) < $1.distance(to: point) } ?? point
    }

    /// The command writing the zero point of `page` at `point` (relative to the page's top-left).
    static func command(_ point: Point, on page: Page) -> SetRulerOrigin {
        SetRulerOrigin(page.id, to: Point(x: point.x - page.origin.x, y: point.y - page.origin.y))
    }
}
