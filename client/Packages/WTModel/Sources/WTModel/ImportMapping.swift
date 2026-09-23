import CoreText
import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender
import struct WTGeometry.AffineTransform

// Placing an imported file (import-formats.adoc, "Imported scene to document"; IMG-008, IMG-011,
// WEB-025): WTInterchange's converters return a neutral `ImportedScene`, and this file turns it
// into the ops of one change -- the subtree on the current layer (with the fallback rule of
// importing.adoc, "Where the artwork goes"), the *Notes* and *URLs* layers, and the `asset` nodes
// holding link records and SVG animation blobs.

extension WellKnown {
    /// The assets collection (0:9): `asset` nodes holding blobs and link records.
    public static let assets = OpID.wellKnown(9)
}

/// Where an imported file came from, for its link record (`AssetProps.link`,
/// linking-embedding.adoc): a file on this Mac.  Pasted artwork has none.
public struct ImportLink: Hashable, Sendable {
    /// The file name shown in the Links panel.
    public var displayName: String
    /// The file's path on the importing Mac.
    public var path: String
    /// The importing Mac's name (a path is only meaningful there).
    public var device: String
    /// The file's modification date when imported.
    public var modified: Date?

    public init(displayName: String, path: String, device: String = "", modified: Date? = nil) {
        self.displayName = displayName
        self.path = path
        self.device = device
        self.modified = modified
    }

    /// The link record of the file at `url`.
    public init(fileURL url: URL, device: String = "") {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        self.init(displayName: url.lastPathComponent, path: url.path, device: device, modified: modified)
    }
}

/// An SVG animation's poster frame (svg-animation.adoc, "Client"): a PNG rendered at import,
/// stored as its own asset so every replica can draw the object before the SVG has downloaded.
public struct ImportedPoster: Hashable, Sendable {
    public var blob: ImportedBlob
    public var timeMs: UInt64

    public init(blob: ImportedBlob, timeMs: UInt64 = 0) {
        self.blob = blob
        self.timeMs = timeMs
    }
}

/// How an import lands (importing.adoc, "Importing with the Import command").
public enum ImportPlacement: Hashable, Sendable {
    /// The scene's top-left corner at `point` (pasteboard space), at its natural size.
    case at(Point)
    /// Scaled to fit inside `rect` keeping its proportions and centred in it; `fillWidth`
    /// (Shift) scales it to the rect's width exactly, from the rect's top-left corner.
    case fit(Rect, fillWidth: Bool)

    /// The transform taking the scene's coordinates (its `bounds`) onto the pasteboard.
    public func transform(for bounds: Rect) -> AffineTransform {
        let toOrigin = AffineTransform.translation(x: -bounds.minX, y: -bounds.minY)
        switch self {
        case .at(let point):
            return toOrigin.concatenating(.translation(x: point.x, y: point.y))
        case .fit(let rect, let fillWidth):
            guard bounds.width > 0, bounds.height > 0 else {
                return toOrigin.concatenating(.translation(x: rect.minX, y: rect.minY))
            }
            let widthScale = rect.width / bounds.width
            let scale = fillWidth ? widthScale : min(widthScale, rect.height / bounds.height)
            let x = fillWidth ? rect.minX : rect.minX + (rect.width - bounds.width * scale) / 2
            let y = fillWidth ? rect.minY : rect.minY + (rect.height - bounds.height * scale) / 2
            return toOrigin.concatenating(.scale(scale)).concatenating(.translation(x: x, y: y))
        }
    }
}

/// The layer an import goes onto (importing.adoc, "Where the artwork goes").
public struct ImportTarget: Hashable, Sendable {
    /// The layer, or nil when a new one is created at the top of the list.
    public var layer: OpID?
    /// Whether the preferred layer was locked or hidden and another took its place, which the
    /// status bar reports.
    public var fellBack: Bool

    /// The current layer when it is visible and unlocked; otherwise the nearest such layer above
    /// it; otherwise (none above) a new layer.  With no preferred layer (or one that is no longer
    /// live), the drawing layer, or a new layer when there is none.
    public static func resolve(preferred: OpID?, in state: EngineState) -> ImportTarget {
        let order = LayerOrder(state)
        func accepts(_ info: LayerInfo) -> Bool { info.visible && !info.locked && info.role == .ordinary }
        guard let preferred, let index = order.index(of: preferred) else {
            return ImportTarget(layer: order.drawingLayer, fellBack: false)
        }
        if accepts(order.layers[index]) { return ImportTarget(layer: preferred, fellBack: false) }
        let above = order.layers[(index + 1)...].first(where: accepts)
        return ImportTarget(layer: above?.id, fellBack: true)
    }
}

/// menu:File[Import…], a drop or a paste (IMG-005, IMG-008): the scene's subtree on the current
/// layer, its named layers' artwork, its asset nodes; one change labelled "Import <file>" (vector
/// files) or "Place <file>" (bitmaps and placed files).  Blobs must be in the local cache and
/// `blobs_pending` before it runs.
public struct PlaceImportedScene: Command {
    public var scene: ImportedScene
    public var placement: ImportPlacement
    /// The current layer (the Layers panel's), nil for the drawing layer.
    public var layer: OpID?
    /// The file's link record, when it was imported from a file.
    public var link: ImportLink?
    /// An SVG animation's poster.
    public var poster: ImportedPoster?

    public init(_ scene: ImportedScene, placement: ImportPlacement, layer: OpID? = nil, link: ImportLink? = nil, poster: ImportedPoster? = nil) {
        self.scene = scene
        self.placement = placement
        self.layer = layer
        self.link = link
        self.poster = poster
    }

    public var label: String { scene.kind == .vector ? "Import \(scene.name)" : "Place \(scene.name)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        // Only a file placed whole has a link record; images inside a vector file have none.
        var writer = ImportWriter(state: state, link: scene.kind == .vector ? nil : link, poster: poster)
        let target = ImportTarget.resolve(preferred: layer, in: state)
        // No layer takes it: a new one at the top ("Foreground" in a document without layers).
        let parent = try target.layer ?? writer.createLayer(name: target.fellBack ? "Imported Artwork" : "Foreground", above: nil, builder: &builder)
        let placed = placement.transform(for: scene.bounds)
        let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        let key = try PathEditing.topPosition(in: parent, state: state)
        try writer.create(scene.subtree, parent: parent, position: key, placement: placed.concatenating(toParent), builder: &builder)
        var created: [String: OpID] = [:]
        for layer in scene.layers where !layer.nodes.isEmpty {
            let order = LayerOrder(state)
            let existing = order.layers.first { $0.name == layer.name && $0.role == .ordinary }?.id ?? created[layer.name]
            let destination = try existing ?? writer.createLayer(name: layer.name, above: order.layers.last?.id, builder: &builder)
            created[layer.name] = destination
            let toLayer = Objects.pasteboardTransform(ofSpace: destination, in: state).inverse
            let top = state.store.children(destination).last.flatMap { state.store.placement($0)?.position }
            let keys = try PathEditing.keys(between: top, and: nil, count: layer.nodes.count)
            for (node, key) in zip(layer.nodes, keys) {
                try writer.create(node, parent: destination, position: key, placement: placed.concatenating(toLayer), builder: &builder)
            }
        }
    }

    /// The node the import placed on the target layer in `change` (the one to select): the first
    /// node the change created directly under a layer.
    public static func placedRoot(of change: Wiretuner_Doc_V1_Change, in state: EngineState) -> OpID? {
        zip(change.ops, change.opIDs).first { op, _ in
            guard case .create(let create) = op.op, case .layer? = state.props(OpID(create.parent)).kind else { return false }
            return true
        }?.1
    }
}

/// Writes imported nodes (the mapping table of import-formats.adoc).
struct ImportWriter {
    let state: EngineState
    let link: ImportLink?
    let poster: ImportedPoster?
    /// Assets created in this change, by blob hash.
    private var assets: [Data: OpID] = [:]
    /// Keys for the assets created in this change, above the existing ones.
    private var assetKey: [UInt8]?

    init(state: EngineState, link: ImportLink?, poster: ImportedPoster?) {
        self.state = state
        self.link = link
        self.poster = poster
    }

    /// A visible, printing layer named `name` above `above` (at the top without one).
    func createLayer(name: String, above: OpID?, builder: inout ChangeBuilder) throws -> OpID {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.layer.common.name = name
        props.layer.visible = true
        props.layer.printing = true
        return builder.append(Ops.create(parent: WellKnown.layers, position: try Layers.keyAbove(above, state: state), props: props))
    }

    /// Creates `node` under `parent`; `placement` is composed onto its own transform (the top
    /// node's click or marquee placement expressed in the parent's space; identity below it).
    @discardableResult
    mutating func create(_ node: ImportedNode, parent: OpID, position: [UInt8], placement: AffineTransform = .identity,
                         builder: inout ChangeBuilder) throws -> OpID {
        switch node {
        case .group(let group):
            let id = try NodeCopier.create(NodeTree(props: ImportMapping.group(group, placement: placement)), parent: parent, position: position,
                                           schema: state.schema, builder: &builder)
            var children = group.children
            var clip: ImportedPath?
            if var path = group.clip {
                path.fill = .none
                path.stroke = nil
                path.opacity = 1
                clip = path
                children.insert(.path(path), at: 0)
            }
            let keys = try PathEditing.keys(between: nil, and: nil, count: children.count)
            var created: [OpID] = []
            for (child, key) in zip(children, keys) {
                created.append(try create(child, parent: id, position: key, builder: &builder))
            }
            if clip != nil {
                var props = Wiretuner_Doc_V1_NodeProps()
                props.group.clipPath.id = created[0].proto
                builder.append(Ops.set(id, [RegisterPath([NodeKind.group.rawValue, 4])], values: props))
            }
            return id
        case .path(let path):
            return try NodeCopier.create(NodeTree(props: ImportMapping.path(path, placement: placement)), parent: parent, position: position,
                                         schema: state.schema, builder: &builder)
        case .text(let text):
            return createText(text, parent: parent, position: position, placement: placement, builder: &builder)
        case .image(let image):
            let source = try link.map { try asset(image.pixels.blob, name: $0.displayName, link: $0, builder: &builder) }
            return builder.append(Ops.create(parent: parent, position: position, props: ImportMapping.image(image, source: source, placement: placement)))
        case .placed(let placed):
            return try createPlaced(placed, parent: parent, position: position, placement: placement, builder: &builder)
        }
    }

    private func createText(_ text: ImportedText, parent: OpID, position: [UInt8], placement: AffineTransform,
                            builder: inout ChangeBuilder) -> OpID {
        let origin = text.runs.first?.origin ?? Point(x: 0, y: 0)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.common = ImportMapping.common(name: text.name, transform: AffineTransform.translation(x: origin.x, y: origin.y)
            .concatenating(text.transform).concatenating(placement))
        props.text.block.autoWidth = true
        let node = builder.append(Ops.create(parent: parent, position: position, props: props))
        // The runs' strings with a line break between runs on different baselines.
        var scalars: [Unicode.Scalar] = []
        var spans: [(run: ImportedTextRun, start: Int, count: Int)] = []
        for (index, run) in text.runs.enumerated() {
            if index > 0, abs(run.origin.y - text.runs[index - 1].origin.y) > 0.01 { scalars.append("\n") }
            let runScalars = Array(run.text.unicodeScalars)
            spans.append((run, scalars.count, runScalars.count))
            scalars += runScalars
        }
        guard !scalars.isEmpty else { return node }
        var string = String.UnicodeScalarView()
        string.append(contentsOf: scalars)
        let field = RegisterPath([130, 2])
        let first = builder.append(Ops.textInsert(node, field, String(string)))
        for span in spans where span.count > 0 {
            let start = OpID(counter: first.counter + UInt64(span.start), replica: first.replica)
            let end = OpID(counter: first.counter + UInt64(span.start + span.count - 1), replica: first.replica)
            for value in ImportMapping.marks(span.run) {
                builder.append(ImportMapping.mark(node, field, from: start, to: end, value: value))
            }
        }
        return node
    }

    private mutating func createPlaced(_ placed: ImportedPlacedFile, parent: OpID, position: [UInt8], placement: AffineTransform,
                                       builder: inout ChangeBuilder) throws -> OpID {
        let name = placed.name ?? ""
        switch placed.kind {
        case .eps:
            let source = try link.map { try asset(placed.blob, name: name, link: $0, builder: &builder) }
            var props = Wiretuner_Doc_V1_NodeProps()
            props.placedFile.common = ImportMapping.common(name: placed.name, transform: placed.transform.concatenating(placement))
            props.placedFile.content.format = .eps
            props.placedFile.content.blobSha256 = placed.blob.sha256
            props.placedFile.content.sourceName = String(name.prefix(256))
            props.placedFile.content.bounds = ImportMapping.rect(placed.bounds)
            if let preview = placed.preview {
                props.placedFile.content.previewSha256 = preview.blob.sha256
                props.placedFile.content.previewWidth = Int32(preview.width)
                props.placedFile.content.previewHeight = Int32(preview.height)
            }
            if let source { props.placedFile.source.id = source.proto }
            return builder.append(Ops.create(parent: parent, position: position, props: props))
        case .svgAnimation(let css, let smil, let script, let durationMs):
            let file = try asset(placed.blob, name: name, link: link, builder: &builder)
            let posterAsset = try poster.map { try asset($0.blob, name: "\(name) poster", link: nil, builder: &builder) }
            var props = Wiretuner_Doc_V1_NodeProps()
            let origin = AffineTransform.translation(x: placed.bounds.minX, y: placed.bounds.minY)
            props.svgAnimation.common = ImportMapping.common(name: placed.name, transform: origin.concatenating(placed.transform).concatenating(placement))
            props.svgAnimation.asset.id = file.proto
            props.svgAnimation.naturalSize.width = placed.bounds.width
            props.svgAnimation.naturalSize.height = placed.bounds.height
            props.svgAnimation.durationMs = durationMs
            props.svgAnimation.kinds.css = css
            props.svgAnimation.kinds.smil = smil
            props.svgAnimation.kinds.script = script
            if let poster, let posterAsset {
                props.svgAnimation.posterTimeMs = poster.timeMs
                props.svgAnimation.poster.id = posterAsset.proto
            }
            return builder.append(Ops.create(parent: parent, position: position, props: props))
        }
    }

    /// The `asset` node holding `blob` (created once per change), with `link` as its record.
    mutating func asset(_ blob: ImportedBlob, name: String, link: ImportLink?, builder: inout ChangeBuilder) throws -> OpID {
        if let existing = assets[blob.sha256] { return existing }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.asset.common.name = String(name.prefix(256))
        props.asset.sha256 = blob.sha256
        props.asset.byteSize = UInt64(blob.data.count)
        props.asset.mediaType = blob.mediaType
        if let link {
            props.asset.link.kind = .localFile
            props.asset.link.displayName = String(link.displayName.prefix(256))
            props.asset.link.path = String(link.path.prefix(4096))
            props.asset.link.device = String(link.device.prefix(64))
            if let modified = link.modified { props.asset.link.sourceModifiedMs = Int64((modified.timeIntervalSince1970 * 1000).rounded(.down)) }
        } else {
            props.asset.link.kind = .embedded
        }
        let lower = assetKey ?? state.store.children(WellKnown.assets).last.flatMap { state.store.placement($0)?.position }
        let key = try PathEditing.keys(between: lower, and: nil, count: 1)[0]
        assetKey = key
        let id = builder.append(Ops.create(parent: WellKnown.assets, position: key, props: props))
        assets[blob.sha256] = id
        return id
    }
}

/// The value mapping of import-formats.adoc's table: WTInterchange's neutral values to
/// `NodeProps`.
enum ImportMapping {
    // MARK: Nodes

    static func common(name: String?, transform: AffineTransform, url: String? = nil) -> Wiretuner_Doc_V1_CommonProps {
        var common = Wiretuner_Doc_V1_CommonProps()
        if let name, !name.isEmpty { common.name = String(name.prefix(256)) }
        if !transform.isIdentity { common.transform = PathEditing.proto(transform) }
        if let url, !url.isEmpty { common.url = String(url.prefix(2048)) }
        return common
    }

    static func group(_ group: ImportedGroup, placement: AffineTransform) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.common = common(name: group.name, transform: group.transform.concatenating(placement))
        props.group.kind = group.clip == nil ? .group : .clip
        if let effect = transparency(group.opacity) { props.group.appearance.effects = [effect] }
        return props
    }

    static func path(_ path: ImportedPath, placement: AffineTransform) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.common = common(name: path.name, transform: path.transform.concatenating(placement), url: path.url)
        props.path.contours = path.contours.map(contour)
        props.path.evenOdd = path.fillRule == .evenOdd
        if let fill = fill(path.fill) { props.path.appearance.fills = [fill] }
        if let stroke = path.stroke.flatMap(stroke) { props.path.appearance.strokes = [stroke] }
        if let effect = transparency(path.opacity) { props.path.appearance.effects = [effect] }
        return props
    }

    static func image(_ image: ImportedImage, source: OpID?, placement: AffineTransform) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.image.common = common(name: image.name, transform: image.transform.concatenating(placement))
        let pixels = image.pixels
        props.image.pixels.blobSha256 = pixels.blob.sha256
        props.image.pixels.format = pixels.blob.uti
        props.image.pixels.pixelWidth = Int32(clamping: pixels.width)
        props.image.pixels.pixelHeight = Int32(clamping: pixels.height)
        props.image.pixels.mode = mode(pixels.mode)
        props.image.pixels.bitsPerChannel = Int32(clamping: pixels.bitsPerChannel)
        props.image.pixels.hasAlpha_p = pixels.hasAlpha
        props.image.sourceName = String((image.name ?? "").prefix(256))
        props.image.dpiX = image.dpiX
        props.image.dpiY = image.dpiY
        if let source { props.image.source.id = source.proto }
        return props
    }

    static func mode(_ mode: ImportedColorMode) -> Wiretuner_Doc_V1_ColorMode {
        switch mode {
        case .bilevel: .bilevel
        case .grayscale: .grayscale
        case .indexed: .indexed
        case .rgb: .rgb
        case .cmyk: .cmyk
        }
    }

    static func rect(_ rect: Rect) -> Wiretuner_Doc_V1_Rect {
        var value = Wiretuner_Doc_V1_Rect()
        value.x = rect.minX
        value.y = rect.minY
        value.width = max(rect.width, 0)
        value.height = max(rect.height, 0)
        return value
    }

    // MARK: Geometry

    static func contour(_ contour: ImportedContour) -> Wiretuner_Doc_V1_Contour {
        var value = Wiretuner_Doc_V1_Contour()
        value.closed = contour.closed
        value.points = contour.pathPoints.map { point in
            var stored = Wiretuner_Doc_V1_PathPoint()
            stored.anchor = PathEditing.proto(point.anchor)
            stored.inHandle = PathEditing.proto(point.inHandle)
            stored.outHandle = PathEditing.proto(point.outHandle)
            stored.kind = point.smooth ? .curve : .corner
            return stored
        }
        return value
    }

    // MARK: Paint

    /// A `TransparencyEffect` (Basic) for an opacity below 1.
    static func transparency(_ opacity: Double) -> Wiretuner_Doc_V1_Effect? {
        guard opacity < 1 else { return nil }
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .transparency
        effect.settings.transparency.style = .basic
        effect.settings.transparency.amount = UInt32(min(max(((1 - opacity) * 100).rounded(), 0), 100))
        return effect
    }

    static func fill(_ paint: ImportedPaint) -> Wiretuner_Doc_V1_Fill? {
        var fill = Wiretuner_Doc_V1_Fill()
        switch paint {
        case .none:
            return nil
        case .solid(let color):
            fill.settings.kind = .basic
            fill.settings.basic.color = colorRef(color)
        case .gradient(let gradient):
            fill.settings.kind = .gradient
            fill.settings.gradient = self.gradient(gradient)
        }
        return fill
    }

    /// A Basic stroke; a gradient stroke paints its first stop's colour.
    static func stroke(_ stroke: ImportedStroke) -> Wiretuner_Doc_V1_Stroke? {
        guard let color = stroke.paint.representativeColor else { return nil }
        var value = Wiretuner_Doc_V1_Stroke()
        value.settings.kind = .basic
        let style = stroke.style
        value.settings.basic.color = colorRef(color)
        value.settings.basic.width = min(max(style.width, 0), 16_164)
        value.settings.basic.cap = switch style.cap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
        value.settings.basic.join = switch style.join {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
        value.settings.basic.miterLimit = min(max(style.miterLimit, 1), 57)
        if !style.dash.isEmpty { value.settings.basic.dash.lengths = Array(style.dash.prefix(8)) }
        return value
    }

    static func gradient(_ gradient: Gradient) -> Wiretuner_Doc_V1_GradientFill {
        var value = Wiretuner_Doc_V1_GradientFill()
        value.type = switch gradient.kind {
        case .linear: .linear
        case .logarithmic: .logarithmic
        case .radial: .radial
        case .rectangle: .rectangle
        case .contour: .contour
        case .cone: .cone
        }
        value.behavior = switch gradient.behavior {
        case .normal: .normal
        case .repeat: .repeat
        case .reflect: .reflect
        case .autoSize: .autoSize
        }
        value.repeatCount = UInt32(min(max(gradient.repeatCount, 1), 100))
        if let axis = gradient.axis {
            value.axis.start = PathEditing.proto(axis.start)
            value.axis.end = PathEditing.proto(axis.end)
            if let end2 = axis.end2 { value.axis.end2 = PathEditing.proto(end2) }
        }
        value.stops = gradient.stops.map { stop in
            var value = Wiretuner_Doc_V1_GradientStop()
            value.offset = min(max(stop.offset, 0), 1)
            value.color = colorRef(stop.color)
            return value
        }
        return value
    }

    static func colorRef(_ color: Color) -> Wiretuner_Doc_V1_ColorRef {
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.inline = self.color(color)
        return ref
    }

    /// A stored colour in the colour's own space (the stored colour carries no alpha).
    static func color(_ color: Color) -> Wiretuner_Doc_V1_Color {
        var value = Wiretuner_Doc_V1_Color()
        let c = color.components
        func unit(_ v: Double) -> Double { min(max(v, 0), 1) }
        switch color.space {
        case .sRGB, .displayP3:
            value.rgb.r = unit(c[0])
            value.rgb.g = unit(c[1])
            value.rgb.b = unit(c[2])
            value.space = color.space == .displayP3 ? .displayP3 : .srgb
        case .lab, .oklab:
            value.lab.l = c[0]
            value.lab.a = c[1]
            value.lab.b = c[2]
            value.space = color.space == .oklab ? .oklab : .lab
        case .cmyk:
            value.cmyk.c = unit(c[0])
            value.cmyk.m = unit(c[1])
            value.cmyk.y = unit(c[2])
            value.cmyk.k = unit(c[3])
        }
        return value
    }

    // MARK: Text

    /// The character marks of a run: font family and style (from its PostScript name), size and
    /// fill.
    static func marks(_ run: ImportedTextRun) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let (family, style) = font(run.fontName)
        var values: [Wiretuner_Doc_V1_TextMarkValue] = []
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.fontFamily = String(family.prefix(256))
        values.append(value)
        if !style.isEmpty {
            value = Wiretuner_Doc_V1_TextMarkValue()
            value.fontStyle = String(style.prefix(256))
            values.append(value)
        }
        if run.fontSize > 0 {
            value = Wiretuner_Doc_V1_TextMarkValue()
            value.size = min(run.fontSize, 10_000)
            values.append(value)
        }
        if let color = run.fill.representativeColor {
            value = Wiretuner_Doc_V1_TextMarkValue()
            value.fill = colorRef(color)
            values.append(value)
        }
        return values
    }

    /// The family and style of the installed font named `postScriptName`; a font that is not
    /// installed keeps its PostScript name as the family, for font substitution to resolve.
    static func font(_ postScriptName: String) -> (family: String, style: String) {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        guard CTFontCopyPostScriptName(font) as String == postScriptName else { return (postScriptName, "") }
        let style = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String } ?? ""
        return (CTFontCopyFamilyName(font) as String, style)
    }

    /// A `TextMark` of `value` over the characters `from` ... `to`.
    static func mark(_ node: OpID, _ field: RegisterPath, from: OpID, to: OpID, value: Wiretuner_Doc_V1_TextMarkValue) -> Wiretuner_Doc_V1_Op {
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = field.proto
        mark.start.char = Ops.elementID(from)
        mark.start.before = true
        mark.end.char = Ops.elementID(to)
        mark.end.before = false
        mark.value = value
        var op = Wiretuner_Doc_V1_Op()
        op.textMark = mark
        return op
    }
}
