// FreeHand appearance to imported paint (import-formats.adoc, "FreeHand"; IO-041).  A FreeHand
// object names a style record; the style reaches its fill and stroke through property lists
// (FreeHand 8 and earlier: `PropLst`, keyed by the "fill" and "stroke" names) or graphic styles
// (FreeHand 9 and later: an attribute list of attribute holders, each holder's value inherited
// from its parent), and filter holders add transparency and live effects.  The walk is
// libfreehand's (FHCollector::_appendFillProperties and _appendStrokeProperties); the values it
// finds become live WireTuner fills and strokes wherever one exists.

import Foundation
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle

/// What a style record resolves to.
struct FreeHandStyle: Hashable, Sendable {
    /// The fill record (basic, linear, radial, lens, tile, pattern or custom).
    var fill: Int?
    /// The stroke record (basic, pattern or custom line).
    var stroke: Int?
    /// The product of the style's opacity filters.
    var opacity: Double = 1
    var shadow = false
    var glow = false
}

extension FreeHandConverter {
    // MARK: Styles

    /// Style `id` resolved: parents first, then the record's own settings over them.
    func style(_ id: Int) -> FreeHandStyle {
        var style = FreeHandStyle()
        var visited: Set<Int> = []
        resolve(id, into: &style, visited: &visited)
        return style
    }

    private func resolve(_ id: Int, into style: inout FreeHandStyle, visited: inout Set<Int>) {
        guard id != 0, visited.insert(id).inserted, visited.count < FreeHandConverter.maximumDepth else { return }
        if let list = records.propertyLists[id] {
            resolve(list.parent, into: &style, visited: &visited)
            if let fill = list.elements[String(records.fillName)], records.fillName != 0, isFill(fill) { style.fill = fill }
            if let stroke = list.elements[String(records.strokeName)], records.strokeName != 0, isStroke(stroke) { style.stroke = stroke }
            return
        }
        guard let graphic = records.graphicStyles[id] else { return }
        resolve(graphic.parent, into: &style, visited: &visited)
        for element in records.lists[graphic.attr]?.elements ?? [] {
            if let holder = records.filterAttributeHolders[element] {
                resolve(holder.style, into: &style, visited: &visited)
                applyFilter(holder.filter, to: &style, visited: &visited)
                continue
            }
            let value = attributeValue(element, visited: visited)
            if isFill(value) { style.fill = value }
            if isStroke(value) { style.stroke = value }
        }
    }

    /// An attribute holder's value: its own, else its parent's.
    private func attributeValue(_ id: Int, visited: Set<Int>) -> Int {
        var visited = visited
        var current = id
        while current != 0, visited.insert(current).inserted, let holder = records.attributeHolders[current] {
            if holder.attr != 0 { return holder.attr }
            current = holder.parent
        }
        return 0
    }

    /// Filter `id` (or each filter of list `id`): opacity multiplies, shadows and glows are noted.
    private func applyFilter(_ id: Int, to style: inout FreeHandStyle, visited: inout Set<Int>) {
        guard id != 0, visited.insert(id).inserted else { return }
        if let opacity = records.opacityFilters[id] { style.opacity *= min(max(opacity, 0), 1) }
        if records.shadowFilters[id] != nil { style.shadow = true }
        if records.glowFilters[id] != nil { style.glow = true }
        for element in records.lists[id]?.elements ?? [] {
            applyFilter(element, to: &style, visited: &visited)
        }
    }

    func isFill(_ id: Int) -> Bool {
        records.basicFills[id] != nil || records.linearFills[id] != nil || records.radialFills[id] != nil || records.lensFills[id] != nil
            || records.tileFills[id] != nil || records.patternFills[id] != nil || records.customProcs[id] != nil
    }

    func isStroke(_ id: Int) -> Bool {
        records.basicLines[id] != nil || records.patternLines[id] != nil
    }

    mutating func noteEffects(_ style: FreeHandStyle) {
        if style.shadow { notes.shadows += 1 }
        if style.glow { notes.glows += 1 }
    }

    // MARK: Colours

    /// Colour record `id`: its colour, the name it is listed under and whether it is a spot ink.
    func color(_ id: Int) -> (color: Color, name: String?, spot: Bool)? {
        let preview = records.rgbColors[id].flatMap { rgb -> Color? in
            guard rgb.count == 3 else { return nil }
            return Color(red: Double(rgb[0]) / 65535, green: Double(rgb[1]) / 65535, blue: Double(rgb[2]) / 65535)
        }
        if let record = records.colorRecords[id] {
            let name = records.strings[record.name].flatMap { $0.isEmpty ? nil : $0 }
            var value = preview
            var spot = false
            switch record.kind {
            case 1, 2:
                // Color6 and SpotColor6: the colour model's first word (1 RGB, 2 CMYK), the
                // components as 16.16 fixed point at the end of the record.
                value = FreeHandConverter.components(record.raw.data) ?? preview
                spot = record.kind == 2 && name.map(FreeHandConverter.isSpotLibraryName) == true
            case 4:
                if let cmyk = record.cmyk, cmyk.count == 4 {
                    value = Color(cyan: Double(cmyk[0]) / 65535, magenta: Double(cmyk[1]) / 65535, yellow: Double(cmyk[2]) / 65535, black: Double(cmyk[3]) / 65535)
                }
            case 5:
                spot = true
            default:
                break
            }
            if let value { return (value, name, spot) }
        }
        if let tint = records.tints[id], let base = color(tint.base) {
            return (FreeHandConverter.tinted(base.color, Double(tint.tint) / 65535), nil, false)
        }
        return preview.map { ($0, nil, false) }
    }

    /// Color6 and SpotColor6 components: RGB or CMYK by the model word, nil for another model.
    static func components(_ raw: Data) -> Color? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 2 else { return nil }
        let model = Int(bytes[0]) << 8 | Int(bytes[1])
        let count = model == 1 ? 3 : model == 2 ? 4 : 0
        guard count > 0, bytes.count >= 2 + count * 4 else { return nil }
        let values = (0..<count).map { index -> Double in
            let offset = bytes.count - (count - index) * 4
            let fixed = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            return min(max(Double(fixed) / 65536, 0), 1)
        }
        // 0xffff is FreeHand's full strength.
        func unit(_ value: Double) -> Double { value >= 65535.0 / 65536 ? 1 : value }
        if count == 3 { return Color(red: unit(values[0]), green: unit(values[1]), blue: unit(values[2])) }
        return Color(cyan: unit(values[0]), magenta: unit(values[1]), yellow: unit(values[2]), black: unit(values[3]))
    }

    /// `color` at `strength` (0...1) over paper.
    static func tinted(_ color: Color, _ strength: Double) -> Color {
        let t = min(max(strength, 0), 1)
        var result = color
        if color.space == .cmyk {
            result.components = color.components * t
        } else {
            result.components = SIMD4(color.components.x * t + (1 - t), color.components.y * t + (1 - t), color.components.z * t + (1 - t), 0)
        }
        return result
    }

    /// Whether a colour's name comes from a spot ink library.  FreeHand 9 and later keep a
    /// named colour's spot or process choice in bytes libfreehand does not decode, so the name
    /// decides (D-083).
    static func isSpotLibraryName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["PANTONE", "TOYO", "DIC ", "HKS", "ANPA"].contains { upper.hasPrefix($0) }
    }

    /// The paint of colour `id`: a named colour as a swatch, else the colour itself.
    func colorPaint(_ id: Int) -> ImportedPaint? {
        guard let (color, name, spot) = self.color(id) else { return nil }
        if let name { return .swatch(ImportedSwatch(name: name, color: color, spot: spot)) }
        return .solid(color)
    }

    // MARK: Fills

    /// Fill record `id` for a path whose geometry spans `bounds` (scene space); `transform` maps
    /// FreeHand space to scene space at the path.
    mutating func paint(fill id: Int, bounds: Rect, transform: AffineTransform) -> ImportedPaint {
        if let fill = records.basicFills[id] {
            return colorPaint(fill) ?? .solid(.black)
        }
        if let linear = records.linearFills[id] {
            return .gradient(linearGradient(linear, bounds: bounds, transform: transform))
        }
        if let radial = records.radialFills[id] {
            return .gradient(radialGradient(radial, bounds: bounds))
        }
        if let lens = records.lensFills[id] {
            return .lens(self.lens(lens))
        }
        if let tile = records.tileFills[id] {
            return self.tile(tile)
        }
        if let pattern = records.patternFills[id] {
            let color = self.color(pattern.color)?.color ?? .black
            return .pattern(PatternPaint(bitmap: PatternBitmap(rows: [UInt8](pattern.pattern.data)), color: color))
        }
        if let custom = records.customProcs[id] {
            notes.customFills += 1
            return custom.ids.first.flatMap(colorPaint) ?? .solid(.black)
        }
        return .none
    }

    /// Stops of a two-colour fill or its multi-colour list, the first colour at offset 0 (at 1
    /// when `reversed`).
    func stops(color1: Int, color2: Int, list: Int, reversed: Bool = false) -> [Gradient.Stop] {
        func offset(_ value: Double) -> Double { reversed ? 1 - value : value }
        let listed = (records.multiColorLists[list] ?? []).compactMap { stop -> Gradient.Stop? in
            guard stop.count == 2, let color = self.color(Int(stop[0]))?.color else { return nil }
            return Gradient.Stop(offset: offset(min(max(stop[1], 0), 1)), color: color)
        }
        if listed.count >= 2 { return listed }
        return [Gradient.Stop(offset: offset(0), color: color(color1)?.color ?? .white), Gradient.Stop(offset: offset(1), color: color(color2)?.color ?? .black)]
    }

    /// A graduated fill: the ramp runs across the path's bounds from the first colour in the
    /// direction (cos a, −sin a) of FreeHand's y-up space -- libfreehand's reading (its ODF angle
    /// is 90° − a), so 90° runs from the top down.
    func linearGradient(_ fill: FreeHandRecords.LinearFill, bounds: Rect, transform: AffineTransform) -> Gradient {
        let radians = fill.angle * .pi / 180
        var direction = transform.apply(Vector(dx: cos(radians), dy: -sin(radians)))
        let length = direction.length
        direction = length > 0 ? Vector(dx: direction.dx / length, dy: direction.dy / length) : Vector(dx: 1, dy: 0)
        let half = (abs(direction.dx) * bounds.width + abs(direction.dy) * bounds.height) / 2
        let center = bounds.center
        let axis = Gradient.Axis(start: Point(x: center.x - direction.dx * half, y: center.y - direction.dy * half),
                                 end: Point(x: center.x + direction.dx * half, y: center.y + direction.dy * half))
        return Gradient(kind: .linear, axis: axis, stops: stops(color1: fill.color1, color2: fill.color2, list: fill.multiColorList))
    }

    /// A radial fill: centred at FreeHand's fractions of the bounds (y measured up), reaching
    /// the farthest corner; the first colour is outside, as libfreehand reads it (its ODF start
    /// colour).
    func radialGradient(_ fill: FreeHandRecords.RadialFill, bounds: Rect) -> Gradient {
        let center = Point(x: bounds.minX + fill.cx * bounds.width, y: bounds.maxY - fill.cy * bounds.height)
        let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.minX, y: bounds.maxY), Point(x: bounds.maxX, y: bounds.maxY)]
        let radius = corners.map { ($0 - center).length }.max()!
        let axis = Gradient.Axis(start: center, end: Point(x: center.x + max(radius, 0.001), y: center.y))
        return Gradient(kind: .radial, axis: axis, stops: stops(color1: fill.color1, color2: fill.color2, list: fill.multiColorList, reversed: true))
    }

    func lens(_ fill: FreeHandRecords.LensFill) -> LensFill {
        let color = self.color(fill.color)?.color ?? .black
        let amount = min(max(fill.value, 0), 100)
        switch fill.mode {
        case 1: return LensFill(type: .magnify, color: color, magnification: min(max(fill.value, 1), 20))
        case 2: return LensFill(type: .lighten, color: color, amount: amount)
        case 3: return LensFill(type: .darken, color: color, amount: amount)
        case 4: return LensFill(type: .invert, color: color)
        case 5: return LensFill(type: .monochrome, color: color)
        default: return LensFill(type: .transparency, color: color, amount: amount)
        }
    }

    /// Tile space: FreeHand's inches to points, y down, the same origin.
    static let tileSpace = AffineTransform(a: 72, b: 0, c: 0, d: -72, tx: 0, ty: 0)

    /// A tiled fill: the tile's artwork in tile space (the tile's own transform applied),
    /// FreeHand's scale fractions as percentages, its offset in points, its angle with y down.
    mutating func tile(_ fill: FreeHandRecords.TileFill) -> ImportedPaint {
        let nodes = node(fill.group, freeHandTransform(fill.xform).concatenating(FreeHandConverter.tileSpace))
        guard !nodes.isEmpty else { return .none }
        func percent(_ value: Double) -> Double { value.isFinite && value > 0 ? value * 100 : 100 }
        return .tiled(ImportedTile(nodes: nodes, angle: -fill.angle, scaleX: percent(fill.scaleX), scaleY: percent(fill.scaleY),
                                   offset: Point(x: fill.offsetX * 72, y: -fill.offsetY * 72)))
    }

    // MARK: Strokes

    /// Stroke record `id` at the path; `transform` scales its width and dash.
    mutating func stroke(_ id: Int, transform: AffineTransform) -> ImportedStroke? {
        let scale = FreeHandConverter.scale(of: transform)
        if let line = records.basicLines[id] {
            let paint = colorPaint(line.color) ?? .solid(.black)
            let dash = (records.linePatterns[line.pattern] ?? []).filter { $0.isFinite && $0 >= 0 }
            // Line patterns are in points; the scene's points are FreeHand's inches times 72.
            let dashes = dash.count >= 2 && dash.contains { $0 > 0 } ? dash.map { $0 * scale / 72 } : []
            let miter = line.miter * 72
            let style = StrokeStyle(width: max(line.width * scale, 0), miterLimit: miter.isFinite && miter >= 1 ? miter : 4, dash: dashes)
            return ImportedStroke(paint: paint, style: style, startArrowhead: arrowhead(line.startArrow), endArrowhead: arrowhead(line.endArrow))
        }
        if let line = records.patternLines[id] {
            notes.patternStrokes += 1
            return ImportedStroke(paint: colorPaint(line.color) ?? .solid(.black), style: StrokeStyle(width: max(line.width * scale, 0)))
        }
        return nil
    }

    /// Arrowhead `id`: FreeHand's outline in stroke widths, pointing along +x from the end.
    func arrowhead(_ id: Int) -> ImportedArrowhead? {
        guard let path = records.arrowPaths[id] else { return nil }
        // libfreehand keeps the outline's raw units (stroke widths) as its "inches"; y up.
        let contours = FreeHandConverter.contours(path, AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
        return contours.isEmpty ? nil : ImportedArrowhead(contours: contours, filled: true, name: "FreeHand \(id)")
    }
}
