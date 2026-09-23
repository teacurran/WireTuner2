// DXF import (import-formats.adoc, "AutoCAD DXF" and "Client"; IMG-013): the two-dimensional
// entities of an ASCII or binary DXF as paths and text, block references expanded in place, one
// group per layer.  Drawing space is y-up in drawing units; every entity is built in its own
// space and mapped through one transform -- the drawing's units to points with y flipped, any
// block insertion, and the object coordinate system's mirror for entities extruded along −Z --
// so arcs and curves stay exact Béziers.  The scene's natural size is the drawing's extents,
// with their top-left corner at the origin.

import CoreText
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

public struct DXFImporter: Importer {
    public init() {}

    public var formats: [ImportFormat] { [.dxf] }

    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema { DXFImportOptions.schema }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let scene = try convert(data, name: name, options: DXFImportOptions())
        return ImportDescriptor(format: .dxf, naturalSize: scene.bounds)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        try context.checkSize(data.count, name: name)
        return try convert(data, name: name, options: DXFImportOptions(options))
    }

    /// `data` converted with typed options.
    public func convert(_ data: Data, name: String, options: DXFImportOptions) throws -> ImportedScene {
        guard let drawing = DXFImportDrawing(data) else {
            throw ImportError.unreadable(name: name, reason: "it is not a DXF file or it is cut short.")
        }
        return try DXFImportConverter(drawing: drawing, options: options, name: name).scene()
    }
}

/// Converts one parsed drawing.
final class DXFImportConverter {
    let drawing: DXFImportDrawing
    let options: DXFImportOptions
    let name: String
    let layers: [String: DXFImportLayer]
    /// Points per drawing unit.
    let unit: Double
    private(set) var notes: [String] = []
    private var skipped: [String] = []
    private var layerOrder: [String] = []
    private var layerNodes: [String: [ImportedNode]] = [:]

    /// Where an entity is drawn: its space's transform to the page and the values a block
    /// reference passes to its contents.
    struct Context {
        var transform: AffineTransform
        /// The layer entities on layer "0" take (the inserting entity's), nil at top level.
        var layer: String?
        var byBlockColor: Color = .black
        var byBlockLineweight = -3
        var blocks: [String] = []
    }

    init(drawing: DXFImportDrawing, options: DXFImportOptions, name: String) {
        self.drawing = drawing
        self.options = options
        self.name = name
        layers = Dictionary(drawing.layers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let code = drawing.header["$INSUNITS"]?.first { $0.code == 70 }?.int ?? 0
        unit = DXFImportConverter.pointsPerUnit(code) ?? options.units.points
        if code != 0 && DXFImportConverter.pointsPerUnit(code) == nil {
            notes.append("“\(name)” uses drawing units WireTuner does not know ($INSUNITS \(code)); they were read as \(options.units.rawValue).")
        }
    }

    /// Points per unit of a `$INSUNITS` code; nil for unitless and unknown codes.
    static func pointsPerUnit(_ code: Int) -> Double? {
        let inch = 72.0
        let millimeter = inch / 25.4
        switch code {
        case 1: return inch
        case 2: return inch * 12
        case 3: return inch * 63_360
        case 4: return millimeter
        case 5: return millimeter * 10
        case 6: return millimeter * 1_000
        case 7: return millimeter * 1_000_000
        case 8: return inch * 1e-6
        case 9: return inch * 1e-3
        case 10: return inch * 36
        case 11: return millimeter * 1e-7
        case 12: return millimeter * 1e-6
        case 13: return millimeter * 1e-3
        case 14: return millimeter * 100
        case 15: return millimeter * 10_000
        case 16: return millimeter * 100_000
        case 21: return inch * 12 * 1_200 / 1_199.997_6
        default: return nil
        }
    }

    // MARK: Scene

    func scene() throws -> ImportedScene {
        let root = Context(transform: AffineTransform(a: unit, b: 0, c: 0, d: -unit, tx: 0, ty: 0))
        var hiddenLayers = Set<String>()
        for entity in drawing.entities {
            let layer = entity.layer
            if layers[layer]?.hidden == true {
                hiddenLayers.insert(layer)
                continue
            }
            let nodes = convert(entity, root)
            guard !nodes.isEmpty else { continue }
            if layerNodes[layer] == nil {
                layerOrder.append(layer)
            }
            layerNodes[layer, default: []] += nodes
        }
        if !hiddenLayers.isEmpty {
            notes.append("Layers that are off or frozen were left out: \(hiddenLayers.sorted().joined(separator: ", ")).")
        }
        if !skipped.isEmpty {
            notes.append("Entities without a two-dimensional appearance were left out: \(skipped.joined(separator: ", ")).")
        }
        var seen = Set<String>()
        let tableOrder = drawing.layers.map(\.name).filter { seen.insert($0).inserted }
        let ordered = tableOrder.filter { layerNodes[$0] != nil } + layerOrder.filter { !tableOrder.contains($0) }
        let rects = ordered.flatMap { layerNodes[$0]!.flatMap { DXFImportConverter.bounds(of: $0, .identity) } }
        guard let first = rects.first else {
            throw ImportError.empty(name: name)
        }
        let extents = rects.reduce(first) { $0.union($1) }
        let shift = AffineTransform.translation(x: -extents.minX, y: -extents.minY)
        let groups = ordered.map { ImportedNode.group(ImportedGroup(children: layerNodes[$0]!, transform: shift, name: $0, role: .layer)) }
        return ImportedScene(kind: .vector, name: name, bounds: Rect(x: 0, y: 0, width: extents.width, height: extents.height), nodes: groups, notes: notes)
    }

    /// A node's bounds in its parent's space, as the boxes of its parts: exact for paths, the
    /// run boxes for text.
    static func bounds(of node: ImportedNode, _ parent: AffineTransform) -> [Rect] {
        switch node {
        case .group(let group):
            let total = group.transform.concatenating(parent)
            return group.children.flatMap { bounds(of: $0, total) }
        case .path(let path):
            let total = path.transform.concatenating(parent)
            return path.contours.map { $0.applying(total) }.flatMap { contour -> [Rect] in
                var current = contour.start
                var result = [Rect(current, current)]
                for segment in contour.segments {
                    switch segment {
                    case .line(let end):
                        result.append(Rect(current, end))
                    case .cubic(let c1, let c2, let end):
                        result.append(CubicBezier(current, c1, c2, end).bounds)
                    }
                    current = segment.end
                }
                return result
            }
        case .text(let text):
            let total = text.transform.concatenating(parent)
            return text.runs.map { run in
                let width = DXFImportConverter.width(of: run.text, size: run.fontSize)
                let corners = [Point(x: run.origin.x, y: run.origin.y - run.fontSize * 0.75), Point(x: run.origin.x + width, y: run.origin.y + run.fontSize * 0.25)]
                return Rect(boundingPoints: corners.map(total.apply))
            }
        case .image, .placed:
            return []
        }
    }

    // MARK: Attributes

    /// The layer an entity's BYLAYER values come from.
    func effectiveLayer(_ entity: DXFImportEntity, _ context: Context) -> String {
        entity.layer == "0" ? context.layer ?? "0" : entity.layer
    }

    func layerColor(_ name: String) -> Color {
        guard let layer = layers[name] else {
            return .black
        }
        return layer.trueColor.map(DXFImportColors.color(rgb:)) ?? DXFImportColors.color(index: layer.colorIndex)
    }

    /// The entity's colour: true colour, index, BYBLOCK (0) or BYLAYER (256, the default).
    func color(_ entity: DXFImportEntity, _ context: Context) -> Color {
        if entity.has(420) {
            return DXFImportColors.color(rgb: entity.int(420))
        }
        switch entity.int(62, 256) {
        case 0: return context.byBlockColor
        case 256: return layerColor(effectiveLayer(entity, context))
        case let index: return DXFImportColors.color(index: abs(index))
        }
    }

    /// The entity's lineweight in hundredths of a millimetre, BYLAYER and BYBLOCK resolved;
    /// negative is the default.
    func lineweight(_ entity: DXFImportEntity, _ context: Context) -> Int {
        switch entity.int(370, -1) {
        case -1: return layers[effectiveLayer(entity, context)]?.lineweight ?? -3
        case -2: return context.byBlockLineweight
        case let value: return value
        }
    }

    /// The default lineweight, AutoCAD's `LWDEFAULT`: 0.25 mm.
    static let defaultLineweight = 25

    func stroke(_ entity: DXFImportEntity, _ context: Context, width: Double? = nil) -> ImportedStroke {
        var color = color(entity, context)
        if options.whiteStrokesToBlack && DXFImportColors.isWhite(color) {
            color = .black
        }
        let weight = lineweight(entity, context)
        let points = width ?? Double(weight < 0 ? DXFImportConverter.defaultLineweight : weight) / 100 * 72 / 25.4
        return ImportedStroke(paint: .solid(color), style: StrokeStyle(width: points, cap: .round, join: .round))
    }

    func fill(_ entity: DXFImportEntity, _ context: Context) -> ImportedPaint {
        let color = color(entity, context)
        return .solid(options.whiteFillsToBlack && DXFImportColors.isWhite(color) ? .black : color)
    }

    /// The object coordinate system: entities extruded along −Z are mirrored in x; any other
    /// tilt is drawn as seen along its own axis.
    func ocs(_ entity: DXFImportEntity) -> AffineTransform {
        let normal = (entity.double(210), entity.double(220), entity.double(230, 1))
        if abs(normal.0) > 1e-6 || abs(normal.1) > 1e-6 {
            skip("tilted extrusion (drawn along its own axis)")
        }
        return normal.2 < 0 ? .scale(x: -1, y: 1) : .identity
    }

    func skip(_ type: String) {
        if !skipped.contains(type) {
            skipped.append(type)
        }
    }

    /// Points per local unit along both axes (the geometric mean of the transform's scales).
    static func scale(_ transform: AffineTransform) -> Double {
        abs(transform.determinant).squareRoot()
    }

    // MARK: Entities

    func convert(_ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        switch entity.type {
        case "LINE":
            var builder = ImportPathBuilder()
            builder.move(to: entity.point(10))
            builder.line(to: entity.point(11))
            return stroked(builder, entity, context, transform: context.transform)
        case "LWPOLYLINE":
            let vertices = lightweightVertices(entity)
            return polyline(vertices, closed: entity.int(70) & 1 != 0, width: entity.double(43), entity, context)
        case "POLYLINE":
            return heavyPolyline(entity, context)
        case "CIRCLE":
            var builder = ImportPathBuilder()
            let transform = ocs(entity).concatenating(context.transform)
            builder.dxfArc(center: entity.point(10), rx: entity.double(40), ry: entity.double(40), start: 0, sweep: 2 * .pi, scale: DXFImportConverter.scale(transform))
            builder.close()
            return stroked(builder, entity, context, transform: transform)
        case "ARC":
            var builder = ImportPathBuilder()
            let transform = ocs(entity).concatenating(context.transform)
            let start = entity.double(50) * .pi / 180
            builder.dxfArc(center: entity.point(10), rx: entity.double(40), ry: entity.double(40), start: start, sweep: DXFImportConverter.sweep(from: entity.double(50), to: entity.double(51)) * .pi / 180, scale: DXFImportConverter.scale(transform))
            return stroked(builder, entity, context, transform: transform)
        case "ELLIPSE":
            var builder = ImportPathBuilder()
            let full = ellipse(&builder, center: entity.point(10), major: entity.point(11), ratio: entity.double(40, 1), start: entity.double(41), end: entity.double(42, 2 * .pi), clockwise: false, scale: DXFImportConverter.scale(context.transform))
            if full {
                builder.close()
            }
            return stroked(builder, entity, context, transform: context.transform)
        case "SPLINE":
            return spline(entity, context)
        case "HATCH":
            return hatch(entity, context)
        case "SOLID", "TRACE":
            var builder = ImportPathBuilder()
            let third = entity.has(13) ? entity.point(13) : entity.point(12)
            builder.move(to: entity.point(10))
            builder.line(to: entity.point(11))
            builder.line(to: third)
            builder.line(to: entity.point(12))
            builder.close()
            let transform = ocs(entity).concatenating(context.transform)
            return [.path(ImportedPath(contours: builder.build().map { $0.applying(transform) }, fill: fill(entity, context)))]
        case "TEXT":
            return [text(entity, context, vertical: 73)].compactMap { $0 }
        case "MTEXT":
            return [mtext(entity, context)].compactMap { $0 }
        case "INSERT":
            return insert(entity, context)
        case "DIMENSION":
            guard let block = entity.string(2) else {
                return []
            }
            return expand(block, entity, context, transform: context.transform, color: color(entity, context), lineweight: lineweight(entity, context))
        case "ATTDEF", "SEQEND", "VIEWPORT":
            return []
        default:
            skip(entity.type)
            return []
        }
    }

    /// Clockwise-positive-free sweep in degrees from `start` to `end` counter-clockwise, in
    /// (0, 360].
    static func sweep(from start: Double, to end: Double) -> Double {
        var sweep = (end - start).truncatingRemainder(dividingBy: 360)
        if sweep <= 1e-9 {
            sweep += 360
        }
        return sweep
    }

    /// An elliptical arc from parameter `start` to `end` (radians); true when it is whole.
    @discardableResult
    func ellipse(_ builder: inout ImportPathBuilder, center: Point, major: Point, ratio: Double, start: Double, end: Double, clockwise: Bool, scale: Double) -> Bool {
        let rx = hypot(major.x, major.y)
        var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep <= 1e-9 {
            sweep += 2 * .pi
        }
        builder.dxfArc(center: center, rx: rx, ry: rx * ratio, rotation: atan2(major.y, major.x), start: clockwise ? -start : start, sweep: clockwise ? -sweep : sweep, scale: scale)
        return abs(sweep - 2 * .pi) < 1e-9
    }

    func stroked(_ builder: ImportPathBuilder, _ entity: DXFImportEntity, _ context: Context, transform: AffineTransform, width: Double? = nil) -> [ImportedNode] {
        var builder = builder
        let contours = builder.build().map { $0.applying(transform) }
        return [.path(ImportedPath(contours: contours, stroke: stroke(entity, context, width: width)))]
    }

    // MARK: Polylines

    struct Vertex {
        var point: Point
        var bulge: Double
    }

    func lightweightVertices(_ entity: DXFImportEntity) -> [Vertex] {
        var vertices: [Vertex] = []
        for pair in entity.pairs {
            switch pair.code {
            case 10: vertices.append(Vertex(point: Point(x: pair.double, y: 0), bulge: 0))
            case 20 where !vertices.isEmpty: vertices[vertices.count - 1].point.y = pair.double
            case 42 where !vertices.isEmpty: vertices[vertices.count - 1].bulge = pair.double
            default: break
            }
        }
        return vertices
    }

    func heavyPolyline(_ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        let flags = entity.int(70)
        if flags & (16 | 64) != 0 {
            skip("polyface and polygon meshes")
            return []
        }
        // Spline frame control points (flag 16) are not on the curve; fit vertices are.
        let vertices = entity.children.filter { $0.int(70) & 16 == 0 }.map { Vertex(point: $0.point(10), bulge: $0.double(42)) }
        return polyline(vertices, closed: flags & 1 != 0, width: entity.double(40), entity, context)
    }

    func polyline(_ vertices: [Vertex], closed: Bool, width: Double, _ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        guard let first = vertices.first else {
            return []
        }
        let transform = ocs(entity).concatenating(context.transform)
        let scale = DXFImportConverter.scale(transform)
        var builder = ImportPathBuilder()
        builder.move(to: first.point)
        for (index, vertex) in vertices.enumerated().dropFirst() {
            builder.dxfBulge(vertices[index - 1].bulge, to: vertex.point, scale: scale)
        }
        if closed {
            builder.dxfBulge(vertices[vertices.count - 1].bulge, to: first.point, scale: scale)
            builder.close()
        }
        return stroked(builder, entity, context, transform: transform, width: width > 0 ? width * DXFImportConverter.scale(transform) : nil)
    }

    // MARK: Splines

    func spline(_ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        var controls: [Point] = []
        var fits: [Point] = []
        var knots: [Double] = []
        var weights: [Double] = []
        for pair in entity.pairs {
            switch pair.code {
            case 10: controls.append(Point(x: pair.double, y: 0))
            case 20 where !controls.isEmpty: controls[controls.count - 1].y = pair.double
            case 11: fits.append(Point(x: pair.double, y: 0))
            case 21 where !fits.isEmpty: fits[fits.count - 1].y = pair.double
            case 40: knots.append(pair.double)
            case 41: weights.append(pair.double)
            default: break
            }
        }
        let closed = entity.int(70) & 1 != 0
        var builder = ImportPathBuilder()
        let tolerance = 0.01 / max(DXFImportConverter.scale(context.transform), 1e-12)
        if !DXFImportSpline.draw(into: &builder, degree: entity.int(71, 3), knots: knots, controls: controls, weights: weights, tolerance: tolerance) {
            guard fits.count >= 2 else {
                skip("SPLINE without control or fit points")
                return []
            }
            DXFImportSpline.throughPoints(into: &builder, fits, closed: closed)
        }
        if closed {
            builder.close()
        }
        return stroked(builder, entity, context, transform: context.transform)
    }

    // MARK: Hatches

    func hatch(_ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        guard let start = entity.pairs.firstIndex(where: { $0.code == 91 }) else {
            return []
        }
        var reader = DXFImportCursor(pairs: entity.pairs, index: start + 1)
        let count = entity.pairs[start].int
        let transform = ocs(entity).concatenating(context.transform)
        let scale = DXFImportConverter.scale(transform)
        var builder = ImportPathBuilder()
        for _ in 0..<count {
            guard let flags = reader.next(92)?.int else { break }
            if flags & 2 != 0 {
                let bulges = reader.int(72, 0)
                reader.next(73)
                let vertices = reader.int(93, 0)
                var points: [Vertex] = []
                for _ in 0..<vertices {
                    let x = reader.double(10, 0)
                    let y = reader.double(20, 0)
                    points.append(Vertex(point: Point(x: x, y: y), bulge: bulges != 0 ? reader.double(42) : 0))
                }
                if let first = points.first {
                    builder.move(to: first.point)
                    for (index, vertex) in points.enumerated().dropFirst() {
                        builder.dxfBulge(points[index - 1].bulge, to: vertex.point, scale: scale)
                    }
                    builder.dxfBulge(points[points.count - 1].bulge, to: first.point, scale: scale)
                    builder.close()
                }
            } else {
                let edges = reader.int(93, 0)
                builder.finishContour()
                for _ in 0..<edges {
                    edge(&builder, &reader, scale: scale)
                }
                builder.close()
            }
        }
        if entity.int(70) == 0 {
            notes.append("A hatch pattern in “\(name)” was imported as a solid fill.")
        }
        let contours = builder.build().map { $0.applying(transform) }
        guard !contours.isEmpty else {
            return []
        }
        return [.path(ImportedPath(contours: contours, fill: fill(entity, context), fillRule: .evenOdd))]
    }

    /// One boundary edge: line (1), circular arc (2), elliptic arc (3) or spline (4).
    func edge(_ builder: inout ImportPathBuilder, _ reader: inout DXFImportCursor, scale: Double) {
        func connect(_ point: Point) {
            if builder.hasCurrentContour {
                builder.line(to: point)
            } else {
                builder.move(to: point)
            }
        }
        switch reader.int(72, 1) {
        case 2:
            let center = reader.point(10)
            let radius = reader.double(40, 0)
            let start = reader.double(50, 0)
            let end = reader.double(51, 360)
            let clockwise = (reader.int(73, 1)) == 0
            let sweep = DXFImportConverter.sweep(from: start, to: end) * .pi / 180
            builder.dxfArc(center: center, rx: radius, ry: radius, start: (clockwise ? -start : start) * .pi / 180, sweep: clockwise ? -sweep : sweep, scale: scale)
        case 3:
            let center = reader.point(10)
            let major = reader.point(11)
            let ratio = reader.double(40, 1)
            let start = (reader.double(50, 0)) * .pi / 180
            let end = (reader.double(51, 360)) * .pi / 180
            let clockwise = (reader.int(73, 1)) == 0
            ellipse(&builder, center: center, major: major, ratio: ratio, start: start, end: end, clockwise: clockwise, scale: scale)
        case 4:
            let degree = reader.int(94, 3)
            let rational = (reader.int(73, 0)) != 0
            reader.next(74)
            let knotCount = reader.int(95, 0)
            let controlCount = reader.int(96, 0)
            let knots = (0..<knotCount).map { _ in reader.double(40, 0) }
            var controls: [Point] = []
            var weights: [Double] = []
            for _ in 0..<controlCount {
                controls.append(reader.point(10))
                if rational {
                    weights.append(reader.double(42, 1))
                }
            }
            if let first = controls.first {
                connect(first)
            }
            _ = DXFImportSpline.draw(into: &builder, degree: degree, knots: knots, controls: controls, weights: weights, tolerance: 1e-3)
        default:
            let from = reader.point(10)
            let to = reader.point(11)
            connect(from)
            builder.line(to: to)
        }
    }

    // MARK: Text

    /// The cap height of Helvetica as a fraction of its size: DXF heights are cap heights.
    static let font = "Helvetica"
    static let capHeight: Double = {
        let font = CTFontCreateWithName(DXFImportConverter.font as CFString, 100, nil)
        return Double(CTFontGetCapHeight(font)) / 100
    }()

    static func width(of text: String, size: Double) -> Double {
        let font = CTFontCreateWithName(DXFImportConverter.font as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// TEXT and ATTRIB (vertical justification in `vertical`: 73 for TEXT, 74 for ATTRIB).
    func text(_ entity: DXFImportEntity, _ context: Context, vertical: Int) -> ImportedNode? {
        let string = DXFImportText.specials(entity.string(1) ?? "")
        let horizontal = entity.int(72)
        let verticalCode = entity.int(vertical)
        let aligned = (horizontal != 0 || verticalCode != 0) && entity.has(11)
        let anchor = aligned ? entity.point(11) : entity.point(10)
        let justification: (h: Double, v: Int)
        switch horizontal {
        case 1: justification = (0.5, verticalCode)
        case 2: justification = (1, verticalCode)
        case 4: justification = (0.5, 2)
        default: justification = (0, verticalCode)
        }
        return placeText([string], at: anchor, height: entity.double(40, 1), rotation: entity.double(50), horizontal: justification.h, vertical: justification.v, entity, context)
    }

    func mtext(_ entity: DXFImportEntity, _ context: Context) -> ImportedNode? {
        let raw = entity.pairs.filter { $0.code == 3 }.map(\.value).joined() + (entity.string(1) ?? "")
        let lines = DXFImportText.plain(raw).components(separatedBy: "\n")
        var rotation = entity.double(50)
        if entity.has(11) {
            rotation = atan2(entity.double(21), entity.double(11)) * 180 / .pi
        }
        let attachment = min(max(entity.int(71, 1), 1), 9) - 1
        // Attachment rows: top, middle, bottom; columns: left, centre, right.
        let vertical = [3, 2, 1][attachment / 3]
        return placeText(lines, at: entity.point(10), height: entity.double(40, 1), rotation: rotation, horizontal: Double(attachment % 3) / 2, vertical: vertical, entity, context, multiline: true)
    }

    /// Lines of text, the anchor at the justification point: `horizontal` 0 left, ½ centre,
    /// 1 right; `vertical` 0 baseline, 1 bottom, 2 middle, 3 top.
    func placeText(_ lines: [String], at anchor: Point, height: Double, rotation: Double, horizontal: Double, vertical: Int, _ entity: DXFImportEntity, _ context: Context, multiline: Bool = false) -> ImportedNode? {
        guard lines.contains(where: { !$0.isEmpty }) else {
            return nil
        }
        let transform = (multiline ? .identity : ocs(entity)).concatenating(context.transform)
        let angle = rotation * .pi / 180
        let direction = transform.apply(Vector(dx: cos(angle), dy: sin(angle)))
        let up = transform.apply(Vector(dx: -sin(angle), dy: cos(angle)))
        let cap = height * up.length
        let size = cap / DXFImportConverter.capHeight
        let spacing = size * 1.2
        let total = cap + spacing * Double(lines.count - 1)
        let top: Double
        switch vertical {
        case 1: top = -(total + size * 0.2)
        case 2: top = -total / 2
        case 3: top = 0
        default: top = -cap
        }
        var color = color(entity, context)
        if options.whiteFillsToBlack && DXFImportColors.isWhite(color) {
            color = .black
        }
        let runs = lines.enumerated().compactMap { index, line -> ImportedTextRun? in
            guard !line.isEmpty else { return nil }
            let x = -DXFImportConverter.width(of: line, size: size) * horizontal
            return ImportedTextRun(text: line, fontName: DXFImportConverter.font, fontSize: size, fill: .solid(color), origin: Point(x: x, y: top + cap + spacing * Double(index)))
        }
        let x = direction.normalized
        let y = (-up).normalized
        let origin = transform.apply(anchor)
        return .text(ImportedText(runs: runs, transform: AffineTransform(a: x.dx, b: x.dy, c: y.dx, d: y.dy, tx: origin.x, ty: origin.y)))
    }

    // MARK: Blocks

    func insert(_ entity: DXFImportEntity, _ context: Context) -> [ImportedNode] {
        guard let block = entity.string(2) else {
            return []
        }
        let scaleX = entity.double(41, 1)
        let scaleY = entity.double(42, 1)
        let angle = entity.double(50) * .pi / 180
        let columns = max(entity.int(70, 1), 1)
        let rows = max(entity.int(71, 1), 1)
        let rotation = AffineTransform.rotation(radians: angle)
        let ocs = ocs(entity)
        let color = color(entity, context)
        let weight = lineweight(entity, context)
        var nodes: [ImportedNode] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = rotation.apply(Vector(dx: Double(column) * entity.double(44), dy: Double(row) * entity.double(45)))
                let place = AffineTransform.scale(x: scaleX, y: scaleY).concatenating(rotation).concatenating(.translation(x: entity.double(10) + offset.dx, y: entity.double(20) + offset.dy))
                nodes += expand(block, entity, context, transform: place.concatenating(ocs).concatenating(context.transform), color: color, lineweight: weight)
            }
        }
        for attribute in entity.children where attribute.type == "ATTRIB" {
            if attribute.int(70) & 1 != 0 && !options.importInvisibleAttributes {
                continue
            }
            var attributeContext = context
            attributeContext.layer = effectiveLayer(entity, context)
            if let node = text(attribute, attributeContext, vertical: 74) {
                nodes.append(node)
            }
        }
        return nodes
    }

    /// The contents of block `name` as one group, drawn through `transform` (block space, base
    /// point at the origin, to the page).
    func expand(_ name: String, _ entity: DXFImportEntity, _ context: Context, transform: AffineTransform, color: Color, lineweight: Int) -> [ImportedNode] {
        guard let block = drawing.blocks[name] else {
            notes.append("A reference to the missing block “\(name)” was left out.")
            return []
        }
        guard !context.blocks.contains(name), context.blocks.count < 32 else {
            notes.append("The block “\(name)” refers to itself; the repetition was left out.")
            return []
        }
        var inner = context
        inner.transform = AffineTransform.translation(x: -block.base.x, y: -block.base.y).concatenating(transform)
        inner.layer = effectiveLayer(entity, context)
        inner.byBlockColor = color
        inner.byBlockLineweight = lineweight
        inner.blocks.append(name)
        let children = block.entities.flatMap { child -> [ImportedNode] in
            if child.layer != "0", layers[child.layer]?.hidden == true {
                return []
            }
            return convert(child, inner)
        }
        return children.isEmpty ? [] : [.group(ImportedGroup(children: children, name: name))]
    }
}

extension ImportPathBuilder {
    /// The largest radial error an arc may have, in points (IMG-013: bulges within 0.01 pt).
    static let dxfArcTolerance = 0.005

    /// An arc as `arc(center:…)` draws it, in pieces short enough that at `scale` points per
    /// unit no point strays more than `dxfArcTolerance` from the true arc: a Bézier of angle θ
    /// deviates by about r·θ⁶/55 000, so a quarter turn is 0.02 pt off at a one-inch radius.
    mutating func dxfArc(center: Point, rx: Double, ry: Double, rotation: Double = 0, start: Double, sweep: Double, scale: Double) {
        let radius = max(rx, ry) * scale
        let limit = min(.pi / 2, pow(ImportPathBuilder.dxfArcTolerance * 55_000 / max(radius, 1e-12), 1.0 / 6))
        let pieces = max(Int((abs(sweep) / limit - 1e-9).rounded(.up)), 1)
        let step = sweep / Double(pieces)
        for index in 0..<pieces {
            arc(center: center, rx: rx, ry: ry, rotation: rotation, start: start + step * Double(index), sweep: step)
        }
    }

    /// A DXF polyline bulge (the tangent of a quarter of the included angle, positive
    /// counter-clockwise, in the drawing's y-up space) from the current point to `end`.
    mutating func dxfBulge(_ bulge: Double, to end: Point, scale: Double) {
        guard let start = currentPoint, abs(bulge) > 1e-12, !start.isApproximatelyEqual(to: end, tolerance: 1e-12) else {
            line(to: end)
            return
        }
        let chord = end - start
        let length = chord.length
        let included = 4 * atan(bulge)
        let radius = length / (2 * sin(included / 2))
        let normal = Vector(dx: -chord.dy / length, dy: chord.dx / length)
        let center = Point.lerp(start, end, 0.5) + normal * (radius * cos(included / 2))
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        dxfArc(center: center, rx: abs(radius), ry: abs(radius), start: startAngle, sweep: included, scale: scale)
    }
}

/// A forward reader over an entity's pairs, for the sequential structures (hatch boundaries).
struct DXFImportCursor {
    let pairs: [DXFImportPair]
    var index: Int

    /// The next pair with `code` from the current position, which moves past it; nil (and no
    /// move) when there is none.
    @discardableResult
    mutating func next(_ code: Int) -> DXFImportPair? {
        guard let found = pairs[index...].firstIndex(where: { $0.code == code }) else {
            return nil
        }
        index = found + 1
        return pairs[found]
    }

    /// The next `code`'s value as a number, or `fallback` when the structure is cut short.
    mutating func double(_ code: Int, _ fallback: Double = 0) -> Double {
        next(code)?.double ?? fallback
    }

    mutating func int(_ code: Int, _ fallback: Int = 0) -> Int {
        Int(double(code, Double(fallback)))
    }

    /// The next point of `code` and `code + 10`.
    mutating func point(_ code: Int) -> Point {
        let x = double(code)
        return Point(x: x, y: double(code + 10))
    }
}

/// B-spline conversion (import-formats.adoc, "Client": "splines from control points").
enum DXFImportSpline {
    /// A point of the spline at `u` by de Boor's algorithm (homogeneous for weights).
    static func evaluate(degree p: Int, knots: [Double], controls: [Point], weights: [Double], at u: Double, span k: Int) -> Point {
        var d = (0...p).map { j -> SIMD3<Double> in
            let point = controls[j + k - p]
            let w = weights.isEmpty ? 1 : weights[j + k - p]
            return SIMD3(point.x * w, point.y * w, w)
        }
        if p > 0 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let denominator = knots[j + 1 + k - r] - knots[j + k - p]
                    // Positive on a non-empty span: the knots bracket [knots[k], knots[k + 1]].
                    let alpha = (u - knots[j + k - p]) / denominator
                    d[j] = (1 - alpha) * d[j - 1] + alpha * d[j]
                }
            }
        }
        return Point(x: d[p].x / d[p].z, y: d[p].y / d[p].z)
    }

    /// Draws a B-spline into `builder`, continuing its contour (or starting one): polynomial
    /// splines of degree 1 to 3 as exact lines and Béziers (each knot span's polynomial is
    /// sampled at four parameters and the Bézier solved from them), higher degrees and rational
    /// splines flattened within `tolerance`.  False when the data does not form a spline.
    static func draw(into builder: inout ImportPathBuilder, degree p: Int, knots: [Double], controls: [Point], weights: [Double], tolerance: Double) -> Bool {
        let n = controls.count
        guard p >= 1, n > p, knots.count == n + p + 1, weights.isEmpty || weights.count == n else {
            return false
        }
        let rational = weights.contains { abs($0 - 1) > 1e-12 }
        let evaluator = { (u: Double, k: Int) in evaluate(degree: p, knots: knots, controls: controls, weights: rational ? weights : [], at: u, span: k) }
        let startPoint = evaluator(knots[p], p)
        if builder.hasCurrentContour {
            if let here = builder.currentPoint, !here.isApproximatelyEqual(to: startPoint, tolerance: 1e-9) {
                builder.line(to: startPoint)
            }
        } else {
            builder.move(to: startPoint)
        }
        for k in p..<n where knots[k + 1] > knots[k] {
            let a = knots[k]
            let b = knots[k + 1]
            if p == 1 && !rational {
                builder.line(to: evaluator(b, k))
            } else if p <= 3 && !rational {
                let b0 = evaluator(a, k)
                let q1 = evaluator(a + (b - a) / 3, k)
                let q2 = evaluator(a + 2 * (b - a) / 3, k)
                let b3 = evaluator(b, k)
                // B(1/3) = (8 b0 + 12 b1 + 6 b2 + b3) / 27, B(2/3) = (b0 + 6 b1 + 12 b2 + 8 b3) / 27.
                let first = SIMD2(q1.x, q1.y) * 27 - SIMD2(b0.x, b0.y) * 8 - SIMD2(b3.x, b3.y)
                let second = SIMD2(q2.x, q2.y) * 27 - SIMD2(b0.x, b0.y) - SIMD2(b3.x, b3.y) * 8
                let b1 = (first * 2 - second) / 18
                let b2 = (second * 2 - first) / 18
                builder.cubic(Point(x: b1.x, y: b1.y), Point(x: b2.x, y: b2.y), b3)
            } else {
                flatten(&builder, from: a, to: b, span: k, depth: 0, tolerance: tolerance, evaluate: evaluator)
            }
        }
        return true
    }

    static func flatten(_ builder: inout ImportPathBuilder, from a: Double, to b: Double, span k: Int, depth: Int, tolerance: Double, evaluate: (Double, Int) -> Point) {
        let start = evaluate(a, k)
        let end = evaluate(b, k)
        let middle = evaluate((a + b) / 2, k)
        let deviation = (middle - Point.lerp(start, end, 0.5)).length
        if depth >= 12 || (deviation <= tolerance && depth >= 2) {
            builder.line(to: end)
            return
        }
        flatten(&builder, from: a, to: (a + b) / 2, span: k, depth: depth + 1, tolerance: tolerance, evaluate: evaluate)
        flatten(&builder, from: (a + b) / 2, to: b, span: k, depth: depth + 1, tolerance: tolerance, evaluate: evaluate)
    }

    /// A smooth curve through fit points (a Catmull-Rom spline as Béziers), used when a SPLINE
    /// carries only fit data.
    static func throughPoints(into builder: inout ImportPathBuilder, _ points: [Point], closed: Bool) {
        builder.move(to: points[0])
        let count = points.count
        let segments = closed ? count : count - 1
        func at(_ index: Int) -> Point {
            closed ? points[(index % count + count) % count] : points[min(max(index, 0), count - 1)]
        }
        for index in 0..<segments {
            let p0 = at(index - 1), p1 = at(index), p2 = at(index + 1), p3 = at(index + 2)
            builder.cubic(p1 + (p2 - p0) / 6, p2 + (p1 - p3) / 6, p2)
        }
    }
}

/// DXF text codes.
enum DXFImportText {
    /// `%%d`, `%%c`, `%%p`, `%%%` as characters; `%%u` and `%%o` (underline and overline
    /// toggles) removed; `%%nnn` as the character with that code.
    static func specials(_ text: String) -> String {
        guard text.contains("%%") else {
            return text
        }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "%%") {
            result += rest[..<range.lowerBound]
            rest = rest[range.upperBound...]
            let code = rest.first.map { String($0).lowercased() }
            switch code {
            case "d": result += "°"
            case "c": result += "⌀"
            case "p": result += "±"
            case "%": result += "%"
            case "u", "o": break
            default:
                let digits = rest.prefix(3)
                if digits.count == 3, let value = UInt32(digits), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                    rest = rest.dropFirst(3)
                } else {
                    result += "%%"
                }
                continue
            }
            rest = rest.dropFirst()
        }
        return result + rest
    }

    /// MTEXT with its inline formatting removed: `\P` is a new paragraph, `\~` a no-break space,
    /// `\\`, `\{`, `\}` literal; codes ending in `;` (`\f…;`, `\H…;`, `\C…;`, `\A…;`, `\S…;` whose
    /// stacked parts are joined with "/") and toggles (`\L`, `\O`, `\K`…) removed; braces dropped.
    static func plain(_ text: String) -> String {
        var result = ""
        let characters = Array(specials(text))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "{" || character == "}" {
                continue
            }
            guard character == "\\", index < characters.count else {
                result.append(character)
                continue
            }
            let code = characters[index]
            index += 1
            switch code {
            case "P", "n": result.append("\n")
            case "~": result.append("\u{00A0}")
            case "\\", "{", "}": result.append(code)
            case "L", "l", "O", "o", "K", "k": break
            case "S":
                let end = characters[index...].firstIndex(of: ";") ?? characters.count
                result += String(characters[index..<end]).replacingOccurrences(of: "^", with: "/").replacingOccurrences(of: "#", with: "/")
                index = min(end + 1, characters.count)
            default:
                let end = characters[index...].firstIndex(of: ";") ?? characters.count
                index = min(end + 1, characters.count)
            }
        }
        return result
    }
}
