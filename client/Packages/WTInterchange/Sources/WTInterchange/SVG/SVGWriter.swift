// The SVG writer (export-vector.adoc, "SVG options" and "Client"; IO-019).  It writes one
// flattened page as SVG 1.1 plus the widely supported SVG 2 parts (`feDropShadow`, CSS Color 4
// colours in `style`): paths with coordinates at the chosen precision, gradients de-duplicated
// into `<defs>`, clips, gradient masks as luminance masks, blur/shadow/glow filters, text as
// `<text>` or outlines (optionally with embedded font subsets), images as data URLs or linked
// files, ids from object names, attached URLs as `<a>` links and Document Info as `<metadata>`;
// alt text and *Decorative* as titles, descriptions and ARIA attributes (IO-031,
// `SVGAccessibility.swift`).
//
// Geometry is written in page space (the page's top-left at 0,0, one user unit per point).  An
// element whose transform is a similarity has its coordinates transformed and its stroke scaled;
// any other transform is written as a `transform` attribute over local coordinates.

import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// A written SVG file and the files it links.
public struct SVGDocument: Sendable {
    public var text: String
    /// Linked images, by path relative to the SVG.
    public var resources: [(path: String, data: Data)]
    /// What the writer changed (outlined fonts, clipped colours).
    public var notes: [String]
    /// Text outlined because its font could not be embedded, by font and node (the HTML
    /// publisher's *outlined font* warnings, WEB-008).
    public var outlinedFonts: [SVGOutlinedFont] = []
}

/// Writes flattened pages as SVG.
public struct SVGWriter: Sendable {
    public var options: SVGOptions
    /// Where a page link to each document page number points (WEB-023): the page's own file
    /// (`page-3.svg`) when pages are separate files, `#page-3` when they share one, the published
    /// page (`page-3.html`, `#page-3`) for the HTML publisher.  A page link to a page without an
    /// entry falls back to the object's URL.
    public var pageHrefs: [Int: String] = [:]
    /// The HTML publisher's shared folders (WEB-008): when set, images and embedded fonts are
    /// written as content-named files there instead of as `options.images` and data URLs say.
    public var linkedFiles: SVGLinkedFiles?

    public init(options: SVGOptions = .defaults, pageHrefs: [Int: String] = [:], linkedFiles: SVGLinkedFiles? = nil) {
        self.options = options
        self.pageHrefs = pageHrefs
        self.linkedFiles = linkedFiles
    }

    /// `page` as SVG; linked images go in `resourceFolder` (relative to the SVG).
    public func write(_ page: FlatPage, scene: ExportScene, resourceFolder: String = "images") -> SVGDocument {
        let build = SVGBuild(options: options, page: page, scene: scene, resourceFolder: resourceFolder)
        build.pageHrefs = pageHrefs
        build.linkedFiles = linkedFiles
        return build.document()
    }
}

/// One page being written.
final class SVGBuild {
    let options: SVGOptions
    let page: FlatPage
    let scene: ExportScene
    let resourceFolder: String
    var ids = SVGIdentifiers()
    var nodeIDs: [NodeID: String] = [:]
    var body: XMLStream
    var defs: XMLStream
    var defsKeys: [String: String] = [:]
    var classes: [String: String] = [:]
    var classOrder: [String] = []
    var fontFaces: [String] = []
    var embeddedFonts: [String: String] = [:]
    var resources: [(path: String, data: Data)] = []
    var notes: [String] = []
    var wideColors = 0
    /// Page links' targets by document page number (`SVGWriter.pageHrefs`).
    var pageHrefs: [Int: String] = [:]
    /// Content-named image and font files in shared folders (`SVGWriter.linkedFiles`).
    var linkedFiles: SVGLinkedFiles?
    var outlinedFonts: [SVGOutlinedFont] = []
    /// Whether accessibility markup is written (IO-031): some object of the document has alt
    /// text or is decorative.  Off, the file is what it was before IO-031.
    lazy var accessible: Bool = scene.nodes.values.contains { $0.decorative || SVGBuild.description($0.alt) != nil }
    /// What the next element written says to assistive technology (the node being written).
    var pending: SVGAccessibility = .none
    /// Open figures and hidden elements: their descendants carry nothing of their own.
    var figureDepth = 0
    /// Figures written on this page.
    var figures = 0
    /// The root's `<title>` and `<desc>` ids.
    var rootIDs: (title: String, desc: String?) = ("", nil)
    /// Pasteboard → page space.
    let toPage: AffineTransform

    init(options: SVGOptions, page: FlatPage, scene: ExportScene, resourceFolder: String) {
        self.options = options
        self.page = page
        self.scene = scene
        self.resourceFolder = resourceFolder
        body = XMLStream(minify: options.minify)
        defs = XMLStream(minify: options.minify)
        toPage = .translation(x: -page.bounds.minX, y: -page.bounds.minY)
    }

    func number(_ value: Double) -> String {
        Numbers.format(value, places: options.precision)
    }

    // MARK: Document

    func document() -> SVGDocument {
        assignNodeIDs(page.nodes)
        body = XMLStream(minify: options.minify)
        for node in page.nodes {
            write(node)
        }
        writeTextLinks()
        var out = XMLStream(minify: options.minify)
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        if !options.minify {
            text += "\n<!-- Generator: \(XMLStream.escape(scene.info.creator, attribute: false)) -->"
        }
        let width = page.bounds.width, height = page.bounds.height
        // Validated by the exporter; a writer used directly with an unknown unit writes points.
        let unit = SVGOptions.unitScale[options.sizeUnit, default: 1]
        out.start("svg", [
            ("xmlns", "http://www.w3.org/2000/svg"),
            ("xmlns:xlink", "http://www.w3.org/1999/xlink"),
            ("version", "1.1"),
            ("width", options.responsive ? nil : number(width * unit) + options.sizeUnit),
            ("height", options.responsive ? nil : number(height * unit) + options.sizeUnit),
            ("viewBox", "0 0 \(number(width)) \(number(height))"),
            ("xml:lang", options.includeDocumentInfo || accessible ? scene.info.effectiveLanguage : nil),
        ] + rootAccessibility())
        if accessible {
            writeRootLabel(into: &out)
        }
        if options.includeDocumentInfo && !scene.info.isEmpty {
            writeMetadata(into: &out)
        }
        if !defs.text.isEmpty || !classOrder.isEmpty || !fontFaces.isEmpty {
            out.start("defs")
            if !classOrder.isEmpty || !fontFaces.isEmpty {
                let rules = fontFaces + classOrder.map { ".\(classes[$0]!){\($0)}" }
                out.element("style", [("type", "text/css")], text: rules.joined(separator: options.minify ? "" : "\n"))
            }
            if !defs.text.isEmpty {
                out.raw(indented(defs.text, levels: 2))
            }
            out.end()
        }
        if options.pageBackground, let background = page.background {
            var attributes: [(String, String?)] = [("width", number(width)), ("height", number(height))]
            attributes += styleAttributes(paint(background, "fill"))
            out.element("rect", attributes)
        }
        if !body.text.isEmpty {
            out.raw(indented(body.text, levels: 1))
        }
        out.end()
        if wideColors > 0 {
            notes.append("\(wideColors) wide-gamut color\(wideColors == 1 ? "" : "s") written as Display P3 with an sRGB fallback")
        }
        return SVGDocument(text: text + (options.minify ? "" : "\n") + out.text + (options.minify ? "" : "\n"), resources: resources, notes: notes, outlinedFonts: outlinedFonts)
    }

    /// `fragment` (written at indentation 0) shifted right by `levels`.
    func indented(_ fragment: String, levels: Int) -> String {
        guard !options.minify else {
            return fragment
        }
        let prefix = String(repeating: "  ", count: levels)
        return fragment.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : prefix + $0.element }.joined(separator: "\n")
    }

    func writeMetadata(into out: inout XMLStream) {
        let info = scene.info
        if let writer = info.metadataWriter(documentName: scene.name) {
            out.raw(writer.svgMetadata)
            return
        }
        out.start("metadata")
        out.start("rdf:RDF", [("xmlns:rdf", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"), ("xmlns:dc", "http://purl.org/dc/elements/1.1/")])
        out.start("rdf:Description", [("rdf:about", "")])
        let fields: [(String, String?)] = [
            ("dc:title", info.title), ("dc:creator", info.author), ("dc:description", info.description),
            ("dc:subject", info.subject), ("dc:language", info.language),
        ]
        for (name, value) in fields {
            if let value {
                out.element(name, text: value)
            }
        }
        for keyword in info.keywords {
            out.element("dc:subject", text: keyword)
        }
        out.end()
        out.end()
        out.end()
    }

    // MARK: Ids

    /// Names become ids before anything is generated, so a name always keeps its spelling.
    func assignNodeIDs(_ nodes: [FlatNode]) {
        for node in nodes {
            if let id = node.node, nodeIDs[id] == nil {
                switch options.ids {
                case .fromNames:
                    if let name = scene.nodes[id]?.name, let unique = ids.unique(name) {
                        nodeIDs[id] = unique
                    }
                case .generated:
                    nodeIDs[id] = ids.generate("o")
                case .none:
                    break
                }
            }
            if case .group(let group) = node {
                assignNodeIDs(group.children)
            }
        }
    }

    func idAttribute(_ node: NodeID?) -> (String, String?) {
        ("id", node.flatMap { nodeIDs[$0] })
    }

    // MARK: Elements

    func write(_ node: FlatNode) {
        let link = anchor(scene.info(for: node.node))
        if let link {
            body.start("a", link.attributes)
            if let title = link.title {
                body.element("title", text: title)
            }
        }
        pending = accessibility(of: node)
        let marks = pending != .none
        if marks { figureDepth += 1 }
        defer { if marks { figureDepth -= 1 } }
        switch node {
        case .path(let path):
            writePath(path)
        case .text(let text):
            writeText(text)
        case .image(let image):
            writeImage(image)
        case .group(let group):
            writeGroup(group)
        }
        if link != nil {
            body.end()
        }
    }

    // MARK: Links (WEB-005, WEB-023)

    /// The `<a>` an object's click becomes: `xlink:href` from its page link (via `pageHrefs`) or
    /// its URL completed by `WebLinks.href`, `target="_blank"` for *New tab*, and a `<title>`
    /// child carrying the link's alt text.  Nil for no link or an address that cannot be made
    /// valid (the output warnings list it).
    func anchor(_ info: ExportNodeInfo?) -> (attributes: [(String, String?)], title: String?)? {
        guard let info, info.url != nil || info.pageLink != nil else { return nil }
        let href: String?
        if let page = info.pageLink, let target = pageHrefs[page] {
            href = target
        } else {
            href = info.url.flatMap(WebLinks.href)
        }
        guard let href else { return nil }
        let target = info.linkTarget == .newTab && info.pageLink.flatMap({ pageHrefs[$0] }) == nil ? "_blank" : nil
        return ([("xlink:href", href), ("target", target)], info.linkAlt)
    }

    /// Text-range links on this page: an anchor over each line of each range, holding an
    /// invisible rectangle that takes the click (the glyphs stay where the text writer put them).
    func writeTextLinks() {
        pending = .none
        for node in scene.textLinks.keys.sorted() {
            for link in scene.textLinks[node]! {
                guard let href = WebLinks.href(link.url) else { continue }
                let rects = link.rects.compactMap { $0.intersection(page.bounds).nonEmpty }
                guard !rects.isEmpty else { continue }
                body.start("a", [("xlink:href", href)])
                if let title = link.alt {
                    body.element("title", text: title)
                }
                for rect in rects {
                    let box = rect.applying(toPage)
                    body.element("rect", [("x", number(box.minX)), ("y", number(box.minY)), ("width", number(box.width)), ("height", number(box.height)),
                                          ("fill", "#000"), ("fill-opacity", "0")])
                }
                body.end()
            }
        }
    }

    func writeGroup(_ group: FlatGroup) {
        var attributes: [(String, String?)] = [idAttribute(group.node)]
        if let clip = group.clip {
            attributes.append(("clip-path", "url(#\(clipPath(clip)))"))
        }
        if let mask = group.softMask {
            attributes.append(("mask", "url(#\(softMask(mask)))"))
        }
        if let filter = group.filter, let bounds = FlatNode.group(group).bounds {
            attributes.append(("filter", "url(#\(self.filter(filter, bounds: bounds)))"))
        }
        if group.opacity < 1 {
            attributes += styleAttributes([("opacity", number(group.opacity))])
        }
        begin("g", attributes)
        for child in group.children {
            write(child)
        }
        body.end()
    }

    /// A transform written: nil when the geometry is transformed instead.
    struct Placement {
        /// Applied to coordinates before writing.
        var points: AffineTransform
        /// The `transform` attribute, if any.
        var attribute: String?
        /// Stroke widths and dashes scale by this.
        var scale: Double
    }

    /// How an element with local → pasteboard `transform` is placed in page space.
    func placement(for transform: AffineTransform) -> Placement {
        let toPage = transform.concatenating(self.toPage)
        let similarity = abs(toPage.a - toPage.d) < 1e-9 && abs(toPage.b + toPage.c) < 1e-9
        if similarity {
            return Placement(points: toPage, attribute: nil, scale: abs(toPage.determinant).squareRoot())
        }
        return Placement(points: .identity, attribute: matrix(toPage), scale: 1)
    }

    func matrix(_ t: AffineTransform) -> String {
        "matrix(\([t.a, t.b, t.c, t.d, t.tx, t.ty].map { Numbers.format($0, places: max(options.precision, 4)) }.joined(separator: " ")))"
    }

    func pathData(_ path: DisplayPath, _ transform: AffineTransform) -> String {
        var parts: [String] = []
        func point(_ p: Point) -> String {
            let q = transform.apply(p)
            return "\(number(q.x)) \(number(q.y))"
        }
        for element in path.elements {
            switch element {
            case .move(let p): parts.append("M" + point(p))
            case .line(let p): parts.append("L" + point(p))
            case .quadCurve(let c, let e): parts.append("Q" + point(c) + " " + point(e))
            case .cubicCurve(let c1, let c2, let e): parts.append("C" + point(c1) + " " + point(c2) + " " + point(e))
            case .close: parts.append("Z")
            }
        }
        return parts.joined(separator: options.minify ? "" : " ")
    }

    func writePath(_ item: FlatPath) {
        let place = placement(for: item.transform)
        var properties: [(String, String)] = []
        switch item.style {
        case .fill(let rule):
            properties += paintProperties(item.paint, property: "fill", placement: place, transform: item.transform)
            if rule == .evenOdd {
                properties.append(("fill-rule", "evenodd"))
            }
        case .stroke(let style):
            properties.append(("fill", "none"))
            properties += paintProperties(item.paint, property: "stroke", placement: place, transform: item.transform)
            properties += strokeProperties(style, scale: place.scale)
        }
        emit("path", [idAttribute(item.node), ("d", pathData(item.path, place.points)), ("transform", place.attribute)] + styleAttributes(properties))
    }

    func strokeProperties(_ style: StrokeStyle, scale: Double) -> [(String, String)] {
        var result: [(String, String)] = []
        if style.isHairline {
            result.append(("stroke-width", "1"))
            result.append(("vector-effect", "non-scaling-stroke"))
        } else {
            result.append(("stroke-width", number(style.width * scale)))
        }
        switch style.cap {
        case .butt: break
        case .round: result.append(("stroke-linecap", "round"))
        case .square: result.append(("stroke-linecap", "square"))
        }
        switch style.join {
        case .miter:
            if style.miterLimit != 4 {
                result.append(("stroke-miterlimit", number(style.miterLimit)))
            }
        case .round: result.append(("stroke-linejoin", "round"))
        case .bevel: result.append(("stroke-linejoin", "bevel"))
        }
        let dash = style.effectiveDash
        if !dash.isEmpty {
            result.append(("stroke-dasharray", dash.map { number($0 * scale) }.joined(separator: " ")))
            if style.dashPhase != 0 {
                result.append(("stroke-dashoffset", number(style.dashPhase * scale)))
            }
        }
        return result
    }

    // MARK: Paint and colour

    func paintProperties(_ paint: FlatPaint, property: String, placement: Placement, transform: AffineTransform) -> [(String, String)] {
        switch paint {
        case .color(let color):
            return self.paint(color, property)
        case .gradient(let gradient):
            // A pre-transformed element needs the gradient mapped the same way; a transformed one
            // takes it in its own local space.
            let gradientTransform = placement.attribute == nil ? transform.concatenating(toPage) : .identity
            return [(property, "url(#\(self.gradient(gradient, transform: gradientTransform)))")]
        }
    }

    /// `color` as `property` (and `property-opacity` when translucent).  A wide-gamut value gets
    /// its Display P3 form as a second declaration, which CSS Color 4 viewers use and others skip.
    func paint(_ color: Color, _ property: String) -> [(String, String)] {
        var result = [(property, ColorMath.hex(color))]
        if ColorMath.isWide(color) {
            wideColors += 1
            let p3 = ColorMath.displayP3(color)
            result.append(("~" + property, "color(display-p3 \(Numbers.format(p3.x, places: 4)) \(Numbers.format(p3.y, places: 4)) \(Numbers.format(p3.z, places: 4)))"))
        }
        if color.alpha < 1 {
            result.append(("\(property)-opacity", number(max(color.alpha, 0))))
        }
        return result
    }

    /// Properties as the styling option writes them.  A property named `~name` is a CSS-only
    /// override of `name` (the wide-gamut colour) that presentation attributes cannot carry.
    func styleAttributes(_ properties: [(String, String)]) -> [(String, String?)] {
        guard !properties.isEmpty else {
            return []
        }
        let declarations = properties.map { "\($0.0.hasPrefix("~") ? String($0.0.dropFirst()) : $0.0):\($0.1)" }.joined(separator: ";")
        switch options.styling {
        case .presentationAttributes:
            let plain = properties.filter { !$0.0.hasPrefix("~") }.map { ($0.0, Optional($0.1)) }
            let overrides = properties.filter { $0.0.hasPrefix("~") }.map { "\($0.0.dropFirst()):\($0.1)" }
            return plain + (overrides.isEmpty ? [] : [("style", overrides.joined(separator: ";"))])
        case .inlineStyle:
            return [("style", declarations)]
        case .cssClasses:
            if classes[declarations] == nil {
                classes[declarations] = ids.generate("st")
                classOrder.append(declarations)
            }
            return [("class", classes[declarations])]
        }
    }

    // MARK: Definitions

    /// The id of a definition written once per distinct `key`.
    func definition(_ key: String, prefix: String, write: (String, inout XMLStream) -> Void) -> String {
        if let id = defsKeys[key] {
            return id
        }
        let id = ids.generate(prefix)
        defsKeys[key] = id
        write(id, &defs)
        return id
    }

    func gradient(_ gradient: FlatGradient, transform: AffineTransform) -> String {
        let key = "g|\(gradient.shape)|\(gradient.gradient)|\(matrix(transform))"
        return definition(key, prefix: "wt-g") { id, out in
            writeGradient(gradient, id: id, transform: transform, stops: gradient.linearStops().map { ($0.offset, $0.color) }, into: &out)
        }
    }

    func writeGradient(_ gradient: FlatGradient, id: String, transform: AffineTransform, stops: [(Double, Color)], into out: inout XMLStream) {
        var attributes: [(String, String?)] = [("id", id), ("gradientUnits", "userSpaceOnUse")]
        let name: String
        switch gradient.shape {
        case .axial(let start, let end):
            name = "linearGradient"
            attributes += [("x1", number(start.x)), ("y1", number(start.y)), ("x2", number(end.x)), ("y2", number(end.y))]
            attributes.append(("gradientTransform", transform.isIdentity ? nil : matrix(transform)))
        case .radial(let frame):
            name = "radialGradient"
            attributes += [("cx", "0"), ("cy", "0"), ("r", "1")]
            attributes.append(("gradientTransform", matrix(frame.concatenating(transform))))
        }
        out.start(name, attributes)
        var previous: (Double, Color)?
        for (index, stop) in stops.enumerated() {
            // Collinear runs of equal colour add nothing.
            if let previous, index + 1 < stops.count, previous.1 == stop.1, stops[index + 1].1 == stop.1 {
                continue
            }
            var stopAttributes: [(String, String?)] = [("offset", Numbers.format(stop.0, places: 4)), ("stop-color", ColorMath.hex(stop.1))]
            if stop.1.alpha < 1 {
                stopAttributes.append(("stop-opacity", Numbers.format(max(stop.1.alpha, 0), places: 4)))
            }
            out.element("stop", stopAttributes)
            previous = stop
        }
        out.end()
    }

    func clipPath(_ clip: FlatClip) -> String {
        let place = placement(for: clip.transform)
        let data = pathData(clip.path, place.points)
        let key = "c|\(data)|\(clip.rule)|\(place.attribute ?? "")"
        return definition(key, prefix: "wt-c") { id, out in
            out.start("clipPath", [("id", id), ("clipPathUnits", "userSpaceOnUse")])
            out.element("path", [("d", data), ("transform", place.attribute), ("clip-rule", clip.rule == .evenOdd ? "evenodd" : nil)])
            out.end()
        }
    }

    /// A luminance mask whose white is painted with the factor as `stop-opacity`: white's
    /// luminance is 1 in both sRGB and linear light, so every viewer reads the factor exactly.
    func softMask(_ mask: FlatSoftMask) -> String {
        let bounds = mask.bounds.applying(toPage)
        let gradientTransform = mask.frame.concatenating(toPage)
        let stops = (0...64).map { index -> (Double, Color) in
            let t = Double(index) / 64
            return (t, Color(white: 1, alpha: mask.value(at: t)))
        }
        let gradientID = definition("mg|\(mask.gradient.shape)|\(mask.gradient.gradient)|\(matrix(gradientTransform))", prefix: "wt-g") { id, out in
            writeGradient(mask.gradient, id: id, transform: gradientTransform, stops: stops, into: &out)
        }
        let rect: [(String, String?)] = [("x", number(bounds.minX)), ("y", number(bounds.minY)), ("width", number(bounds.width)), ("height", number(bounds.height))]
        return definition("m|\(gradientID)|\(rect.map { $0.1 ?? "" })", prefix: "wt-m") { id, out in
            out.start("mask", [("id", id), ("maskUnits", "userSpaceOnUse")] + rect)
            out.element("rect", rect + [("fill", "url(#\(gradientID))")])
            out.end()
        }
    }

    func filter(_ filter: FlatFilter, bounds: Rect) -> String {
        let region = bounds.applying(toPage)
        let rect: [(String, String?)] = [("x", number(region.minX)), ("y", number(region.minY)), ("width", number(region.width)), ("height", number(region.height))]
        return definition("f|\(filter)|\(rect.map { $0.1 ?? "" })", prefix: "wt-f") { id, out in
            out.start("filter", [("id", id), ("filterUnits", "userSpaceOnUse"), ("color-interpolation-filters", "sRGB")] + rect)
            switch filter {
            case .blur(let sigma):
                out.element("feGaussianBlur", [("stdDeviation", number(sigma))])
            case .dropShadow(let dx, let dy, let sigma, let color):
                out.element("feDropShadow", [("dx", number(dx)), ("dy", number(dy)), ("stdDeviation", number(sigma)), ("flood-color", ColorMath.hex(color)), ("flood-opacity", number(color.alpha))])
            case .glow(let radius, let sigma, let color):
                out.element("feMorphology", [("in", "SourceAlpha"), ("operator", "dilate"), ("radius", number(radius)), ("result", "spread")])
                out.element("feGaussianBlur", [("in", "spread"), ("stdDeviation", number(sigma)), ("result", "soft")])
                out.element("feFlood", [("flood-color", ColorMath.hex(color)), ("flood-opacity", number(color.alpha))])
                out.element("feComposite", [("in2", "soft"), ("operator", "in"), ("result", "glow")])
                out.start("feMerge")
                out.element("feMergeNode", [("in", "glow")])
                out.element("feMergeNode", [("in", "SourceGraphic")])
                out.end()
            }
            out.end()
        }
    }

    // MARK: Text

    func writeText(_ text: FlatText) {
        let scalars = Array(text.text.unicodeScalars)
        let run = text.run
        let positioned = run.glyphs.count == scalars.count && run.glyphs.allSatisfy { $0.transform == nil } && run.font.horizontalScale == 1
        guard options.text != .outlines, positioned else {
            readAsOutlines(text.text)
            writePath(FlatPath(path: run.outline, transform: text.transform, paint: .color(text.color), node: text.node))
            if options.text != .outlines {
                notes.append("text \"\(text.text)\" written as outlines (its glyphs do not map one to one onto characters)")
            }
            return
        }
        let facts = FontFacts(run.font.ctFont)
        var family = "'\(facts.familyName)'"
        if options.text == .asTextEmbedFonts {
            guard let embedded = embeddedFamily(for: run, facts: facts) else {
                notes.append("font \(facts.postScriptName) cannot be embedded; its text is written as outlines")
                outlinedFonts.append(SVGOutlinedFont(postScriptName: facts.postScriptName, node: text.node, restricted: !facts.embeddable))
                readAsOutlines(text.text)
                writePath(FlatPath(path: run.outline, transform: text.transform, paint: .color(text.color), node: text.node))
                return
            }
            family = "'\(embedded)', " + family
        }
        let toPage = text.transform.concatenating(self.toPage)
        let translationOnly = toPage.a == 1 && toPage.b == 0 && toPage.c == 0 && toPage.d == 1
        let shift = translationOnly ? Vector(toPage.tx, toPage.ty) : .zero
        let xs = run.glyphs.map { number($0.position.x + shift.dx) }.joined(separator: " ")
        let ysValues = run.glyphs.map { number($0.position.y + shift.dy) }
        let ys = Set(ysValues).count == 1 ? ysValues[0] : ysValues.joined(separator: " ")
        var properties: [(String, String)] = [("font-family", family), ("font-size", number(run.font.size))]
        if facts.cssWeight != 400 {
            properties.append(("font-weight", String(facts.cssWeight)))
        }
        if facts.italic {
            properties.append(("font-style", "italic"))
        }
        properties += paint(text.color, "fill")
        emit("text", [idAttribute(text.node), ("transform", translationOnly ? nil : matrix(toPage)), ("x", xs), ("y", ys), ("xml:space", "preserve")] + styleAttributes(properties), text: text.text)
    }

    /// The family name of an embedded subset holding every glyph of the fonts `run` uses, or
    /// nil when the font has no TrueType outlines or forbids embedding.  One subset per font
    /// holds the glyphs of every run seen so far (the face is written when the page is done).
    func embeddedFamily(for run: GlyphRun, facts: FontFacts) -> String? {
        guard run.font.subsettable else {
            return nil
        }
        let key = facts.postScriptName
        if let family = embeddedFonts[key] {
            return family
        }
        let family = ids.generate("wt-font-")
        embeddedFonts[key] = family
        let glyphs = Set(collectGlyphs(of: key, in: page.nodes))
        // A font with TrueType outlines always subsets.
        let data = FontProgram.trueTypeSubset(of: run.font.ctFont, glyphs: glyphs)!
        if let linkedFiles, let url = linkedFont(data, in: linkedFiles) {
            fontFaces.append("@font-face{font-family:'\(family)';src:url(\(url)) format('woff2')}")
            return family
        }
        fontFaces.append("@font-face{font-family:'\(family)';src:url(\(ImageEncoding.dataURL(data, mime: "font/ttf"))) format('truetype')}")
        return family
    }

    func collectGlyphs(of postScriptName: String, in nodes: [FlatNode]) -> [CGGlyph] {
        nodes.flatMap { node -> [CGGlyph] in
            switch node {
            case .text(let text) where text.run.font.postScriptName == postScriptName:
                return text.run.glyphs.map(\.glyph)
            case .group(let group):
                return collectGlyphs(of: postScriptName, in: group.children)
            default:
                return []
            }
        }
    }

    // MARK: Images

    func writeImage(_ image: FlatImage) {
        let toPage = image.transform.concatenating(self.toPage)
        let translationOnly = toPage.a == 1 && toPage.b == 0 && toPage.c == 0 && toPage.d == 1
        let rect = translationOnly ? image.rect.applying(toPage) : image.rect
        let original = image.rasterized ? nil : image.jpegData
        let reference: String
        if let linkedFiles {
            reference = linkedImage(image.image, original: original, in: linkedFiles)
        } else {
            switch options.images {
            case .embed:
                if let original {
                    reference = ImageEncoding.dataURL(original, mime: "image/jpeg")
                } else {
                    reference = ImageEncoding.dataURL(png(image.image), mime: "image/png")
                }
            case .link, .linkOriginals:
                let index = resources.count + 1
                if options.images == .linkOriginals, let original {
                    reference = "\(resourceFolder)/image-\(index).jpg"
                    resources.append((reference, original))
                } else {
                    reference = "\(resourceFolder)/image-\(index).png"
                    resources.append((reference, png(image.image)))
                }
            }
        }
        emit("image", [
            idAttribute(image.node),
            ("x", number(rect.minX)), ("y", number(rect.minY)), ("width", number(rect.width)), ("height", number(rect.height)),
            ("transform", translationOnly ? nil : matrix(toPage)),
            ("preserveAspectRatio", "none"),
            ("xlink:href", reference),
        ])
    }

    func png(_ image: CGImage) -> Data {
        // Every CGImage the flattener produces encodes as PNG.
        ImageEncoding.encode(image, type: .png)!
    }
}
