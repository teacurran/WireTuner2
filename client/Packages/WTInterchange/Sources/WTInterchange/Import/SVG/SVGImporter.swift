// The SVG importer (import-formats.adoc, "SVG" and "Client"; IMG-012; animated files per
// svg-animation.adoc, WEB-025): shapes, paths, groups, `use`/`symbol`, gradients, clipping,
// opacity, dashes, embedded or referenced images, text as text or outlines, and the CSS cascade
// for presentation properties, converted into an `ImportedScene` at 96 px/in.  Filters, masks,
// patterns, markers, `foreignObject`, animation and scripts are not imported; the parts they
// affect import without them and the scene's notes say so.  A file with animation is placed as
// an animation unless the options say to convert it.

import CoreGraphics
import CoreText
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

public struct SVGImporter: Importer {
    /// Placed animations may be at most this large (svg-animation.adoc: 50 MiB).
    public static let maximumAnimationSize = 50 * 1_048_576
    /// Points per SVG user unit (CSS pixel): 96 px/in.
    public static let pointsPerPixel = 0.75

    /// Where relative image references resolve; nil skips referenced (non-`data:`) images.
    public var baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    public var formats: [ImportFormat] { [.svg] }

    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema {
        SVGImportOptions.schema
    }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let root = try SVGImportTree.parse(data, name: name)
        let viewport = SVGImportViewport(root)
        let animated = SVGImportAnimation.scan(root).isAnimated
        return ImportDescriptor(format: .svg, naturalSize: viewport.bounds, placed: animated)
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let options = SVGImportOptions(options)
        let root = try SVGImportTree.parse(data, name: name)
        let viewport = SVGImportViewport(root)
        let animation = SVGImportAnimation.scan(root)
        let place = options.animation == .place || (options.animation == .automatic && animation.isAnimated)
        if place {
            if data.count > SVGImporter.maximumAnimationSize {
                throw ImportError.tooLarge(name: name, bytes: data.count, limit: SVGImporter.maximumAnimationSize)
            }
            let placed = ImportedPlacedFile(kind: animation.placedKind, blob: ImportedBlob(data: data, uti: "public.svg-image"), bounds: viewport.bounds, name: name)
            return ImportedScene(kind: .placed, name: name, bounds: viewport.bounds, nodes: [.placed(placed)], notes: ["“\(name)” is placed as an SVG animation; its poster frame is drawn when it is placed."])
        }
        let converter = SVGImportConverter(root: root, options: options, name: name, baseURL: baseURL, context: context)
        var nodes = converter.convertRoot(viewport)
        if options.flattenGroups {
            nodes = SVGImportFlattener.flatten(nodes)
        }
        var notes = converter.notes
        if animation.isAnimated {
            notes.append("“\(name)” contains animation; it was converted to objects without it.")
        }
        return ImportedScene(kind: .vector, name: name, bounds: viewport.bounds, nodes: nodes, notes: notes)
    }

    /// The animation analysis of an SVG file (for the animation importer, WEB-025).
    public static func animationInfo(_ data: Data, name: String = "SVG") throws -> SVGAnimationInfo {
        SVGImportAnimation.scan(try SVGImportTree.parse(data, name: name))
    }
}

// MARK: - Viewport

/// The root viewport: its size in user units and the transform from the root's user space
/// (after `viewBox`) to points.
struct SVGImportViewport {
    var width: Double
    var height: Double
    /// Root user space → scene points.
    var transform: AffineTransform
    /// The size percentages of the root's children refer to: the view box's, else the
    /// viewport's.
    var userSize: (width: Double, height: Double)

    init(_ root: SVGImportElement) {
        let box = SVGImportViewport.viewBox(root.attributes["viewBox"])
        let width = SVGImportValues.length(root.attributes["width"], percentOf: box?.width ?? 300) ?? box?.width ?? 300
        let height = SVGImportValues.length(root.attributes["height"], percentOf: box?.height ?? 150) ?? box?.height ?? 150
        self.width = max(width, 0)
        self.height = max(height, 0)
        // Mapping the view box straight into the viewport in points keeps a points-sized file
        // (`width="200pt" viewBox="0 0 200 200"`) exact.
        let points = Rect(x: 0, y: 0, width: self.width * SVGImporter.pointsPerPixel, height: self.height * SVGImporter.pointsPerPixel)
        transform = box.map { SVGImportViewport.map($0, into: points, preserve: root.attributes["preserveAspectRatio"]) } ?? .scale(SVGImporter.pointsPerPixel)
        userSize = (box?.width ?? self.width, box?.height ?? self.height)
    }

    /// The natural size in points.
    var bounds: Rect {
        Rect(x: 0, y: 0, width: width * SVGImporter.pointsPerPixel, height: height * SVGImporter.pointsPerPixel)
    }

    static func viewBox(_ text: String?) -> Rect? {
        let values = SVGImportValues.numbers(text ?? "")
        guard values.count == 4, values[2] > 0, values[3] > 0 else {
            return nil
        }
        return Rect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// The transform placing `box` into `viewport` by `preserveAspectRatio` (default
    /// `xMidYMid meet`).
    static func map(_ box: Rect, into viewport: Rect, preserve: String?) -> AffineTransform {
        let words = (preserve ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "defer" }
        let align = words.first ?? "xMidYMid"
        var sx = viewport.width / box.width
        var sy = viewport.height / box.height
        if align != "none" {
            let scale = words.count > 1 && words[1] == "slice" ? max(sx, sy) : min(sx, sy)
            sx = scale
            sy = scale
        }
        func offset(_ axis: String, _ free: Double) -> Double {
            if align.contains("\(axis)Min") { return 0 }
            if align.contains("\(axis)Max") { return free }
            return align == "none" ? 0 : free / 2
        }
        let tx = viewport.minX + offset("x", viewport.width - box.width * sx) - box.minX * sx
        let ty = viewport.minY + offset("Y", viewport.height - box.height * sy) - box.minY * sy
        return AffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }
}

// MARK: - Style

/// A paint as declared: none, a colour, or a paint server reference with its fallback.
enum SVGImportPaintSpec: Equatable {
    case none
    case color(Color)
    case currentColor
    case server(id: String, fallback: Color?)
}

/// The inherited computed style.
struct SVGImportStyle {
    var fill: SVGImportPaintSpec = .color(.black)
    var fillOpacity = 1.0
    var fillRule: FillRule = .nonZero
    var clipRule: FillRule = .nonZero
    var stroke: SVGImportPaintSpec = .none
    var strokeOpacity = 1.0
    var strokeWidth = 1.0
    var cap: LineCap = .butt
    var join: LineJoin = .miter
    var miterLimit = 4.0
    var dash: [Double] = []
    var dashOffset = 0.0
    var fontFamily = "serif"
    var fontSize = 16.0
    var fontWeight = 400
    var italic = false
    var textAnchor = "start"
    var visible = true
    var color: Color = .black
    var preserveSpace = false
    var stopColor: Color = .black
    var stopOpacity = 1.0
}

/// The properties an element declares, cascaded: presentation attributes, then style-sheet
/// rules, then the `style` attribute, then `!important` rules and declarations.
struct SVGImportProperties {
    var values: [String: String] = [:]

    static let presentation: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "clip-rule", "stroke", "stroke-opacity", "stroke-width", "stroke-linecap",
        "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "font-family", "font-size",
        "font-weight", "font-style", "text-anchor", "visibility", "display", "opacity", "color", "clip-path", "mask",
        "filter", "marker-start", "marker-mid", "marker-end", "stop-color", "stop-opacity", "transform",
    ]

    init(_ element: SVGImportElement, sheet: SVGImportStyleSheet) {
        for (key, value) in element.attributes where SVGImportProperties.presentation.contains(key) {
            values[key] = value
        }
        let rules = sheet.matching(element)
        let inline = SVGImportStyleSheet.declarations(element.attributes["style"] ?? "")
        for declaration in rules.normal + inline.filter({ !$0.important }) + rules.important + inline.filter(\.important) {
            values[declaration.property] = declaration.value
        }
        values = values.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed == "inherit" ? nil : trimmed
        }
    }

    subscript(key: String) -> String? {
        values[key]
    }
}

// MARK: - Converter

final class SVGImportConverter {
    let root: SVGImportElement
    let options: SVGImportOptions
    let name: String
    let baseURL: URL?
    let context: ImportContext
    let sheet: SVGImportStyleSheet
    var ids: [String: SVGImportElement] = [:]
    /// Notes in first-seen order.
    private(set) var notes: [String] = []
    /// The innermost viewport (every conversion runs inside the root's).
    var viewport: (width: Double, height: Double) { viewports[viewports.count - 1] }
    /// The normalized diagonal percentages of non-directional lengths refer to.
    var diagonal: Double { ((viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot() }
    /// `use` targets being expanded (the recursion guard).
    var expanding: Set<String> = []
    /// The viewport sizes for percentages, innermost last.
    var viewports: [(width: Double, height: Double)] = []

    init(root: SVGImportElement, options: SVGImportOptions, name: String, baseURL: URL?, context: ImportContext) {
        self.root = root
        self.options = options
        self.name = name
        self.baseURL = baseURL
        self.context = context
        let all = root.descendants
        sheet = SVGImportStyleSheet(all.filter { $0.name == "style" }.map(\.text).joined(separator: "\n"))
        for element in all {
            if let id = element.attributes["id"], ids[id] == nil {
                ids[id] = element
            }
        }
    }

    func note(_ text: String) {
        if !notes.contains(text) {
            notes.append(text)
        }
    }

    func convertRoot(_ viewport: SVGImportViewport) -> [ImportedNode] {
        viewports = [viewport.userSize]
        let properties = SVGImportProperties(root, sheet: sheet)
        let style = computed(properties, parent: SVGImportStyle(), element: root)
        guard properties["display"] != "none" else {
            return []
        }
        let nodes = convertChildren(root, style: style, link: nil)
        return wrap(nodes, element: root, properties: properties, ownTransform: viewport.transform)
    }

    // MARK: Style computation

    func computed(_ p: SVGImportProperties, parent: SVGImportStyle, element: SVGImportElement) -> SVGImportStyle {
        var s = parent
        if let value = p["color"], let color = SVGImportValues.color(value, current: parent.color) {
            s.color = color
        }
        if let value = p["fill"] { s.fill = paintSpec(value) }
        if let value = p["stroke"] { s.stroke = paintSpec(value) }
        if let value = p["fill-opacity"] { s.fillOpacity = opacity(value, parent.fillOpacity) }
        if let value = p["stroke-opacity"] { s.strokeOpacity = opacity(value, parent.strokeOpacity) }
        if let value = p["fill-rule"] { s.fillRule = value == "evenodd" ? .evenOdd : .nonZero }
        if let value = p["clip-rule"] { s.clipRule = value == "evenodd" ? .evenOdd : .nonZero }
        if let value = p["font-size"], let size = fontSize(value, parent: parent.fontSize) { s.fontSize = size }
        if let value = p["stroke-width"], let width = SVGImportValues.length(value, percentOf: diagonal, fontSize: s.fontSize), width >= 0 { s.strokeWidth = width }
        if let value = p["stroke-linecap"] { s.cap = value == "round" ? .round : value == "square" ? .square : .butt }
        if let value = p["stroke-linejoin"] { s.join = value == "round" ? .round : value == "bevel" ? .bevel : .miter }
        if let value = p["stroke-miterlimit"], let limit = Double(value), limit >= 1 { s.miterLimit = limit }
        if let value = p["stroke-dasharray"] { s.dash = dashes(value, diagonal: diagonal, fontSize: s.fontSize) }
        if let value = p["stroke-dashoffset"], let offset = SVGImportValues.length(value, percentOf: diagonal, fontSize: s.fontSize) { s.dashOffset = offset }
        if let value = p["font-family"] { s.fontFamily = value }
        if let value = p["font-weight"] { s.fontWeight = weight(value, parent: parent.fontWeight) }
        if let value = p["font-style"] { s.italic = value == "italic" || value == "oblique" }
        if let value = p["text-anchor"] { s.textAnchor = value }
        if let value = p["visibility"] { s.visible = value == "visible" }
        if let value = element.attributes["xml:space"] { s.preserveSpace = value == "preserve" }
        // Stop properties are not inherited.
        s.stopColor = p["stop-color"].flatMap { SVGImportValues.color($0, current: s.color) } ?? .black
        s.stopOpacity = p["stop-opacity"].map { opacity($0, 1) } ?? 1
        return s
    }

    func paintSpec(_ value: String) -> SVGImportPaintSpec {
        if value == "none" {
            return .none
        }
        if value.lowercased() == "currentcolor" {
            return .currentColor
        }
        if value.hasPrefix("url(") {
            guard let close = value.firstIndex(of: ")") else {
                return .none
            }
            let reference = value[value.index(value.startIndex, offsetBy: 4)..<close].trimmingCharacters(in: CharacterSet(charactersIn: " '\"#"))
            let fallback = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return .server(id: reference, fallback: fallback.isEmpty ? nil : SVGImportValues.color(fallback))
        }
        return SVGImportValues.color(value).map(SVGImportPaintSpec.color) ?? .none
    }

    func opacity(_ value: String, _ fallback: Double) -> Double {
        let number = value.hasSuffix("%") ? Double(value.dropLast()).map { $0 / 100 } : Double(value)
        return min(max(number ?? fallback, 0), 1)
    }

    func fontSize(_ value: String, parent: Double) -> Double? {
        let keywords: [String: Double] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32, "larger": parent * 1.2, "smaller": parent / 1.2]
        if let keyword = keywords[value] {
            return keyword
        }
        return SVGImportValues.length(value, percentOf: parent, fontSize: parent)
    }

    func weight(_ value: String, parent: Int) -> Int {
        switch value {
        case "normal": return 400
        case "bold": return 700
        case "bolder": return min(parent + 300, 900)
        case "lighter": return max(parent - 300, 100)
        default: return Int(value) ?? parent
        }
    }

    func dashes(_ value: String, diagonal: Double, fontSize: Double) -> [Double] {
        guard value != "none" else {
            return []
        }
        let lengths = SVGImportValues.lengths(value, percentOf: diagonal, fontSize: fontSize)
        guard !lengths.isEmpty, lengths.allSatisfy({ $0 >= 0 }), lengths.reduce(0, +) > 0 else {
            return []
        }
        return lengths.count % 2 == 1 ? lengths + lengths : lengths
    }

    // MARK: Elements

    func convertChildren(_ element: SVGImportElement, style: SVGImportStyle, link: String?) -> [ImportedNode] {
        element.children.flatMap { convert($0, parentStyle: style, link: link) }
    }

    static let skipped: Set<String> = ["defs", "symbol", "clipPath", "linearGradient", "radialGradient", "style", "title", "desc", "metadata", "script", "stop"]
    static let unsupported: [String: String] = [
        "pattern": "patterns", "mask": "masks", "filter": "filters", "marker": "markers", "foreignObject": "foreign objects",
    ]

    func convert(_ element: SVGImportElement, parentStyle: SVGImportStyle, link: String?) -> [ImportedNode] {
        if SVGImportConverter.skipped.contains(element.name) || SVGImportAnimation.smilElements.contains(element.name) {
            return []
        }
        if let kind = SVGImportConverter.unsupported[element.name] {
            if element.name == "foreignObject" {
                note("SVG \(kind) are not imported.")
            }
            return []
        }
        let properties = SVGImportProperties(element, sheet: sheet)
        guard properties["display"] != "none" else {
            return []
        }
        let style = computed(properties, parent: parentStyle, element: element)
        for (property, kind) in [("mask", "masks"), ("filter", "filters"), ("marker-start", "markers"), ("marker-mid", "markers"), ("marker-end", "markers")] {
            if let value = properties[property], value != "none" {
                note("SVG \(kind) are not imported; the objects they apply to are imported without them.")
            }
        }
        var nodes: [ImportedNode]
        var link = link
        switch element.name {
        case "g", "switch":
            nodes = convertChildren(element, style: style, link: link)
            if element.name == "switch" {
                nodes = Array(nodes.prefix(1))
            }
            guard !nodes.isEmpty else {
                return []
            }
            return wrap([.group(ImportedGroup(children: nodes, name: nodeName(element)))], element: element, properties: properties, ownTransform: nil)
        case "a":
            link = element.href ?? link
            nodes = convertChildren(element, style: style, link: link)
            guard !nodes.isEmpty else {
                return []
            }
            return wrap([.group(ImportedGroup(children: nodes, name: nodeName(element)))], element: element, properties: properties, ownTransform: nil)
        case "svg":
            return nestedSVG(element, style: style, properties: properties, link: link)
        case "use":
            return use(element, style: style, properties: properties, link: link)
        case "text":
            nodes = text(element, style: style)
        case "image":
            nodes = image(element, properties: properties)
        default:
            guard let contours = shape(element, fontSize: style.fontSize), !contours.isEmpty else {
                return []
            }
            guard style.visible else {
                return []
            }
            nodes = [.path(path(contours, style: style, name: nodeName(element), url: link))]
        }
        return wrap(nodes, element: element, properties: properties, ownTransform: nil)
    }

    /// `nodes` (the element's content in its own user space) under the element's transform,
    /// opacity and clip path.  A single group or path takes them itself; otherwise a group is
    /// made.  `ownTransform` overrides the `transform` attribute (the root's viewport mapping).
    func wrap(_ nodes: [ImportedNode], element: SVGImportElement, properties: SVGImportProperties, ownTransform: AffineTransform?) -> [ImportedNode] {
        guard !nodes.isEmpty else {
            return []
        }
        let transform = ownTransform ?? SVGImportValues.transform(properties["transform"])
        let opacity = properties["opacity"].map { self.opacity($0, 1) } ?? 1
        var clip: ImportedPath?
        if let value = properties["clip-path"], value != "none", let id = SVGImportConverter.reference(value) {
            clip = clipPath(id, content: nodes)
        }
        if clip == nil, nodes.count == 1 {
            switch nodes[0] {
            case .group(var group) where group.clip == nil:
                group.transform = group.transform.concatenating(transform)
                group.opacity *= opacity
                return [.group(group)]
            case .path(var path):
                path.transform = path.transform.concatenating(transform)
                path.opacity *= opacity
                return [.path(path)]
            default:
                break
            }
        }
        if clip == nil, opacity >= 1 {
            return nodes.map { SVGImportConverter.transformed($0, by: transform) }
        }
        return [.group(ImportedGroup(children: nodes, clip: clip, opacity: opacity, transform: transform, name: clip == nil ? nil : nodeName(element)))]
    }

    static func transformed(_ node: ImportedNode, by transform: AffineTransform) -> ImportedNode {
        guard !transform.isIdentity else {
            return node
        }
        switch node {
        case .group(var group):
            group.transform = group.transform.concatenating(transform)
            return .group(group)
        case .path(var path):
            path.transform = path.transform.concatenating(transform)
            return .path(path)
        case .text(var text):
            text.transform = text.transform.concatenating(transform)
            return .text(text)
        case .image(var image):
            image.transform = image.transform.concatenating(transform)
            return .image(image)
        case .placed(var placed):
            placed.transform = placed.transform.concatenating(transform)
            return .placed(placed)
        }
    }

    static func reference(_ value: String) -> String? {
        guard value.hasPrefix("url("), let close = value.firstIndex(of: ")") else {
            return nil
        }
        return value[value.index(value.startIndex, offsetBy: 4)..<close].trimmingCharacters(in: CharacterSet(charactersIn: " '\"#"))
    }

    /// The node name: an Inkscape label, the id, or a `<title>` child.
    func nodeName(_ element: SVGImportElement) -> String? {
        if let label = element.attributes["inkscape:label"] {
            return label
        }
        if let id = element.attributes["id"] {
            return id
        }
        return element.children.first { $0.name == "title" }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: Shapes

    func length(_ element: SVGImportElement, _ attribute: String, axis: Int, fontSize: Double) -> Double? {
        let reference: Double
        switch axis {
        case 0: reference = viewport.width
        case 1: reference = viewport.height
        default: reference = diagonal
        }
        return SVGImportValues.length(element.attributes[attribute], percentOf: reference, fontSize: fontSize)
    }

    /// The outline of a basic shape or path in its own user space; nil for other elements.
    func shape(_ element: SVGImportElement, fontSize: Double) -> [ImportedContour]? {
        func value(_ attribute: String, _ axis: Int) -> Double {
            length(element, attribute, axis: axis, fontSize: fontSize) ?? 0
        }
        var builder = ImportPathBuilder()
        switch element.name {
        case "path":
            return SVGImportValues.pathData(element.attributes["d"] ?? "")
        case "rect":
            let x = value("x", 0), y = value("y", 1), w = value("width", 0), h = value("height", 1)
            guard w > 0, h > 0 else {
                return []
            }
            var rx = length(element, "rx", axis: 0, fontSize: fontSize)
            var ry = length(element, "ry", axis: 1, fontSize: fontSize)
            if rx == nil || (rx ?? 0) < 0 { rx = ry }
            if ry == nil || (ry ?? 0) < 0 { ry = rx }
            let cx = min(max(rx ?? 0, 0), w / 2)
            let cy = min(max(ry ?? 0, 0), h / 2)
            guard cx > 0, cy > 0 else {
                builder.rect(Rect(x: x, y: y, width: w, height: h))
                return builder.build()
            }
            builder.move(to: Point(x: x + cx, y: y))
            builder.line(to: Point(x: x + w - cx, y: y))
            builder.arc(center: Point(x: x + w - cx, y: y + cy), rx: cx, ry: cy, start: -.pi / 2, sweep: .pi / 2)
            builder.line(to: Point(x: x + w, y: y + h - cy))
            builder.arc(center: Point(x: x + w - cx, y: y + h - cy), rx: cx, ry: cy, start: 0, sweep: .pi / 2)
            builder.line(to: Point(x: x + cx, y: y + h))
            builder.arc(center: Point(x: x + cx, y: y + h - cy), rx: cx, ry: cy, start: .pi / 2, sweep: .pi / 2)
            builder.line(to: Point(x: x, y: y + cy))
            builder.arc(center: Point(x: x + cx, y: y + cy), rx: cx, ry: cy, start: .pi, sweep: .pi / 2)
            builder.close()
            return builder.build()
        case "circle", "ellipse":
            let r = element.name == "circle" ? value("r", 2) : 0
            let rx = element.name == "circle" ? r : value("rx", 0)
            let ry = element.name == "circle" ? r : value("ry", 1)
            guard rx > 0, ry > 0 else {
                return []
            }
            builder.ellipse(center: Point(x: value("cx", 0), y: value("cy", 1)), rx: rx, ry: ry)
            return builder.build()
        case "line":
            builder.move(to: Point(x: value("x1", 0), y: value("y1", 1)))
            builder.line(to: Point(x: value("x2", 0), y: value("y2", 1)))
            return builder.build()
        case "polyline", "polygon":
            let numbers = SVGImportValues.numbers(element.attributes["points"] ?? "")
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map { Point(x: numbers[$0], y: numbers[$0 + 1]) }
            guard let first = points.first else {
                return []
            }
            builder.move(to: first)
            points.dropFirst().forEach { builder.line(to: $0) }
            if element.name == "polygon" {
                builder.close()
            }
            return builder.build()
        default:
            return nil
        }
    }

    /// A path node with the style's fill and stroke; paint servers resolved against the
    /// contours' bounds.
    func path(_ contours: [ImportedContour], style: SVGImportStyle, name: String?, url: String?) -> ImportedPath {
        // Only bounding-box gradients need the bounds; most paths have none.
        var cached: Rect?
        let bounds = { () -> Rect in
            if let cached { return cached }
            let rect = SVGImportConverter.bounds(of: contours)
            cached = rect
            return rect
        }
        let fill = paint(style.fill, opacity: style.fillOpacity, style: style, bounds: bounds)
        var stroke: ImportedStroke?
        let strokePaint = paint(style.stroke, opacity: style.strokeOpacity, style: style, bounds: bounds)
        if !strokePaint.isNone && style.strokeWidth > 0 {
            stroke = ImportedStroke(paint: strokePaint, style: StrokeStyle(width: style.strokeWidth, cap: style.cap, join: style.join, miterLimit: style.miterLimit, dash: style.dash, dashPhase: style.dashOffset))
        }
        return ImportedPath(contours: contours, fill: fill, fillRule: style.fillRule, stroke: stroke, name: name, url: url)
    }

    /// The exact bounds of contours (curve extrema included).
    static func bounds(of contours: [ImportedContour]) -> Rect {
        var rect = Rect.null
        for contour in contours {
            rect.formUnion(contour.start)
            var current = contour.start
            for segment in contour.segments {
                switch segment {
                case .line(let end):
                    rect.formUnion(end)
                case .cubic(let c1, let c2, let end):
                    rect.formUnion(CubicBezier(current, c1, c2, end).bounds)
                }
                current = segment.end
            }
        }
        return rect
    }

    func paint(_ spec: SVGImportPaintSpec, opacity: Double, style: SVGImportStyle, bounds: () -> Rect) -> ImportedPaint {
        switch spec {
        case .none:
            return .none
        case .color(let color):
            return .solid(color.withAlpha(multipliedBy: opacity))
        case .currentColor:
            return .solid(style.color.withAlpha(multipliedBy: opacity))
        case .server(let id, let fallback):
            if let element = ids[id], element.name == "linearGradient" || element.name == "radialGradient",
               let gradient = gradient(element, bounds: bounds(), opacity: opacity, style: style) {
                return gradient
            }
            if let element = ids[id], element.name == "pattern" {
                note("SVG patterns are not imported; the objects they apply to are imported without them.")
            }
            return fallback.map { .solid($0.withAlpha(multipliedBy: opacity)) } ?? .none
        }
    }

    // MARK: Gradients

    /// The attribute of a gradient or of the gradients it references.
    func gradientChain(_ element: SVGImportElement) -> [SVGImportElement] {
        var chain = [element]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(element)]
        while let href = chain.last?.href, href.hasPrefix("#"), let next = ids[String(href.dropFirst())],
              next.name.hasSuffix("Gradient"), seen.insert(ObjectIdentifier(next)).inserted {
            chain.append(next)
        }
        return chain
    }

    func gradient(_ element: SVGImportElement, bounds: Rect, opacity: Double, style: SVGImportStyle) -> ImportedPaint? {
        let chain = gradientChain(element)
        func attribute(_ key: String) -> String? {
            chain.lazy.compactMap { $0.attributes[key] }.first
        }
        let stopsElement = chain.first { $0.children.contains { $0.name == "stop" } }
        var stops: [Gradient.Stop] = []
        var previous = 0.0
        for stop in stopsElement?.children.filter({ $0.name == "stop" }) ?? [] {
            let raw = stop.attributes["offset"] ?? "0"
            var offset = raw.hasSuffix("%") ? (Double(raw.dropLast()) ?? 0) / 100 : (Double(raw) ?? 0)
            offset = max(min(max(offset, 0), 1), previous)
            previous = offset
            let stopStyle = computed(SVGImportProperties(stop, sheet: sheet), parent: style, element: stop)
            stops.append(Gradient.Stop(offset: offset, color: stopStyle.stopColor.withAlpha(multipliedBy: stopStyle.stopOpacity * opacity)))
        }
        guard !stops.isEmpty else {
            return nil
        }
        if stops.count == 1 {
            return .solid(stops[0].color)
        }
        let boxUnits = attribute("gradientUnits") != "userSpaceOnUse"
        if boxUnits && (bounds.isNull || bounds.width <= 0 || bounds.height <= 0) {
            return nil
        }
        func coordinate(_ key: String, _ fallback: String, axis: Int) -> Double {
            let text = attribute(key) ?? fallback
            if boxUnits {
                return text.hasSuffix("%") ? (Double(text.dropLast()) ?? 0) / 100 : (SVGImportValues.length(text) ?? 0)
            }
            let reference = axis == 0 ? viewport.width : axis == 1 ? viewport.height : diagonal
            return SVGImportValues.length(text, percentOf: reference, fontSize: style.fontSize) ?? 0
        }
        var map = SVGImportValues.transform(attribute("gradientTransform"))
        if boxUnits {
            map = map.concatenating(AffineTransform(a: bounds.width, b: 0, c: 0, d: bounds.height, tx: bounds.minX, ty: bounds.minY))
        }
        let behavior: Gradient.Behavior
        switch attribute("spreadMethod") {
        case "reflect": behavior = .reflect
        case "repeat": behavior = .repeat
        default: behavior = .normal
        }
        if element.name == "radialGradient" {
            let cx = coordinate("cx", "50%", axis: 0), cy = coordinate("cy", "50%", axis: 1), r = coordinate("r", "50%", axis: 2)
            if let fx = attribute("fx"), let fy = attribute("fy"), abs(coordinate("fx", fx, axis: 0) - cx) > 1e-9 || abs(coordinate("fy", fy, axis: 1) - cy) > 1e-9 {
                note("Radial gradient focal points are not imported; those gradients are centred.")
            }
            let center = Point(x: cx, y: cy)
            let axis = Gradient.Axis(start: map.apply(center), end: map.apply(Point(x: cx + r, y: cy)), end2: map.apply(Point(x: cx, y: cy + r)))
            return .gradient(Gradient(kind: .radial, behavior: behavior, axis: axis, stops: stops))
        }
        let p1 = Point(x: coordinate("x1", "0%", axis: 0), y: coordinate("y1", "0%", axis: 1))
        let p2 = Point(x: coordinate("x2", "100%", axis: 0), y: coordinate("y2", "0%", axis: 1))
        // An affine map keeps isolines parallel but not perpendicular to the axis: the axis in
        // user space is the mapped axis projected onto the normal of the mapped isolines.
        let d = p2 - p1
        let start = map.apply(p1)
        var vector = map.apply(d)
        let isoline = map.apply(d.perpendicular)
        if isoline.length > 1e-12 {
            let unit = isoline.normalized
            vector = vector - unit * vector.dot(unit)
        }
        return .gradient(Gradient(kind: .linear, behavior: behavior, axis: Gradient.Axis(start: start, end: start + vector), stops: stops))
    }

    // MARK: Clip paths

    /// The clip of `id` for content in the referencing element's user space.
    func clipPath(_ id: String, content: [ImportedNode]) -> ImportedPath? {
        guard let element = ids[id], element.name == "clipPath" else {
            return nil
        }
        let properties = SVGImportProperties(element, sheet: sheet)
        var neutral = computed(properties, parent: SVGImportStyle(), element: element)
        neutral.visible = true
        var contours: [ImportedContour] = []
        var rule: FillRule = .nonZero
        let children = element.children.filter { !SVGImportConverter.skipped.contains($0.name) }
        for child in children {
            let childProperties = SVGImportProperties(child, sheet: sheet)
            let childStyle = computed(childProperties, parent: neutral, element: child)
            let target = child.name == "use" ? child.href.flatMap { ids[String($0.dropFirst())] } : child
            guard let target, let shape = shape(target, fontSize: childStyle.fontSize) else {
                continue
            }
            var transform = SVGImportValues.transform(childProperties["transform"])
            if child.name == "use" {
                let offset = AffineTransform.translation(x: length(child, "x", axis: 0, fontSize: 16) ?? 0, y: length(child, "y", axis: 1, fontSize: 16) ?? 0)
                transform = SVGImportValues.transform(SVGImportProperties(target, sheet: sheet)["transform"]).concatenating(offset).concatenating(transform)
            }
            let placed = shape.map { $0.applying(transform) }
            contours += children.count > 1 ? placed.map(SVGImportConverter.positivelyWound) : placed
            rule = children.count > 1 ? .nonZero : computed(SVGImportProperties(target, sheet: sheet), parent: childStyle, element: target).clipRule
        }
        guard !contours.isEmpty else {
            return nil
        }
        var transform = SVGImportValues.transform(properties["transform"])
        if element.attributes["clipPathUnits"] == "objectBoundingBox" {
            // Content always has extent: empty elements import as nothing and are never wrapped.
            let box = SVGImportConverter.bounds(of: content)
            transform = transform.concatenating(AffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY))
        }
        return ImportedPath(contours: contours.map { $0.applying(transform) }, fillRule: rule, name: nodeName(element))
    }

    /// The union of several clip shapes is their nonzero fill once every contour winds the
    /// same way.
    static func positivelyWound(_ contour: ImportedContour) -> ImportedContour {
        let points = contour.allPoints
        var area = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area >= 0 ? contour : reversed(contour)
    }

    static func reversed(_ contour: ImportedContour) -> ImportedContour {
        var segments: [ImportedContour.Segment] = []
        var current = contour.start
        for segment in contour.segments {
            switch segment {
            case .line:
                segments.append(.line(to: current))
            case .cubic(let c1, let c2, _):
                segments.append(.cubic(control1: c2, control2: c1, to: current))
            }
            current = segment.end
        }
        return ImportedContour(start: current, segments: segments.reversed(), closed: contour.closed)
    }

    /// The bounds of nodes in their parent's space (control hulls, transforms applied).
    static func bounds(of nodes: [ImportedNode]) -> Rect {
        var rect = Rect.null
        for node in nodes {
            switch node {
            case .path(let path):
                rect.formUnion(bounds(of: path.contours.map { $0.applying(path.transform) }))
            case .group(let group):
                let inner = bounds(of: group.children)
                if !inner.isNull {
                    rect.formUnion(inner.applying(group.transform))
                }
            case .image(let image):
                rect.formUnion(image.naturalRect.applying(image.transform))
            case .text(let text):
                for run in text.runs {
                    rect.formUnion(Rect(x: run.origin.x, y: run.origin.y - run.fontSize, width: run.fontSize * Double(run.text.count) * 0.5, height: run.fontSize).applying(text.transform))
                }
            case .placed(let placed):
                rect.formUnion(placed.bounds.applying(placed.transform))
            }
        }
        return rect
    }

    // MARK: use, symbol, nested svg

    func use(_ element: SVGImportElement, style: SVGImportStyle, properties: SVGImportProperties, link: String?) -> [ImportedNode] {
        guard let href = element.href, href.hasPrefix("#"), let target = ids[String(href.dropFirst())] else {
            return []
        }
        let id = String(href.dropFirst())
        guard !expanding.contains(id) else {
            note("A circular `use` reference was not expanded.")
            return []
        }
        expanding.insert(id)
        defer { expanding.remove(id) }
        let offset = AffineTransform.translation(x: length(element, "x", axis: 0, fontSize: style.fontSize) ?? 0, y: length(element, "y", axis: 1, fontSize: style.fontSize) ?? 0)
        var nodes: [ImportedNode]
        if target.name == "symbol" {
            let targetProperties = SVGImportProperties(target, sheet: sheet)
            let symbolStyle = computed(targetProperties, parent: style, element: target)
            var size = viewport
            size.width = length(element, "width", axis: 0, fontSize: style.fontSize) ?? size.width
            size.height = length(element, "height", axis: 1, fontSize: style.fontSize) ?? size.height
            var map = AffineTransform.identity
            if let box = SVGImportViewport.viewBox(target.attributes["viewBox"]) {
                map = SVGImportViewport.map(box, into: Rect(x: 0, y: 0, width: size.width, height: size.height), preserve: target.attributes["preserveAspectRatio"])
            }
            viewports.append(size)
            nodes = convertChildren(target, style: symbolStyle, link: link).map { SVGImportConverter.transformed($0, by: map) }
            viewports.removeLast()
        } else {
            nodes = convert(target, parentStyle: style, link: link)
        }
        nodes = nodes.map { SVGImportConverter.transformed($0, by: offset) }
        let group = ImportedNode.group(ImportedGroup(children: nodes, name: nodeName(element) ?? nodeName(target)))
        return wrap(nodes.isEmpty ? [] : [group], element: element, properties: properties, ownTransform: nil)
    }

    func nestedSVG(_ element: SVGImportElement, style: SVGImportStyle, properties: SVGImportProperties, link: String?) -> [ImportedNode] {
        let outer = viewport
        let x = length(element, "x", axis: 0, fontSize: style.fontSize) ?? 0
        let y = length(element, "y", axis: 1, fontSize: style.fontSize) ?? 0
        let width = length(element, "width", axis: 0, fontSize: style.fontSize) ?? outer.width
        let height = length(element, "height", axis: 1, fontSize: style.fontSize) ?? outer.height
        guard width > 0, height > 0 else {
            return []
        }
        let frame = Rect(x: x, y: y, width: width, height: height)
        let map = SVGImportViewport.viewBox(element.attributes["viewBox"]).map { SVGImportViewport.map($0, into: frame, preserve: element.attributes["preserveAspectRatio"]) } ?? .translation(x: x, y: y)
        viewports.append((width, height))
        let children = convertChildren(element, style: style, link: link).map { SVGImportConverter.transformed($0, by: map) }
        viewports.removeLast()
        guard !children.isEmpty else {
            return []
        }
        var builder = ImportPathBuilder()
        builder.rect(frame)
        let clip = element.attributes["overflow"] == "visible" ? nil : ImportedPath(contours: builder.build())
        return wrap([.group(ImportedGroup(children: children, clip: clip, name: nodeName(element)))], element: element, properties: properties, ownTransform: nil)
    }

    // MARK: Images

    func image(_ element: SVGImportElement, properties: SVGImportProperties) -> [ImportedNode] {
        guard let href = element.href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else {
            return []
        }
        var data: Data?
        var fileName = nodeName(element) ?? "image"
        if href.hasPrefix("data:") {
            data = SVGImportConverter.dataURL(href)
        } else if let baseURL, let url = URL(string: href, relativeTo: baseURL), url.isFileURL {
            data = try? Data(contentsOf: url)
            fileName = url.lastPathComponent
        } else {
            note("Images linked from outside the SVG file were not imported.")
            return []
        }
        guard let data, let decoded = try? ImageImporter().decode(data, name: fileName, context: context) else {
            note("An image in the SVG file could not be read and was not imported.")
            return []
        }
        var image = decoded.image(name: nodeName(element))
        let natural = image.naturalRect
        let x = length(element, "x", axis: 0, fontSize: 16) ?? 0
        let y = length(element, "y", axis: 1, fontSize: 16) ?? 0
        // Without a size the image takes its pixel size in user units.
        let width = length(element, "width", axis: 0, fontSize: 16) ?? Double(decoded.pixels.width)
        let height = length(element, "height", axis: 1, fontSize: 16) ?? Double(decoded.pixels.height)
        guard width > 0, height > 0 else {
            return []
        }
        let box = Rect(x: x, y: y, width: width, height: height)
        image.transform = SVGImportViewport.map(natural, into: box, preserve: element.attributes["preserveAspectRatio"])
        let slice = (element.attributes["preserveAspectRatio"] ?? "").contains("slice")
        guard slice else {
            return [.image(image)]
        }
        var builder = ImportPathBuilder()
        builder.rect(box)
        return [.group(ImportedGroup(children: [.image(image)], clip: ImportedPath(contours: builder.build())))]
    }

    /// The bytes of a `data:` URL (base64 or percent-encoded).
    static func dataURL(_ href: String) -> Data? {
        guard let comma = href.firstIndex(of: ",") else {
            return nil
        }
        let header = href[..<comma]
        let payload = String(href[href.index(after: comma)...])
        if header.hasSuffix(";base64") {
            return Data(base64Encoded: payload.filter { !$0.isWhitespace })
        }
        return percentDecoded(payload)
    }

    /// Percent-encoded bytes decoded (`%89PNG…`); nil when an escape is malformed.
    static func percentDecoded(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        let utf8 = Array(text.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x25 {
                guard index + 2 < utf8.count, let byte = UInt8(String(decoding: utf8[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                    return nil
                }
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return Data(bytes)
    }

    // MARK: Text

    /// One positioned piece of a text element.
    struct TextPiece {
        var text: String
        var origin: Point
        var style: SVGImportStyle
        /// Starts a new anchored chunk (explicit x).
        var chunkStart: Bool
    }

    func text(_ element: SVGImportElement, style: SVGImportStyle) -> [ImportedNode] {
        var pieces: [TextPiece] = []
        var pen = Point(x: 0, y: 0)
        collectText(element, style: style, pen: &pen, pieces: &pieces, first: true)
        // Collapsed white space is trimmed at both ends of the element's text.
        while let first = pieces.first, !first.style.preserveSpace {
            pieces[0].text = String(first.text.drop { $0 == " " })
            guard pieces[0].text.isEmpty else { break }
            pieces.removeFirst()
        }
        while let last = pieces.last, !last.style.preserveSpace {
            pieces[pieces.count - 1].text = String(last.text.reversed().drop { $0 == " " }.reversed())
            guard pieces[pieces.count - 1].text.isEmpty else { break }
            pieces.removeLast()
        }
        pieces = pieces.filter { !$0.text.isEmpty && $0.style.visible }
        guard !pieces.isEmpty else {
            return []
        }
        // Re-lay out with measured advances so each piece starts where the previous ended, then
        // apply the text anchor per chunk.
        var measured: [(piece: TextPiece, font: SVGImportFont, width: Double)] = []
        var x = 0.0
        for piece in pieces {
            var piece = piece
            if !piece.chunkStart {
                piece.origin.x = x
            }
            let font = SVGImportFont.resolve(piece.style)
            let width = font.width(of: piece.text)
            x = piece.origin.x + width
            measured.append((piece, font, width))
        }
        var chunkStart = 0
        for index in measured.indices where index == measured.count - 1 || measured[index + 1].piece.chunkStart {
            let anchor = measured[chunkStart].piece.style.textAnchor
            if anchor == "middle" || anchor == "end" {
                let total = measured[chunkStart...index].reduce(0) { $0 + $1.width }
                let shift = anchor == "middle" ? -total / 2 : -total
                for position in chunkStart...index {
                    measured[position].piece.origin.x += shift
                }
            }
            chunkStart = index + 1
        }
        let name = nodeName(element)
        if options.text == .outlines {
            let paths = measured.map { item -> ImportedNode in
                let contours = item.font.outlines(item.piece.text, at: item.piece.origin)
                return .path(path(contours, style: item.piece.style, name: nil, url: nil))
            }
            return [.group(ImportedGroup(children: paths, name: name))]
        }
        let runs = measured.map { item in
            ImportedTextRun(text: item.piece.text, fontName: item.font.postScriptName, fontSize: item.piece.style.fontSize, fill: paint(item.piece.style.fill, opacity: item.piece.style.fillOpacity, style: item.piece.style, bounds: { Rect(x: item.piece.origin.x, y: item.piece.origin.y - item.piece.style.fontSize, width: max(item.width, 1), height: item.piece.style.fontSize) }), origin: item.piece.origin)
        }
        return [.text(ImportedText(runs: runs, name: name))]
    }

    func collectText(_ element: SVGImportElement, style: SVGImportStyle, pen: inout Point, pieces: inout [TextPiece], first: Bool) {
        let fontSize = style.fontSize
        let xs = SVGImportValues.lengths(element.attributes["x"], percentOf: viewport.width, fontSize: fontSize)
        let ys = SVGImportValues.lengths(element.attributes["y"], percentOf: viewport.height, fontSize: fontSize)
        let dxs = SVGImportValues.lengths(element.attributes["dx"], fontSize: fontSize)
        let dys = SVGImportValues.lengths(element.attributes["dy"], fontSize: fontSize)
        var chunk = first || !xs.isEmpty
        if let x = xs.first { pen.x = x }
        if let y = ys.first { pen.y = y }
        if let dx = dxs.first {
            pen.x += dx
            chunk = true
        }
        if let dy = dys.first { pen.y += dy }
        for content in element.content {
            switch content {
            case .text(let raw):
                let text = style.preserveSpace ? raw.replacingOccurrences(of: "\n", with: " ") : SVGImportConverter.collapse(raw)
                pieces.append(TextPiece(text: text, origin: pen, style: style, chunkStart: chunk))
                chunk = false
            case .element(let child):
                guard child.name == "tspan" || child.name == "a" else {
                    continue
                }
                let properties = SVGImportProperties(child, sheet: sheet)
                guard properties["display"] != "none" else { continue }
                let childStyle = computed(properties, parent: style, element: child)
                collectText(child, style: childStyle, pen: &pen, pieces: &pieces, first: false)
                chunk = false
            }
        }
    }

    /// XML white space collapsed to single spaces (`xml:space="default"`).
    static func collapse(_ text: String) -> String {
        var result = ""
        var space = false
        for character in text {
            if character.isWhitespace {
                space = true
            } else {
                if space {
                    result.append(" ")
                }
                space = false
                result.append(character)
            }
        }
        if space {
            result.append(" ")
        }
        return result
    }
}

// MARK: - Fonts

/// A font resolved from a CSS `font-family` list.
struct SVGImportFont {
    /// The name recorded on the run: the installed face's PostScript name, or the requested
    /// family when nothing installed matches (so font substitution sees what the file asked for).
    var postScriptName: String
    var font: CTFont

    static let generic: [String: String] = ["serif": "Times New Roman", "sans-serif": "Helvetica", "monospace": "Menlo", "cursive": "Apple Chancery", "fantasy": "Papyrus", "system-ui": "Helvetica Neue"]

    static func resolve(_ style: SVGImportStyle) -> SVGImportFont {
        let families = style.fontFamily.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }.filter { !$0.isEmpty }
        let size = CGFloat(style.fontSize)
        var traits: CTFontSymbolicTraits = []
        if style.fontWeight >= 600 { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        for family in families {
            let name = generic[family.lowercased()] ?? family
            let base = CTFontCreateWithName(name as CFString, size, nil)
            let resolvedFamily = CTFontCopyFamilyName(base) as String
            let resolvedName = CTFontCopyPostScriptName(base) as String
            guard resolvedFamily.caseInsensitiveCompare(name) == .orderedSame || resolvedName.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            let font = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
            return SVGImportFont(postScriptName: CTFontCopyPostScriptName(font) as String, font: font)
        }
        return SVGImportFont(postScriptName: families.first ?? "Helvetica", font: CTFontCreateWithName("Helvetica" as CFString, size, nil))
    }

    func line(_ text: String) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineCreateWithAttributedString(attributed)
    }

    /// The advance width of `text`.
    func width(of text: String) -> Double {
        Double(CTLineGetTypographicBounds(line(text), nil, nil, nil))
    }

    /// The glyph outlines of `text` with its baseline starting at `origin`, y down.
    func outlines(_ text: String, at origin: Point) -> [ImportedContour] {
        var contours: [ImportedContour] = []
        let runs = CTLineGetGlyphRuns(line(text)) as! [CTRun]
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // Core Text sets the font of every run, the fallback font where it substituted.
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else {
                    continue
                }
                let place = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x + position.x, ty: origin.y - position.y)
                contours += SVGImportFont.contours(of: path).map { $0.applying(place) }
            }
        }
        return contours
    }

    /// A `CGPath` as contours.
    static func contours(of path: CGPath) -> [ImportedContour] {
        var builder = ImportPathBuilder()
        path.applyWithBlock { element in
            let points = element.pointee.points
            func p(_ i: Int) -> Point { Point(x: Double(points[i].x), y: Double(points[i].y)) }
            switch element.pointee.type {
            case .moveToPoint: builder.move(to: p(0))
            case .addLineToPoint: builder.line(to: p(0))
            case .addQuadCurveToPoint: builder.quad(p(0), p(1))
            case .addCurveToPoint: builder.cubic(p(0), p(1), p(2))
            default: builder.close()
            }
        }
        return builder.build()
    }
}

// MARK: - Flatten groups

/// *Flatten groups*: the file's nested groups replaced by one group around everything (the
/// import group itself); transforms and opacities of dissolved groups move onto their contents.
/// Clipping groups are kept, since dissolving one would unclip its contents.
enum SVGImportFlattener {
    static func flatten(_ nodes: [ImportedNode]) -> [ImportedNode] {
        nodes.flatMap { flatten($0, transform: .identity, opacity: 1) }
    }

    static func flatten(_ node: ImportedNode, transform: AffineTransform, opacity: Double) -> [ImportedNode] {
        switch node {
        case .group(let group) where group.clip == nil:
            let total = group.transform.concatenating(transform)
            return group.children.flatMap { flatten($0, transform: total, opacity: opacity * group.opacity) }
        case .path(var path):
            path.transform = path.transform.concatenating(transform)
            path.opacity *= opacity
            return [.path(path)]
        default:
            let moved = SVGImportConverter.transformed(node, by: transform)
            return opacity < 1 ? [.group(ImportedGroup(children: [moved], opacity: opacity))] : [moved]
        }
    }
}
