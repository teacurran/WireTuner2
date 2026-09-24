import WTCRDT
import WTGeometry
import WTProto
import WTRender

// WEB-024: the placed SVG animation node (`NodeProps.svg_animation` = 190; web/svg-animation.adoc,
// "Data model", "Merge semantics").  The SVG and its poster PNG are blobs held by asset nodes
// (0:9); the node references both.  Placing through import is `PlaceImportedScene`
// (ImportMapping.swift, WEB-025); these commands create, re-poster, set the web playback props
// and replace the file.

/// Register paths of `SvgAnimationProps`.
public enum SvgAnimationFields {
    public static let kind: UInt32 = 190
    public static let transform = RegisterPath([kind, 1, 4])
    public static let asset = RegisterPath([kind, 2])
    public static let naturalSize = RegisterPath([kind, 3])
    public static let durationMs = RegisterPath([kind, 4])
    public static let kinds = RegisterPath([kind, 5])
    public static let posterTimeMs = RegisterPath([kind, 6])
    public static let poster = RegisterPath([kind, 7])
    public static let web = RegisterPath([kind, 8])
    public static let noAutoplay = web.child(1)
    public static let loop = web.child(2)
    public static let playOnHover = web.child(3)

    /// The natural size a zero size reads as.
    public static let fallbackSize = Size(width: 320, height: 240)

    public static func values(_ build: (inout Wiretuner_Doc_V1_SvgAnimationProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.svgAnimation)
        return props
    }
}

/// Which animation mechanisms the file uses.
public struct SvgAnimationKinds: Hashable, Sendable {
    public var css: Bool
    public var smil: Bool
    public var script: Bool

    public init(css: Bool = false, smil: Bool = false, script: Bool = false) {
        self.css = css
        self.smil = smil
        self.script = script
    }

    init(_ stored: Wiretuner_Doc_V1_SvgAnimationKinds) {
        self.init(css: stored.css, smil: stored.smil, script: stored.script)
    }

    var stored: Wiretuner_Doc_V1_SvgAnimationKinds {
        var kinds = Wiretuner_Doc_V1_SvgAnimationKinds()
        kinds.css = css
        kinds.smil = smil
        kinds.script = script
        return kinds
    }
}

/// How a placed animation loops on the web.
public enum SvgAnimationLoop: Hashable, Sendable {
    case asFile
    case loop
    case once

    init(_ stored: Wiretuner_Doc_V1_LoopMode) {
        switch stored {
        case .loop: self = .loop
        case .once: self = .once
        default: self = .asFile
        }
    }

    var stored: Wiretuner_Doc_V1_LoopMode {
        switch self {
        case .asFile: .asFile
        case .loop: .loop
        case .once: .once
        }
    }
}

/// The *On the web* playback settings.
public struct SvgAnimationWeb: Hashable, Sendable {
    public var autoplay: Bool
    public var loop: SvgAnimationLoop
    public var playOnHover: Bool

    public init(autoplay: Bool = true, loop: SvgAnimationLoop = .asFile, playOnHover: Bool = false) {
        self.autoplay = autoplay
        self.loop = loop
        self.playOnHover = playOnHover
    }
}

/// What the importer read from one SVG file: everything *Replace…* rewrites at once.
public struct SvgAnimationFile: Hashable, Sendable {
    /// The asset node holding the SVG blob.
    public var asset: OpID
    public var naturalSize: Size
    /// Declared duration; 0 = indefinite.
    public var durationMs: UInt64
    public var kinds: SvgAnimationKinds
    /// The poster frame's time and the asset holding its PNG.
    public var posterTimeMs: UInt64
    public var poster: OpID?

    public init(asset: OpID, naturalSize: Size, durationMs: UInt64 = 0, kinds: SvgAnimationKinds = SvgAnimationKinds(), posterTimeMs: UInt64 = 0,
                poster: OpID? = nil) {
        self.asset = asset
        self.naturalSize = naturalSize
        self.durationMs = durationMs
        self.kinds = kinds
        self.posterTimeMs = posterTimeMs
        self.poster = poster
    }

    func write(into props: inout Wiretuner_Doc_V1_SvgAnimationProps) {
        props.asset.id = asset.proto
        props.naturalSize.width = naturalSize.width
        props.naturalSize.height = naturalSize.height
        props.durationMs = durationMs
        props.kinds = kinds.stored
        props.posterTimeMs = posterTimeMs
        if let poster { props.poster.id = poster.proto }
    }
}

/// One placed SVG animation as read, with the read-time normalizations (svg-animation.adoc): a
/// natural size of zero reads as 320 × 240, a poster time beyond a finite duration as the last
/// frame, and a dangling `asset` or `poster` as a placeholder.
public struct SvgAnimationInfo: Hashable, Sendable {
    public var node: OpID
    /// The SVG's asset, nil when it dangles (the node renders as a hatched placeholder).
    public var asset: OpID?
    /// The poster's asset, nil when unset or dangling.
    public var poster: OpID?
    public var naturalSize: Size
    public var durationMs: UInt64
    public var kinds: SvgAnimationKinds
    public var posterTimeMs: UInt64
    public var web: SvgAnimationWeb
    /// Local (natural-size points) → parent space.
    public var transform: AffineTransform

    /// The node `node` when it is a placed SVG animation.
    public init?(_ node: OpID, in state: EngineState) {
        guard state.store.kind(node) == SvgAnimationFields.kind else { return nil }
        let props = state.props(node).svgAnimation
        self.node = node
        func live(_ ref: Wiretuner_Doc_V1_NodeRef, _ has: Bool) -> OpID? {
            guard has else { return nil }
            let id = OpID(ref.id)
            return state.isLive(id) && state.store.kind(id) == AssetFields.kind ? id : nil
        }
        asset = live(props.asset, props.hasAsset)
        poster = live(props.poster, props.hasPoster)
        let size = props.naturalSize
        naturalSize = size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite
            ? Size(width: size.width, height: size.height) : SvgAnimationFields.fallbackSize
        durationMs = props.durationMs
        kinds = SvgAnimationKinds(props.kinds)
        posterTimeMs = durationMs > 0 ? min(props.posterTimeMs, durationMs) : props.posterTimeMs
        web = SvgAnimationWeb(autoplay: !props.web.noAutoplay, loop: SvgAnimationLoop(props.web.loop), playOnHover: props.web.playOnHover)
        transform = props.common.hasTransform ? PathEditing.transform(props.common.transform) : .identity
    }

    /// Whether the node draws a placeholder (the SVG's asset is gone).
    public var isPlaceholder: Bool { asset == nil }

    /// The natural-size rectangle in the node's local space.
    public var bounds: Rect { Rect(x: 0, y: 0, width: naturalSize.width, height: naturalSize.height) }
}

/// Why an SVG animation command refused.
public enum SvgAnimationError: Error, Hashable, Sendable {
    /// The node is not a placed SVG animation.
    case notAnAnimation(OpID)
    /// The node is not an asset node.
    case notAnAsset(OpID)
    case invalidValue(String)
}

enum SvgAnimationEditing {
    static func check(_ node: OpID, in state: EngineState) throws {
        guard state.store.exists(node), state.store.kind(node) == SvgAnimationFields.kind else { throw SvgAnimationError.notAnAnimation(node) }
    }

    static func checkAsset(_ node: OpID?, in state: EngineState) throws {
        guard let node else { return }
        guard state.store.exists(node), state.store.kind(node) == AssetFields.kind else { throw SvgAnimationError.notAnAsset(node) }
    }

    static func check(_ file: SvgAnimationFile, in state: EngineState) throws {
        try checkAsset(file.asset, in: state)
        try checkAsset(file.poster, in: state)
        let size = file.naturalSize
        guard size.width >= 0, size.height >= 0, size.width.isFinite, size.height.isFinite else { throw SvgAnimationError.invalidValue("naturalSize") }
    }
}

// MARK: - Commands

/// Places an SVG animation whose blobs are already held by asset nodes: one `svg_animation` node
/// on `layer` (the drawing layer when nil) at the top, `transform` mapping its natural size to
/// the pasteboard.  "Place SVG animation".
public struct CreateSvgAnimation: Command {
    public var file: SvgAnimationFile
    public var transform: AffineTransform
    public var name: String
    public var web: SvgAnimationWeb
    public var layer: OpID?
    public var label: String { "Place SVG animation" }

    public init(_ file: SvgAnimationFile, transform: AffineTransform = .identity, name: String = "", web: SvgAnimationWeb = SvgAnimationWeb(), layer: OpID? = nil) {
        self.file = file
        self.transform = transform
        self.name = name
        self.web = web
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try SvgAnimationEditing.check(file, in: state)
        let order = LayerOrder(state)
        guard let layer = layer ?? order.drawingLayer ?? order.defaultLayer else { throw LayerError.notALayer(WellKnown.layers) }
        _ = try Layers.ordinary(layer, order)
        let props = SvgAnimationFields.values { animation in
            file.write(into: &animation)
            animation.common.name = String(name.prefix(256))
            if !transform.isIdentity { animation.common.transform = PathEditing.proto(transform) }
            animation.web.noAutoplay = !web.autoplay
            if web.loop != .asFile { animation.web.loop = web.loop.stored }
            animation.web.playOnHover = web.playOnHover
        }
        builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
    }
}

/// Sets the poster frame: `poster_time_ms` and `poster` in one `SetFields`, so both registers
/// carry the same OpId and a concurrent poster change wins or loses them together.  "Poster
/// Frame".
public struct SetSvgAnimationPoster: Command {
    public var node: OpID
    public var timeMs: UInt64
    public var poster: OpID
    public var label: String { "Poster Frame" }

    public init(_ node: OpID, timeMs: UInt64, poster: OpID) {
        self.node = node
        self.timeMs = timeMs
        self.poster = poster
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try SvgAnimationEditing.check(node, in: state)
        try SvgAnimationEditing.checkAsset(poster, in: state)
        let values = SvgAnimationFields.values {
            $0.posterTimeMs = timeMs
            $0.poster.id = poster.proto
        }
        builder.append(Ops.set(node, [SvgAnimationFields.posterTimeMs, SvgAnimationFields.poster], values: values))
    }
}

/// The *On the web* controls: each given setting on each node, one register each.  "SVG Animation
/// Playback".
public struct SetSvgAnimationWeb: Command {
    public var nodes: [OpID]
    public var autoplay: Bool?
    public var loop: SvgAnimationLoop?
    public var playOnHover: Bool?
    public var label: String { "SVG Animation Playback" }

    public init(_ nodes: [OpID], autoplay: Bool? = nil, loop: SvgAnimationLoop? = nil, playOnHover: Bool? = nil) {
        self.nodes = nodes
        self.autoplay = autoplay
        self.loop = loop
        self.playOnHover = playOnHover
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var paths: [RegisterPath] = []
        let values = SvgAnimationFields.values { animation in
            if let autoplay {
                animation.web.noAutoplay = !autoplay
                paths.append(SvgAnimationFields.noAutoplay)
            }
            if let loop {
                animation.web.loop = loop.stored
                paths.append(SvgAnimationFields.loop)
            }
            if let playOnHover {
                animation.web.playOnHover = playOnHover
                paths.append(SvgAnimationFields.playOnHover)
            }
        }
        guard !paths.isEmpty else { return }
        for node in nodes { try SvgAnimationEditing.check(node, in: state) }
        for node in Set(nodes).sorted() {
            builder.append(Ops.set(node, paths, values: values))
        }
    }
}

/// btn:[Replace…]: points the node at another file -- `asset`, `natural_size`, `duration_ms`,
/// `kinds`, `poster_time_ms` and `poster` in one `SetFields` -- keeping its transform and web
/// settings (independent registers, so a concurrent move survives).  "Replace SVG animation".
public struct ReplaceSvgAnimation: Command {
    public var node: OpID
    public var file: SvgAnimationFile
    public var label: String { "Replace SVG animation" }

    public init(_ node: OpID, with file: SvgAnimationFile) {
        self.node = node
        self.file = file
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try SvgAnimationEditing.check(node, in: state)
        try SvgAnimationEditing.check(file, in: state)
        let paths = [SvgAnimationFields.asset, SvgAnimationFields.naturalSize, SvgAnimationFields.durationMs, SvgAnimationFields.kinds,
                     SvgAnimationFields.posterTimeMs, SvgAnimationFields.poster]
        builder.append(Ops.set(node, paths, values: SvgAnimationFields.values { file.write(into: &$0) }))
    }
}
