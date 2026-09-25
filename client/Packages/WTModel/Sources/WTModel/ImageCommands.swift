import WTCRDT
import WTGeometry
import WTProto
import WTRender

// IMG-003: image node commands (importing.adoc "Data model", "Merge semantics"; bitmaps.adoc
// "Data model").  Every command is one change with a readable label; undo is the engine's
// inverse of that change.  `ImageNodes` reads a node the way the scene draws it (IMG-004's
// `ImageItem`), with the read-time normalizations.

/// Register paths of `ImageProps` (kind `image` = 170).
public enum ImageFields {
    public static let kind = NodeKind.image.rawValue
    public static let transform = RegisterPath([kind, 1, 4])
    /// `pixels`: one ATOMIC register (blob, format, size, mode, depth and alpha together).
    public static let pixels = RegisterPath([kind, 2])
    public static let sourceName = RegisterPath([kind, 3])
    public static let dpiX = RegisterPath([kind, 4])
    public static let dpiY = RegisterPath([kind, 5])
    public static let displayAlpha = RegisterPath([kind, 6])
    public static let transparentBackground = RegisterPath([kind, 7])
    public static let ramp = RegisterPath([kind, 8])
    public static let tint = RegisterPath([kind, 9])
    public static let crop = RegisterPath([kind, 10])
    public static let source = RegisterPath([kind, 12])

    /// A sparse `NodeProps` whose `ImageProps` `build` fills.
    public static func values(_ build: (inout Wiretuner_Doc_V1_ImageProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.image)
        return props
    }
}

/// Why an image command refused.
public enum ImageEditError: Error, Hashable, Sendable {
    /// The node is not a live, editable image.
    case notAnImage(OpID)
    /// A value the schema's validators reject (named by field).
    case invalidValue(String)
}

/// Reading image nodes as the renderers draw them.
public enum ImageNodes {
    /// WTRender's mode for a stored `ColorMode` (unset reads as RGB).
    public static func mode(_ stored: Wiretuner_Doc_V1_ColorMode) -> ImageMode {
        switch stored {
        case .bilevel: .bilevel
        case .grayscale: .grayscale
        case .indexed: .indexed
        case .cmyk: .cmyk
        default: .rgb
        }
    }

    /// The stored `ColorMode` of WTRender's mode.
    public static func stored(_ mode: ImageMode) -> Wiretuner_Doc_V1_ColorMode {
        switch mode {
        case .bilevel: .bilevel
        case .grayscale: .grayscale
        case .indexed: .indexed
        case .rgb: .rgb
        case .cmyk: .cmyk
        }
    }

    /// WTRender's gray ramp for a stored one (unset reads as Normal; Custom with both values 0
    /// reads as Normal through `GrayRamp.effectivePreset`).
    public static func ramp(_ stored: Wiretuner_Doc_V1_GrayRamp) -> GrayRamp {
        let preset: GrayRamp.Preset
        switch stored.preset {
        case .inverted: preset = .inverted
        case .lighten: preset = .lighten
        case .darken: preset = .darken
        case .custom: preset = .custom
        default: preset = .normal
        }
        return GrayRamp(preset: preset, lightness: Int(stored.lightness), contrast: Int(stored.contrast))
    }

    /// The stored form of `ramp`.
    public static func stored(_ ramp: GrayRamp) -> Wiretuner_Doc_V1_GrayRamp {
        var value = Wiretuner_Doc_V1_GrayRamp()
        switch ramp.preset {
        case .normal: value.preset = .normal
        case .inverted: value.preset = .inverted
        case .lighten: value.preset = .lighten
        case .darken: value.preset = .darken
        case .custom: value.preset = .custom
        }
        value.lightness = Int32(ramp.lightness)
        value.contrast = Int32(ramp.contrast)
        return value
    }

    /// The blob of `pixels` as an asset id (lower-case hex SHA-256); empty when unset.
    public static func assetID(_ pixels: Wiretuner_Doc_V1_PixelSource) -> String {
        PlacedFiles.hex(pixels.blobSha256)
    }

    /// The natural frame of `props` in local space (dpi 0 reads as 72).
    public static func naturalRect(_ props: Wiretuner_Doc_V1_ImageProps) -> Rect {
        ImageItem.naturalRect(pixelWidth: Int(props.pixels.pixelWidth), pixelHeight: Int(props.pixels.pixelHeight), dpiX: props.dpiX, dpiY: props.dpiY)
    }

    /// The display item of an image node's `props` under `transform` (the node's own): the
    /// natural frame, crop, mode and alpha flags, ramp, the tint resolved (`Appearances.color`:
    /// through the build's `ColorResolver` while a scene is built), the source profile the image
    /// names and its intent, and the name the placeholder shows.  The mode-gated fields are
    /// dropped by WTRender's treatment on colour images.  An image whose blob is unset draws the
    /// empty placeholder over its (possibly empty) natural frame.
    public static func item(_ props: Wiretuner_Doc_V1_ImageProps, transform: AffineTransform,
                            registry: WTColor.ProfileRegistry = .shared) -> ImageItem {
        let pixels = props.pixels
        let crop = props.hasCrop ? Rect(x: props.crop.x, y: props.crop.y, width: props.crop.width, height: props.crop.height) : nil
        let color = props.color
        let profile: WTColor.ProfileRef?
        if color.useEmbedded, color.hasEmbeddedProfile {
            profile = ColorSettings.profile(color.embeddedProfile, registry: registry)
        } else if color.hasSourceProfile {
            profile = ColorSettings.profile(color.sourceProfile, registry: registry)
        } else {
            profile = nil
        }
        return ImageItem(
            assetID: assetID(pixels), rect: naturalRect(props), transform: transform, crop: crop, mode: mode(pixels.mode),
            hasAlpha: pixels.hasAlpha_p, displayAlpha: props.displayAlpha, transparentBackground: props.transparentBackground,
            ramp: ramp(props.ramp), tint: props.hasTint ? Appearances.color(props.tint) : nil, sourceProfile: profile,
            intent: color.intent == .unspecified ? nil : ColorSettings.intent(color.intent),
            name: props.sourceName.isEmpty ? props.common.name : props.sourceName
        )
    }

    /// The poster frame of placed SVG animation `node` under `transform` (WEB-026): the poster
    /// asset's PNG drawn like an image over the natural size (320 × 240 when unset), with the
    /// play glyph on the canvas.  With no live poster (not rendered yet, or its asset gone) the
    /// asset id is empty and the image placeholder draws.  Nil when `node` is not one.
    public static func poster(_ node: OpID, transform: AffineTransform, in state: EngineState) -> ImageItem? {
        guard let info = SvgAnimationInfo(node, in: state) else { return nil }
        let hash = info.poster.map { PlacedFiles.hex(state.props($0).asset.sha256) } ?? ""
        return ImageItem(assetID: hash, rect: info.bounds, transform: transform, mode: .rgb, hasAlpha: true, displayAlpha: true,
                         name: state.props(node).svgAnimation.common.name, showsPlayGlyph: true)
    }

    // MARK: Validation (the schema's rules, image.proto)

    static func check(_ pixels: Wiretuner_Doc_V1_PixelSource) throws {
        guard pixels.blobSha256.count == 32 else { throw ImageEditError.invalidValue("pixels.blob_sha256") }
        guard pixels.format.count <= 128 else { throw ImageEditError.invalidValue("pixels.format") }
        guard pixels.pixelWidth > 0, pixels.pixelHeight > 0 else { throw ImageEditError.invalidValue("pixels.size") }
        guard [1, 8, 16].contains(pixels.bitsPerChannel) else { throw ImageEditError.invalidValue("pixels.bits_per_channel") }
        guard pixels.mode != .unspecified, Wiretuner_Doc_V1_ColorMode.allCases.contains(pixels.mode) else {
            throw ImageEditError.invalidValue("pixels.mode")
        }
    }

    static func check(dpi: Double) throws {
        guard dpi > 0, dpi.isFinite else { throw ImageEditError.invalidValue("dpi") }
    }

    static func check(crop: Rect) throws {
        guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= 1, crop.maxY <= 1, crop.width > 0, crop.height > 0 else {
            throw ImageEditError.invalidValue("crop")
        }
    }

    static func check(ramp: GrayRamp) throws {
        guard (-100...100).contains(ramp.lightness), (-100...100).contains(ramp.contrast) else { throw ImageEditError.invalidValue("ramp") }
    }

    /// The editable images of `nodes`, or throws naming the first that is not one.
    static func editable(_ nodes: [OpID], in state: EngineState) throws -> [OpID] {
        let editable = Objects.editable(nodes, in: state)
        for node in nodes where state.nodeKind(node) != .image || !editable.contains(node) {
            throw ImageEditError.notAnImage(node)
        }
        return editable
    }

    /// "<verb>" for one image, "<verb> (N images)" for more.
    static func label(_ verb: String, count: Int) -> String {
        count == 1 ? verb : "\(verb) (\(count) images)"
    }
}

/// Places an image (importing.adoc, "Client": placement writes one change per file): a
/// `CreateNode` of the image on top of `layer` (the drawing layer by default) with its pixel
/// source, name (`CommonProps.name` and `source_name`), stored resolution, `transform`, the link
/// record's asset when the file is linked, and *Display alpha channel* on (the Object panel's
/// default).  "Place <name>".
public struct PlaceImage: Command {
    public var pixels: Wiretuner_Doc_V1_PixelSource
    public var name: String
    public var dpiX: Double
    public var dpiY: Double
    public var transform: AffineTransform
    public var source: OpID?
    public var layer: OpID?
    public var label: String { name.isEmpty ? "Place Image" : "Place \(name)" }

    public init(_ pixels: Wiretuner_Doc_V1_PixelSource, name: String = "", dpiX: Double = 72, dpiY: Double = 72,
                transform: AffineTransform = .identity, source: OpID? = nil, layer: OpID? = nil) {
        self.pixels = pixels
        self.name = name
        self.dpiX = dpiX
        self.dpiY = dpiY
        self.transform = transform
        self.source = source
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try ImageNodes.check(pixels)
        try ImageNodes.check(dpi: dpiX)
        try ImageNodes.check(dpi: dpiY)
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        let props = ImageFields.values { image in
            let stored = String(name.prefix(256))
            image.common.name = stored
            if !transform.isIdentity { image.common.transform = PathEditing.proto(transform) }
            image.pixels = pixels
            image.sourceName = stored
            image.dpiX = dpiX
            image.dpiY = dpiY
            image.displayAlpha = true
            if let source { image.source.id = source.proto }
        }
        builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
    }
}

/// Replaces an image's pixels (an external edit, *Transparent image*, Optimize Image): the ATOMIC
/// `pixels` register, and `dpi_x`/`dpi_y` recomputed so the placed bounds stay where they are when
/// the pixel dimensions change; `source_name` too when `name` is given.  One `SetFields`, so a
/// concurrent crop (unit space) still applies to the new picture.  "Replace Pixels".
public struct ReplaceImagePixels: Command {
    public var node: OpID
    public var pixels: Wiretuner_Doc_V1_PixelSource
    public var name: String?
    public var label: String { "Replace Pixels" }

    public init(_ node: OpID, pixels: Wiretuner_Doc_V1_PixelSource, name: String? = nil) {
        self.node = node
        self.pixels = pixels
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ImageNodes.editable([node], in: state)
        try ImageNodes.check(pixels)
        let natural = ImageNodes.naturalRect(state.props(node).image)
        // An image with no natural size yet (unset pixels) keeps the new pixels at 72 ppi.
        let dpiX = natural.width > 0 ? Double(pixels.pixelWidth) / natural.width * 72 : 72
        let dpiY = natural.height > 0 ? Double(pixels.pixelHeight) / natural.height * 72 : 72
        var paths = [ImageFields.pixels, ImageFields.dpiX, ImageFields.dpiY]
        if name != nil { paths.append(ImageFields.sourceName) }
        let values = ImageFields.values { image in
            image.pixels = pixels
            image.dpiX = dpiX
            image.dpiY = dpiY
            if let name { image.sourceName = String(name.prefix(256)) }
        }
        builder.append(Ops.set(node, paths, values: values))
    }
}

/// The Object panel's *Stored* resolution: `dpi_x` and `dpi_y` in one `SetFields` (both with the
/// lock on; one of them by passing nil for the other).  The natural size changes, the pixels do
/// not.  "Set Resolution".
public struct SetImageResolution: Command {
    public var nodes: [OpID]
    public var dpiX: Double?
    public var dpiY: Double?
    public var label: String { ImageNodes.label("Set Resolution", count: nodes.count) }

    public init(_ nodes: [OpID], dpiX: Double?, dpiY: Double?) {
        self.nodes = nodes
        self.dpiX = dpiX
        self.dpiY = dpiY
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let targets = try ImageNodes.editable(nodes, in: state)
        var paths: [RegisterPath] = []
        if let dpiX {
            try ImageNodes.check(dpi: dpiX)
            paths.append(ImageFields.dpiX)
        }
        if let dpiY {
            try ImageNodes.check(dpi: dpiY)
            paths.append(ImageFields.dpiY)
        }
        guard !paths.isEmpty else { return }
        let values = ImageFields.values { image in
            image.dpiX = dpiX ?? 0
            image.dpiY = dpiY ?? 0
        }
        for node in targets { builder.append(Ops.set(node, paths, values: values)) }
    }
}

/// One of the image's display settings, each an independent register (bitmaps.adoc, "Merge
/// semantics"): *Display alpha channel*, *Transparent*, the gray ramp, the tint (the fill row of
/// a bilevel or grayscale image) and the crop.  A nil ramp, tint or crop clears the register
/// (Normal, no tint, uncropped).  Mode-gated settings are written on any image -- the read-time
/// rule ignores them on colour images -- so a later pixel replacement with a gray image shows
/// them.  One change per call.
public struct SetImageSetting: Command {
    public enum Setting: Hashable, Sendable {
        case displayAlpha(Bool)
        case transparentBackground(Bool)
        case ramp(GrayRamp?)
        case tint(Wiretuner_Doc_V1_ColorRef?)
        case crop(Rect?)
    }

    public var nodes: [OpID]
    public var setting: Setting
    public var label: String {
        let verb: String
        switch setting {
        case .displayAlpha(let on): verb = on ? "Display Alpha Channel" : "Hide Alpha Channel"
        case .transparentBackground(let on): verb = on ? "Transparent" : "Opaque Background"
        case .ramp(let ramp): verb = ramp == nil ? "Reset Ramp" : "Edit Ramp"
        case .tint(let tint): verb = tint == nil ? "Remove Tint" : "Tint"
        case .crop(let crop): verb = crop == nil ? "Remove Crop" : "Crop"
        }
        return ImageNodes.label(verb, count: nodes.count)
    }

    public init(_ nodes: [OpID], _ setting: Setting) {
        self.nodes = nodes
        self.setting = setting
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let targets = try ImageNodes.editable(nodes, in: state)
        let path: RegisterPath
        let values: Wiretuner_Doc_V1_NodeProps
        switch setting {
        case .displayAlpha(let on):
            path = ImageFields.displayAlpha
            values = ImageFields.values { $0.displayAlpha = on }
        case .transparentBackground(let on):
            path = ImageFields.transparentBackground
            values = ImageFields.values { $0.transparentBackground = on }
        case .ramp(let ramp):
            if let ramp { try ImageNodes.check(ramp: ramp) }
            path = ImageFields.ramp
            values = ImageFields.values { image in
                if let ramp { image.ramp = ImageNodes.stored(ramp) }
            }
        case .tint(let tint):
            path = ImageFields.tint
            values = ImageFields.values { image in
                if let tint { image.tint = tint }
            }
        case .crop(let crop):
            if let crop { try ImageNodes.check(crop: crop) }
            path = ImageFields.crop
            values = ImageFields.values { image in
                if let crop {
                    image.crop.x = crop.minX
                    image.crop.y = crop.minY
                    image.crop.width = crop.width
                    image.crop.height = crop.height
                }
            }
        }
        for node in targets { builder.append(Ops.set(node, [path], values: values)) }
    }
}
