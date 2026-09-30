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
    /// What the images' embedded profiles do (CMS-012; the *Embedded image profiles* preference,
    /// its *Ask* answered by the app).
    public var embeddedProfiles: EmbeddedProfilePolicy

    public init(_ scene: ImportedScene, placement: ImportPlacement, layer: OpID? = nil, link: ImportLink? = nil, poster: ImportedPoster? = nil,
                embeddedProfiles: EmbeddedProfilePolicy = .useEmbedded) {
        self.scene = scene
        self.placement = placement
        self.layer = layer
        self.link = link
        self.poster = poster
        self.embeddedProfiles = embeddedProfiles
    }

    public var label: String { scene.kind == .vector ? "Import \(scene.name)" : "Place \(scene.name)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        // Only a file placed whole has a link record; images inside a vector file have none.
        var writer = ImportWriter(state: state, link: scene.kind == .vector ? nil : link, poster: poster)
        writer.embeddedProfiles = embeddedProfiles
        try writer.prepare(scene, builder: &builder)
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

/// menu:Object[Convert to Editable] (IMG-060, import-formats.adoc "Converting a placed EPS"): a
/// placed EPS replaced by the objects `scene` holds (`EPSImporter.editable`'s conversion of its
/// PDF-compatible stream).  The scene's bounds are fitted into the placed file's natural rect,
/// then the placed node's own transform applies, so the artwork lands where the preview was; one
/// group named after the file, at the placed node's slot, then the placed node is deleted.  Blobs
/// of images inside must be stored before it runs.  One change "Convert to Editable"; refused
/// (nothing written) for anything but a live, unlocked placed file or an empty scene.
public struct ConvertPlacedFile: Command {
    public var node: OpID
    public var scene: ImportedScene
    public var label: String { "Convert to Editable" }

    public init(_ node: OpID, scene: ImportedScene) {
        self.node = node
        self.scene = scene
    }

    /// Whether `node` is a placed file Convert to Editable can replace.
    public static func accepts(_ node: OpID, in state: EngineState) -> Bool {
        state.nodeKind(node) == .placedFile && !Objects.editable([node], in: state).isEmpty
    }

    /// The placed file's natural rect (its `bounds`, 1 × 1 inch when it has no area).
    public static func natural(_ node: OpID, in state: EngineState) -> Rect {
        let bounds = state.props(node).placedFile.content.bounds
        guard bounds.width > 0, bounds.height > 0 else { return Rect(x: 0, y: 0, width: 72, height: 72) }
        return Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard Self.accepts(node, in: state), !scene.nodes.isEmpty, let parent = Objects.parent(of: node, in: state) else { return }
        let fit = ImportPlacement.fit(Self.natural(node, in: state), fillWidth: false).transform(for: scene.bounds)
        var writer = ImportWriter(state: state, link: nil, poster: nil)
        try writer.prepare(scene, builder: &builder)
        let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
        try writer.create(scene.subtree, parent: parent, position: key, placement: fit.concatenating(Objects.transform(of: node, in: state)), builder: &builder)
        builder.append(Ops.setDeleted(node))
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
    /// `PlaceImportedScene.embeddedProfiles`.
    var embeddedProfiles = EmbeddedProfilePolicy.useEmbedded
    /// Profile assets created in this change.
    private var profileAssets = ProfileAssets.Pending()
    /// The swatches and symbols the nodes refer to (`prepare(_:builder:)`).
    var references = ImportReferences()

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
            if case .instance(let key) = group.role,
               let id = instance(key, name: group.name, transform: group.transform.concatenating(placement), builder: &builder, parent: parent, position: position) {
                return id
            }
            let id = try NodeCopier.create(NodeTree(props: ImportMapping.group(group, placement: placement)), parent: parent, position: position,
                                           schema: state.schema, builder: &builder)
            var children = group.children
            var clip: ImportedPath?
            if var path = group.clip {
                if !group.clipAppearance {
                    path.fill = .none
                    path.stroke = nil
                }
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
            return try NodeCopier.create(NodeTree(props: ImportMapping.path(path, placement: placement, references: references)), parent: parent, position: position,
                                         schema: state.schema, builder: &builder)
        case .text(let text):
            return createText(text, parent: parent, position: position, placement: placement, builder: &builder)
        case .image(let image):
            let source = try link.map { try asset(image.pixels.blob, name: $0.displayName, link: $0, builder: &builder) }
            var props = ImportMapping.image(image, source: source, placement: placement)
            if let embedded = image.embeddedProfile {
                // CMS-012: the profile is recorded on the node -- its asset created unless it is
                // bundled or the document has one -- and read through as the preference says.
                let profile = ColorSettings.stored(embedded.profile)
                // One run of keys above the existing assets for every asset this change creates.
                if let assetKey { profileAssets.lastKey = assetKey }
                try ProfileAssets.ensure(profile, size: UInt64(embedded.blob?.data.count ?? 0), state: state, pending: &profileAssets, builder: &builder)
                assetKey = profileAssets.lastKey ?? assetKey
                props.image.color.embeddedProfile = profile
                props.image.color.useEmbedded = embeddedProfiles == .useEmbedded
            }
            return builder.append(Ops.create(parent: parent, position: position, props: props))
        case .placed(let placed):
            return try createPlaced(placed, parent: parent, position: position, placement: placement, builder: &builder)
        }
    }

    private func createText(_ text: ImportedText, parent: OpID, position: [UInt8], placement: AffineTransform,
                            builder: inout ChangeBuilder) -> OpID {
        let origin = text.runs.first?.origin ?? Point(x: 0, y: 0)
        var props = Wiretuner_Doc_V1_NodeProps()
        if let frame = text.frame, text.path == nil {
            // Area text: the block's origin is its rectangle's top-left corner.
            props.text.common = ImportMapping.common(name: text.name, transform: text.transform.concatenating(placement))
            props.text.block.width = min(max(frame.width.isFinite ? frame.width : 0, 0), 16_164)
            props.text.block.height = min(max(frame.height.isFinite ? frame.height : 0, 0), 16_164)
        } else if text.path != nil {
            // Text on a path: the path child is in the block's space.
            props.text.common = ImportMapping.common(name: text.name, transform: text.transform.concatenating(placement))
            props.text.onPath.mode = .along
        } else {
            props.text.common = ImportMapping.common(name: text.name, transform: AffineTransform.translation(x: origin.x, y: origin.y)
                .concatenating(text.transform).concatenating(placement))
            props.text.block.autoWidth = true
        }
        let node = builder.append(Ops.create(parent: parent, position: position, props: props))
        if var path = text.path {
            path.fill = .none
            path.stroke = nil
            path.opacity = 1
            builder.append(Ops.create(parent: node, position: [0x80], props: ImportMapping.path(path, placement: .identity)))
        }
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
            for value in ImportMapping.marks(span.run, references: references) {
                builder.append(ImportMapping.mark(node, field, from: start, to: end, value: value))
            }
        }
        if let alignment = ImportMapping.alignment(text.alignment) {
            // Every paragraph: each newline's registers and the tail's.
            var paragraph = Wiretuner_Doc_V1_ParagraphProps()
            paragraph.alignment = alignment
            for (offset, scalar) in scalars.enumerated() where scalar == "\n" {
                let newline = OpID(counter: first.counter + UInt64(offset), replica: first.replica)
                builder.append(Ops.set(node, [TextFields.paragraph(newline).child(1)], values: TextEditing.paragraphValues(paragraph, newline: true)))
            }
            builder.append(Ops.set(node, [TextFields.tailParagraph.child(1)], values: TextEditing.paragraphValues(paragraph, newline: false)))
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

    static func path(_ path: ImportedPath, placement: AffineTransform, references: ImportReferences = ImportReferences()) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.common = common(name: path.name, transform: path.transform.concatenating(placement), url: path.url)
        props.path.contours = path.contours.map(contour)
        props.path.evenOdd = path.fillRule == .evenOdd
        if let fill = fill(path.fill, references: references) { props.path.appearance.fills = [fill] }
        if let stroke = path.stroke.flatMap({ stroke($0, references: references) }) { props.path.appearance.strokes = [stroke] }
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
        // *Display alpha channel* is on by default (bitmaps.adoc, "Image properties").
        props.image.displayAlpha = true
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

    static func fill(_ paint: ImportedPaint, references: ImportReferences = ImportReferences()) -> Wiretuner_Doc_V1_Fill? {
        var fill = Wiretuner_Doc_V1_Fill()
        switch paint {
        case .none:
            return nil
        case .solid(let color):
            fill.settings.kind = .basic
            fill.settings.basic.color = colorRef(color)
        case .swatch:
            fill.settings.kind = .basic
            fill.settings.basic.color = references.colorRef(paint)!
        case .gradient(let gradient):
            fill.settings.kind = .gradient
            fill.settings.gradient = self.gradient(gradient)
        case .pattern(let pattern):
            fill.settings.kind = .pattern
            fill.settings.pattern.color = colorRef(pattern.color)
            fill.settings.pattern.bitmap = patternBitmap(pattern.bitmap)
        case .lens(let lens):
            fill.settings.kind = .lens
            fill.settings.lens = self.lens(lens)
        case .tiled(let tile):
            guard let tiled = tiled(tile, references: references) else { return nil }
            fill.settings.kind = .tiled
            fill.settings.tiled = tiled
        }
        return fill
    }

    /// A Basic stroke (a Pattern stroke for a pattern paint); a gradient stroke paints its first
    /// stop's colour, a named colour references its swatch.
    static func stroke(_ stroke: ImportedStroke, references: ImportReferences = ImportReferences()) -> Wiretuner_Doc_V1_Stroke? {
        guard let color = references.colorRef(stroke.paint) else { return nil }
        var value = Wiretuner_Doc_V1_Stroke()
        let style = stroke.style
        if case .pattern(let pattern) = stroke.paint {
            value.settings.kind = .pattern
            value.settings.pattern.color = color
            value.settings.pattern.width = min(max(style.width, 0), 16_164)
            value.settings.pattern.bitmap = patternBitmap(pattern.bitmap)
            return value
        }
        value.settings.kind = .basic
        value.settings.basic.color = color
        if let head = stroke.startArrowhead { value.settings.basic.startArrowhead = arrowhead(head) }
        if let head = stroke.endArrowhead { value.settings.basic.endArrowhead = arrowhead(head) }
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
    static func marks(_ run: ImportedTextRun, references: ImportReferences = ImportReferences()) -> [Wiretuner_Doc_V1_TextMarkValue] {
        let (family, style) = run.family.map { ($0, run.style ?? "") } ?? font(run.fontName)
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
        if let color = references.colorRef(run.fill) {
            value = Wiretuner_Doc_V1_TextMarkValue()
            value.fill = color
            values.append(value)
        }
        return values
    }

    /// The stored alignment, nil for left (the default, written as nothing).
    static func alignment(_ alignment: ImportedTextAlignment) -> Wiretuner_Doc_V1_Alignment? {
        switch alignment {
        case .left: return nil
        case .right: return .right
        case .center: return .center
        case .justify: return .justified
        }
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
