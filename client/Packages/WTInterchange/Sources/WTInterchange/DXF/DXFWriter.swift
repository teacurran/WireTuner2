// The DXF writer (export-vector.adoc, "Client", *DXF writer*; IO-020): ASCII DXF of a page's
// outlines.  Paths become `LWPOLYLINE`s (R12: `POLYLINE`/`VERTEX`/`SEQEND`) with curves flattened to
// the tolerance, or `SPLINE`s -- degree 3, the Béziers' own control points with triple interior
// knots, so the curve is exactly the path -- when splines are chosen.  Each contour of a path is its
// own entity, so a compound path keeps its holes as separate closed polylines.  Layers come from
// the display list's layer groups; y is flipped to DXF's y-up with the page's lower-left corner at
// the origin; `$INSUNITS` carries the unit.  R2000 and 2018 files carry the tables, block records,
// blocks and object dictionary with handles and owners that AutoCAD-family readers expect.

import Foundation
import WTGeometry
import WTRender

/// One contour in drawing units.
struct DXFContour: Equatable {
    enum Segment: Equatable {
        case line(Point)
        case cubic(Point, Point, Point)
    }

    var start: Point
    var segments: [Segment]
    var closed: Bool

    var hasCurves: Bool {
        segments.contains { if case .cubic = $0 { return true } else { return false } }
    }

    /// The vertices, curves flattened so no point of a curve lies farther than `tolerance`
    /// from its chords.  A closed contour does not repeat its start.
    func polyline(tolerance: Double) -> [Point] {
        var points = [start]
        var current = start
        for segment in segments {
            switch segment {
            case .line(let end):
                points.append(end)
                current = end
            case .cubic(let c1, let c2, let end):
                DXFContour.flatten(current, c1, c2, end, tolerance: max(tolerance, 1e-6), depth: 0, into: &points)
                current = end
            }
        }
        if closed, points.count > 1, let last = points.last, (last - start).length < 1e-9 {
            points.removeLast()
        }
        return points
    }

    /// Recursive subdivision until the control points lie within `tolerance` of the chord.
    static func flatten(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point, tolerance: Double, depth: Int, into points: inout [Point]) {
        let chord = p3 - p0
        let length = chord.length
        func distance(_ p: Point) -> Double {
            length < 1e-12 ? (p - p0).length : abs(chord.cross(p - p0)) / length
        }
        if depth >= 16 || max(distance(p1), distance(p2)) <= tolerance {
            points.append(p3)
            return
        }
        let p01 = Point.lerp(p0, p1, 0.5), p12 = Point.lerp(p1, p2, 0.5), p23 = Point.lerp(p2, p3, 0.5)
        let a = Point.lerp(p01, p12, 0.5), b = Point.lerp(p12, p23, 0.5), mid = Point.lerp(a, b, 0.5)
        flatten(p0, p01, a, mid, tolerance: tolerance, depth: depth + 1, into: &points)
        flatten(mid, b, p23, p3, tolerance: tolerance, depth: depth + 1, into: &points)
    }

    /// The contour as one clamped cubic B-spline: control points and knots (every Bézier joint
    /// a triple knot, so the spline passes through it with the Bézier's own tangents).
    var spline: (controls: [Point], knots: [Double]) {
        var controls = [start]
        var current = start
        for segment in segments {
            switch segment {
            case .line(let end):
                controls += [current + (end - current) * (1.0 / 3), current + (end - current) * (2.0 / 3), end]
                current = end
            case .cubic(let c1, let c2, let end):
                controls += [c1, c2, end]
                current = end
            }
        }
        if closed, (current - start).length > 1e-9 {
            controls += [current + (start - current) * (1.0 / 3), current + (start - current) * (2.0 / 3), start]
        }
        let spans = (controls.count - 1) / 3
        var knots = [0.0, 0, 0, 0]
        for span in 1..<max(spans, 1) {
            knots += [Double(span), Double(span), Double(span)]
        }
        knots += [Double(spans), Double(spans), Double(spans), Double(spans)]
        return (controls, knots)
    }

    /// The contours of `path` mapped by `transform`, quadratics raised to cubics.  Contours of
    /// a filled path are closed.
    static func contours(of path: DisplayPath, transform: AffineTransform, filled: Bool) -> [DXFContour] {
        var result: [DXFContour] = []
        var open: DXFContour?
        var current = Point.zero
        func finish() {
            if var contour = open, !contour.segments.isEmpty {
                contour.closed = contour.closed || filled
                result.append(contour)
            }
            open = nil
        }
        for element in path.elements {
            switch element {
            case .move(let p):
                finish()
                current = transform.apply(p)
                open = DXFContour(start: current, segments: [], closed: false)
            case .line(let p):
                let end = transform.apply(p)
                open = open ?? DXFContour(start: current, segments: [], closed: false)
                open?.segments.append(.line(end))
                current = end
            case .quadCurve(let control, let p):
                let c = transform.apply(control), end = transform.apply(p)
                open = open ?? DXFContour(start: current, segments: [], closed: false)
                open?.segments.append(.cubic(current + (c - current) * (2.0 / 3), end + (c - end) * (2.0 / 3), end))
                current = end
            case .cubicCurve(let c1, let c2, let p):
                let end = transform.apply(p)
                open = open ?? DXFContour(start: current, segments: [], closed: false)
                open?.segments.append(.cubic(transform.apply(c1), transform.apply(c2), end))
                current = end
            case .close:
                if let start = open?.start {
                    open?.closed = true
                    current = start
                    finish()
                    open = nil
                }
            }
        }
        finish()
        return result
    }
}

/// Writes one page's outlines as DXF.
public struct DXFWriter: Sendable {
    public var options: DXFOptions

    public init(options: DXFOptions = .defaults) {
        self.options = options
    }

    /// `page` (flattened for DXF) as a DXF file, and notes.
    public func write(_ page: FlatPage, scene: ExportScene) -> (data: Data, notes: [String]) {
        let build = DXFBuild(options: options, scene: scene, page: page)
        return (Data(build.document().utf8), build.notes)
    }
}

final class DXFBuild {
    let options: DXFOptions
    let scene: ExportScene
    let page: FlatPage
    /// Pasteboard → drawing units, y up, page's lower-left at the origin.
    let toDrawing: AffineTransform
    var notes: [String] = []
    /// Layer names in first-use order ("0" first).
    var layers: [String] = ["0"]
    private var layerNames: [NodeID: String] = [:]
    var entities: [(layer: String, contour: DXFContour)] = []
    var skippedImages = 0
    var ignoredClips = 0
    private var out = ""
    private var nextHandle = 0x20

    init(options: DXFOptions, scene: ExportScene, page: FlatPage) {
        self.options = options
        self.scene = scene
        self.page = page
        let k = options.units.perPoint
        toDrawing = AffineTransform(a: k, b: 0, c: 0, d: -k, tx: -page.bounds.minX * k, ty: page.bounds.maxY * k)
    }

    var isR12: Bool { options.version == .r12 }

    // MARK: Collecting

    func collect(_ nodes: [FlatNode], layer: String) {
        for node in nodes {
            var current = layer
            if options.layersFromDocument, let id = node.node, let info = scene.nodes[id], info.isLayer {
                current = layerName(for: id, name: info.name)
            }
            switch node {
            case .path(let path):
                let filled: Bool
                if case .fill = path.style { filled = true } else { filled = false }
                for contour in DXFContour.contours(of: path.path, transform: path.transform.concatenating(toDrawing), filled: filled) {
                    entities.append((current, contour))
                }
            case .group(let group):
                if group.clip != nil {
                    ignoredClips += 1
                }
                collect(group.children, layer: current)
            case .image:
                skippedImages += 1
            case .text:
                // The flattener outlines all text for DXF.
                break
            }
        }
    }

    /// A unique DXF layer name for a layer node: characters DXF forbids replaced, "Layer" when
    /// empty, numbered on collision.
    func layerName(for id: NodeID, name: String?) -> String {
        if let existing = layerNames[id] {
            return existing
        }
        let forbidden = Set("<>/\\\":;?*|=`,")
        var base = String((name ?? "").map { forbidden.contains($0) || $0.isNewline ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
        if base.isEmpty {
            base = "Layer"
        }
        var candidate = base
        var index = 2
        while layers.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        layers.append(candidate)
        layerNames[id] = candidate
        return candidate
    }

    // MARK: Writing

    func pair(_ code: Int, _ value: String) {
        out += "\(code)\n\(value)\n"
    }

    func pair(_ code: Int, _ value: Double) {
        pair(code, Numbers.format(value, places: 6))
    }

    func pair(_ code: Int, _ value: Int) {
        pair(code, String(value))
    }

    func handle() -> String {
        defer { nextHandle += 1 }
        return String(nextHandle, radix: 16, uppercase: true)
    }

    /// A string value: R2018 is UTF-8; older versions escape non-ASCII as `\U+XXXX`.
    func text(_ value: String) -> String {
        if options.version == .v2018 {
            return value
        }
        var result = ""
        for scalar in value.unicodeScalars {
            if scalar.value < 0x80 {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(format: "\\U+%04X", scalar.value)
            }
        }
        return result
    }

    func document() -> String {
        collect(page.nodes, layer: "0")
        if !options.layersFromDocument {
            layers = ["0"]
        }
        let extents = entities.flatMap { $0.contour.polyline(tolerance: options.tolerancePoints * options.units.perPoint) }
        let minX = extents.map(\.x).min() ?? 0, minY = extents.map(\.y).min() ?? 0
        let maxX = extents.map(\.x).max() ?? 0, maxY = extents.map(\.y).max() ?? 0
        let width = page.bounds.width * options.units.perPoint, height = page.bounds.height * options.units.perPoint
        if isR12 {
            writeR12(extents: (minX, minY, maxX, maxY), size: (width, height))
        } else {
            writeModern(extents: (minX, minY, maxX, maxY), size: (width, height))
        }
        if skippedImages > 0 {
            notes.append("\(skippedImages) image\(skippedImages == 1 ? "" : "s") left out (DXF carries outlines only)")
        }
        if ignoredClips > 0 {
            notes.append("\(ignoredClips) clipping path\(ignoredClips == 1 ? "" : "s") ignored: clipped artwork is written whole")
        }
        if options.units == .document || options.units == .points {
            notes.append("drawing units are points ($INSUNITS unitless): DXF has no point unit\(options.units == .document ? ", and the document's units do not reach the exporter yet" : "")")
        }
        return out
    }

    func header(version: String, extents: (Double, Double, Double, Double), size: (Double, Double), handseed: String?) {
        pair(0, "SECTION")
        pair(2, "HEADER")
        pair(9, "$ACADVER")
        pair(1, version)
        if !isR12 {
            pair(9, "$ACADMAINTVER")
            pair(70, 20)
        }
        pair(9, "$DWGCODEPAGE")
        pair(3, "ANSI_1252")
        pair(9, "$INSBASE")
        pair(10, 0.0)
        pair(20, 0.0)
        pair(30, 0.0)
        pair(9, "$EXTMIN")
        pair(10, extents.0)
        pair(20, extents.1)
        pair(30, 0.0)
        pair(9, "$EXTMAX")
        pair(10, extents.2)
        pair(20, extents.3)
        pair(30, 0.0)
        pair(9, "$LIMMIN")
        pair(10, 0.0)
        pair(20, 0.0)
        pair(9, "$LIMMAX")
        pair(10, size.0)
        pair(20, size.1)
        if !isR12 {
            pair(9, "$INSUNITS")
            pair(70, options.units.insUnits)
        }
        pair(9, "$MEASUREMENT")
        pair(70, options.units == .inches ? 0 : 1)
        if let handseed {
            pair(9, "$HANDSEED")
            pair(5, handseed)
        }
        pair(0, "ENDSEC")
    }

    // MARK: R12

    func writeR12(extents: (Double, Double, Double, Double), size: (Double, Double)) {
        header(version: "AC1009", extents: extents, size: size, handseed: nil)
        pair(0, "SECTION")
        pair(2, "TABLES")
        pair(0, "TABLE")
        pair(2, "LTYPE")
        pair(70, 1)
        pair(0, "LTYPE")
        pair(2, "CONTINUOUS")
        pair(70, 0)
        pair(3, "Solid line")
        pair(72, 65)
        pair(73, 0)
        pair(40, 0.0)
        pair(0, "ENDTAB")
        pair(0, "TABLE")
        pair(2, "LAYER")
        pair(70, layers.count)
        for layer in layers {
            pair(0, "LAYER")
            pair(2, text(layer))
            pair(70, 0)
            pair(62, 7)
            pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")
        pair(0, "SECTION")
        pair(2, "ENTITIES")
        for entity in entities {
            let points = entity.contour.polyline(tolerance: options.tolerancePoints * options.units.perPoint)
            let layer = text(options.layersFromDocument ? entity.layer : "0")
            pair(0, "POLYLINE")
            pair(8, layer)
            pair(66, 1)
            pair(10, 0.0)
            pair(20, 0.0)
            pair(30, 0.0)
            pair(70, entity.contour.closed ? 1 : 0)
            for point in points {
                pair(0, "VERTEX")
                pair(8, layer)
                pair(10, point.x)
                pair(20, point.y)
                pair(30, 0.0)
            }
            pair(0, "SEQEND")
            pair(8, layer)
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
    }

    // MARK: R2000 and 2018

    func table(_ name: String, entries: Int, subclass: String? = nil, body: (String) -> Void) {
        let own = handle()
        pair(0, "TABLE")
        pair(2, name)
        pair(5, own)
        pair(330, "0")
        pair(100, "AcDbSymbolTable")
        pair(70, entries)
        if let subclass {
            pair(100, subclass)
        }
        body(own)
        pair(0, "ENDTAB")
    }

    func record(_ type: String, owner: String, subclass: String) -> String {
        let own = handle()
        pair(0, type)
        pair(5, own)
        pair(330, owner)
        pair(100, "AcDbSymbolTableRecord")
        pair(100, subclass)
        return own
    }

    func writeModern(extents: (Double, Double, Double, Double), size: (Double, Double)) {
        // Handles are assigned while writing; the header's $HANDSEED is patched in at the end.
        let placeholder = "HANDSEED-PLACEHOLDER"
        header(version: options.version == .v2018 ? "AC1032" : "AC1015", extents: extents, size: size, handseed: placeholder)
        pair(0, "SECTION")
        pair(2, "CLASSES")
        pair(0, "ENDSEC")
        pair(0, "SECTION")
        pair(2, "TABLES")
        table("VPORT", entries: 1) { owner in
            _ = record("VPORT", owner: owner, subclass: "AcDbViewportTableRecord")
            pair(2, "*Active")
            pair(70, 0)
            pair(10, 0.0)
            pair(20, 0.0)
            pair(11, 1.0)
            pair(21, 1.0)
            pair(12, size.0 / 2)
            pair(22, size.1 / 2)
            pair(40, max(size.1, 1))
            pair(41, size.1 > 0 ? size.0 / size.1 : 1)
        }
        table("LTYPE", entries: 3) { owner in
            for (name, description) in [("ByBlock", ""), ("ByLayer", ""), ("Continuous", "Solid line")] {
                _ = record("LTYPE", owner: owner, subclass: "AcDbLinetypeTableRecord")
                pair(2, name)
                pair(70, 0)
                pair(3, description)
                pair(72, 65)
                pair(73, 0)
                pair(40, 0.0)
            }
        }
        table("LAYER", entries: layers.count) { owner in
            for layer in layers {
                _ = record("LAYER", owner: owner, subclass: "AcDbLayerTableRecord")
                pair(2, text(layer))
                pair(70, 0)
                pair(62, 7)
                pair(6, "Continuous")
                pair(370, -3)
            }
        }
        table("STYLE", entries: 1) { owner in
            _ = record("STYLE", owner: owner, subclass: "AcDbTextStyleTableRecord")
            pair(2, "Standard")
            pair(70, 0)
            pair(40, 0.0)
            pair(41, 1.0)
            pair(50, 0.0)
            pair(71, 0)
            pair(42, 2.5)
            pair(3, "txt")
            pair(4, "")
        }
        table("VIEW", entries: 0) { _ in }
        table("UCS", entries: 0) { _ in }
        table("APPID", entries: 1) { owner in
            _ = record("APPID", owner: owner, subclass: "AcDbRegAppTableRecord")
            pair(2, "ACAD")
            pair(70, 0)
        }
        table("DIMSTYLE", entries: 1, subclass: "AcDbDimStyleTable") { owner in
            let own = handle()
            pair(0, "DIMSTYLE")
            pair(105, own)
            pair(330, owner)
            pair(100, "AcDbSymbolTableRecord")
            pair(100, "AcDbDimStyleTableRecord")
            pair(2, "Standard")
            pair(70, 0)
        }
        var modelSpace = ""
        var paperSpace = ""
        table("BLOCK_RECORD", entries: 2) { owner in
            modelSpace = record("BLOCK_RECORD", owner: owner, subclass: "AcDbBlockTableRecord")
            pair(2, "*Model_Space")
            paperSpace = record("BLOCK_RECORD", owner: owner, subclass: "AcDbBlockTableRecord")
            pair(2, "*Paper_Space")
        }
        pair(0, "ENDSEC")
        pair(0, "SECTION")
        pair(2, "BLOCKS")
        for (name, owner, paper) in [("*Model_Space", modelSpace, false), ("*Paper_Space", paperSpace, true)] {
            pair(0, "BLOCK")
            pair(5, handle())
            pair(330, owner)
            pair(100, "AcDbEntity")
            if paper {
                pair(67, 1)
            }
            pair(8, "0")
            pair(100, "AcDbBlockBegin")
            pair(2, name)
            pair(70, 0)
            pair(10, 0.0)
            pair(20, 0.0)
            pair(30, 0.0)
            pair(3, name)
            pair(1, "")
            pair(0, "ENDBLK")
            pair(5, handle())
            pair(330, owner)
            pair(100, "AcDbEntity")
            if paper {
                pair(67, 1)
            }
            pair(8, "0")
            pair(100, "AcDbBlockEnd")
        }
        pair(0, "ENDSEC")
        pair(0, "SECTION")
        pair(2, "ENTITIES")
        let tolerance = options.tolerancePoints * options.units.perPoint
        for entity in entities {
            let layer = text(options.layersFromDocument ? entity.layer : "0")
            if options.splines && entity.contour.hasCurves {
                writeSpline(entity.contour, layer: layer, owner: modelSpace)
            } else {
                let points = entity.contour.polyline(tolerance: tolerance)
                pair(0, "LWPOLYLINE")
                pair(5, handle())
                pair(330, modelSpace)
                pair(100, "AcDbEntity")
                pair(8, layer)
                pair(100, "AcDbPolyline")
                pair(90, points.count)
                pair(70, entity.contour.closed ? 1 : 0)
                pair(43, 0.0)
                for point in points {
                    pair(10, point.x)
                    pair(20, point.y)
                }
            }
        }
        pair(0, "ENDSEC")
        pair(0, "SECTION")
        pair(2, "OBJECTS")
        let root = handle()
        let groups = handle()
        pair(0, "DICTIONARY")
        pair(5, root)
        pair(330, "0")
        pair(100, "AcDbDictionary")
        pair(281, 1)
        pair(3, "ACAD_GROUP")
        pair(350, groups)
        pair(0, "DICTIONARY")
        pair(5, groups)
        pair(330, root)
        pair(100, "AcDbDictionary")
        pair(281, 1)
        pair(0, "ENDSEC")
        pair(0, "EOF")
        out = out.replacingOccurrences(of: placeholder, with: String(nextHandle, radix: 16, uppercase: true))
    }

    func writeSpline(_ contour: DXFContour, layer: String, owner: String) {
        let spline = contour.spline
        pair(0, "SPLINE")
        pair(5, handle())
        pair(330, owner)
        pair(100, "AcDbEntity")
        pair(8, layer)
        pair(100, "AcDbSpline")
        pair(210, 0.0)
        pair(220, 0.0)
        pair(230, 1.0)
        // 8: planar.  The closed flag is not set: the clamped knots already end where the
        // contour starts, and readers treat "closed" as periodic.
        pair(70, 8)
        pair(71, 3)
        pair(72, spline.knots.count)
        pair(73, spline.controls.count)
        pair(74, 0)
        pair(42, "0.0000000001")
        pair(43, "0.0000000001")
        for knot in spline.knots {
            pair(40, knot)
        }
        for control in spline.controls {
            pair(10, control.x)
            pair(20, control.y)
            pair(30, 0.0)
        }
    }
}
