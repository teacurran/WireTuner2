import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `AnimationSettings` (`SettingsProps.animation` = 70) and `LayerFrameProps`
/// (`LayerProps.frame` = 20) (animation.adoc, "Data model").
public enum AnimationFields {
    static let settings = RegisterPath([2, 70])
    public static let source = settings.child(1)
    public static let fps = settings.child(2)
    public static let loop = settings.child(3)
    public static let noAutoplay = settings.child(4)
    public static let background = settings.child(5)
    public static let hold = RegisterPath([NodeKind.layer.rawValue, 20, 1])
    public static let excluded = RegisterPath([NodeKind.layer.rawValue, 20, 2])
}

/// The document's animation settings as read (WEB-014): an unset source reads as *None*, an fps
/// of 0 as 12, and `loop` as true while the settings message has never been written.
public struct AnimationInfo: Hashable, Sendable {
    public var source: FrameSource
    public var fps: Double
    public var loop: Bool
    public var autoplay: Bool
    /// The layers in `LayerOrder` as the frame list reads them.
    public var layers: [AnimationLayer]

    public init(_ state: EngineState, layers order: LayerOrder? = nil) {
        let settings = state.props(WellKnown.settings).settings
        let animation = settings.animation
        let sources: [Wiretuner_Doc_V1_FrameSource: FrameSource] = [.layers: .layers, .pages: .pages, .pagesAndLayers: .pagesAndLayers]
        source = sources[animation.source] ?? .none
        fps = animation.fps > 0 && animation.fps.isFinite ? min(animation.fps, 120) : FrameComposer.defaultFPS
        loop = settings.hasAnimation ? animation.loop : true
        autoplay = !animation.noAutoplay
        let order = order ?? LayerOrder(state)
        layers = order.layers.map { layer in
            let frame = state.props(layer.id).layer.frame
            return AnimationLayer(id: NodeID(layer.id), printing: layer.printing, visible: layer.visible, excluded: frame.excluded,
                                  hold: Int(frame.hold), isGuides: layer.role == .guides)
        }
    }

    /// The frame list (the `FrameList` query): for each frame, the layers shown, its page and
    /// hold, over the page rectangles `pages` (the window's pages until pages are nodes).
    public func frames(pages: [Rect] = []) -> [AnimationFrame] {
        FrameComposer.frames(source: source, layers: layers, pages: pages)
    }

    /// The live objects each frame shows (background layers' and its own, on the layers each is
    /// drawn on), bottom first.
    public func visibleNodes(of frame: AnimationFrame, in state: EngineState, layers order: LayerOrder? = nil) -> [OpID] {
        let order = order ?? LayerOrder(state)
        return frame.layers.flatMap { order.objects(on: OpID($0), in: state) }
    }

    /// The timeline for playback.
    public func timeline(pages: [Rect] = []) -> AnimationTimeline {
        AnimationTimeline(frames: frames(pages: pages), fps: fps, loop: loop)
    }
}

/// The Animation panel's settings (WEB-014): each field given, one register each, in one change
/// ("Animation Settings").  The first write also writes `loop` so an untouched document's
/// looping survives the message becoming written.
public struct SetAnimationSettings: Command {
    public var source: FrameSource?
    public var fps: Double?
    public var loop: Bool?
    public var autoplay: Bool?
    public var label: String { "Animation Settings" }

    public init(source: FrameSource? = nil, fps: Double? = nil, loop: Bool? = nil, autoplay: Bool? = nil) {
        self.source = source
        self.fps = fps
        self.loop = loop
        self.autoplay = autoplay
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let fps, !(fps.isFinite && (0.01...120).contains(fps)) { throw ObjectEditError.invalidValue("fps") }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let source {
            switch source {
            case .none: props.settings.animation.source = .none
            case .layers: props.settings.animation.source = .layers
            case .pages: props.settings.animation.source = .pages
            case .pagesAndLayers: props.settings.animation.source = .pagesAndLayers
            }
            paths.append(AnimationFields.source)
        }
        if let fps {
            props.settings.animation.fps = fps
            paths.append(AnimationFields.fps)
        }
        let written = state.props(WellKnown.settings).settings.hasAnimation
        if let loop = loop ?? (written || paths.isEmpty ? nil : true) {
            props.settings.animation.loop = loop
            paths.append(AnimationFields.loop)
        }
        if let autoplay {
            props.settings.animation.noAutoplay = !autoplay
            paths.append(AnimationFields.noAutoplay)
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }
}

/// A layer's frame fields (WEB-014): *Hold* (frame periods, 1...10,000) and *Exclude from
/// animation*, on each layer given, one change ("Frame Hold", "Exclude from Animation").
public struct SetLayerFrame: Command {
    public var layers: [OpID]
    public var hold: Int?
    public var excluded: Bool?
    public var label: String {
        if let excluded, hold == nil { return excluded ? "Exclude from Animation" : "Include in Animation" }
        return "Frame Hold"
    }

    public init(_ layers: [OpID], hold: Int? = nil, excluded: Bool? = nil) {
        self.layers = layers
        self.hold = hold
        self.excluded = excluded
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let hold, !(1...10_000).contains(hold) { throw ObjectEditError.invalidValue("hold") }
        let order = LayerOrder(state)
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        if let hold {
            props.layer.frame.hold = UInt32(hold)
            paths.append(AnimationFields.hold)
        }
        if let excluded {
            props.layer.frame.excluded = excluded
            paths.append(AnimationFields.excluded)
        }
        guard !paths.isEmpty else { return }
        for layer in layers {
            _ = try Layers.live(layer, order)
            builder.append(Ops.set(layer, paths, values: props))
        }
    }
}
