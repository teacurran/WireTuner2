import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-008 and FX-014: the btn:[Add Effect] submenu items that add a raster or transparency effect in
// one of its styles (raster-effects.adoc, "To add a raster effect"; transparency.adoc), and the
// document's and an object's raster effects resolution (raster-effects.adoc, "Raster effect
// settings").

/// A style a btn:[Add Effect] submenu item adds its effect in.
public enum EffectPreset: Hashable, Sendable {
    case bevel(Wiretuner_Doc_V1_BevelStyle)
    case blur(Wiretuner_Doc_V1_BlurStyle)
    case shadow(Wiretuner_Doc_V1_ShadowStyle)
    case sharpen(Wiretuner_Doc_V1_SharpenStyle)
    case transparency(Wiretuner_Doc_V1_TransparencyStyle)

    public var kind: Wiretuner_Doc_V1_EffectKind {
        switch self {
        case .bevel: .bevelEmboss
        case .blur: .blur
        case .shadow: .shadow
        case .sharpen: .sharpen
        case .transparency: .transparency
        }
    }

    /// The kind's defaults in this style.  A glow starts in `glow` (the object's fill colour, by
    /// the guide) and a gradient mask with a black-to-white linear ramp, so it draws at once.
    public func settings(seed: UInt64, glow: Wiretuner_Doc_V1_ColorRef? = nil) -> Wiretuner_Doc_V1_EffectSettings {
        var settings = EffectDefaults.settings(kind, seed: seed)
        switch self {
        case .bevel(let style): settings.bevelEmboss.style = style
        case .blur(let style): settings.blur.style = style
        case .shadow(let style):
            settings.shadow.style = style
            if style == .glow || style == .innerGlow, let glow { settings.shadow.color = glow }
        case .sharpen(let style): settings.sharpen.style = style
        case .transparency(let style):
            settings.transparency.style = style
            if style == .gradientMask { settings.transparency.mask = EffectPreset.startingMask }
        }
        return settings
    }

    /// Black (opaque) to white (transparent), linear.
    public static var startingMask: Wiretuner_Doc_V1_GradientFill {
        var mask = Wiretuner_Doc_V1_GradientFill()
        mask.type = .linear
        mask.stops = [(0.0, Color.black), (1.0, Color.white)].map { offset, color in
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.offset = offset
            stop.color = ColorResolver.inline(color)
            return stop
        }
        return mask
    }

    /// The submenu item's name ("Drop Shadow", "Gradient Mask").
    public var title: String {
        switch self {
        case .bevel(.outerBevel): "Outer Bevel"
        case .bevel(.raisedEmboss): "Raised Emboss"
        case .bevel(.insetEmboss): "Inset Emboss"
        case .bevel: "Inner Bevel"
        case .blur(.basic): "Basic Blur"
        case .blur: "Gaussian Blur"
        case .shadow(.innerShadow): "Inner Shadow"
        case .shadow(.glow): "Glow"
        case .shadow(.innerGlow): "Inner Glow"
        case .shadow: "Drop Shadow"
        case .sharpen(.unsharpMask): "Unsharp Mask"
        case .sharpen: "Basic Sharpen"
        case .transparency(.feather): "Feather"
        case .transparency(.gradientMask): "Gradient Mask"
        case .transparency: "Basic"
        }
    }
}

/// A btn:[Add Effect] submenu item: `AddEffect` with the effect's settings in `preset`'s style.
/// Labelled "Add Drop Shadow effect".
public struct AddEffectPreset: Command {
    public var nodes: [OpID]
    public var preset: EffectPreset
    public var attachTo: [OpID: AppearanceRow]
    public var above: [OpID: AppearanceRow]

    public init(_ nodes: [OpID], preset: EffectPreset, attachTo: [OpID: AppearanceRow] = [:], above: [OpID: AppearanceRow] = [:]) {
        self.nodes = nodes
        self.preset = preset
        self.attachTo = attachTo
        self.above = above
    }

    public var label: String { "Add \(preset.title) effect" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes {
            let owner = try AppearanceEditing.owner(node, in: state)
            var effect = Wiretuner_Doc_V1_Effect()
            let glow = StackOwner.appearance(node, in: state)?.fills.last.map(\.settings.basic.color)
            effect.settings = preset.settings(seed: Seeds.next(builder), glow: glow)
            let anchor: AppearanceRow?
            if let target = attachTo[node] {
                guard target.list != .effects else { throw PathEditError.unknownPoint(target.element) }
                _ = try AppearanceEditing.owner(node, target, in: state)
                effect.attachedTo = target.element.elementID
                anchor = EffectReading.group(node, target: target, in: state).last?.row ?? target
            } else {
                anchor = above[node]
            }
            let key = try AppearanceEditing.keyAbove(node, anchor, owner: owner, state: state)
            // A mask's stops are elements of their own: inserted after the effect, into it.
            let stops = effect.settings.transparency.mask.stops
            effect.settings.transparency.mask.stops = []
            let inserted = builder.append(Ops.elementInsert(node, owner.sequence(.effects), positions: [key], values: EffectEditing.values(owner, effect)))
            guard !stops.isEmpty else { continue }
            let row = AppearanceRow(.effects, inserted)
            let keys = try PathEditing.keys(between: nil, and: nil, count: stops.count)
            var mask = Wiretuner_Doc_V1_GradientFill()
            mask.stops = stops
            builder.append(Ops.elementInsert(node, MaskEditing.stops(owner, row), positions: keys, values: MaskEditing.values(owner, mask)))
        }
    }
}

/// menu:File[Document Settings > Raster Effects…]: the document's raster effects resolution
/// (1 to 2400 ppi) and *Optimal CMYK*, one change "Change raster effects settings".
public struct ChangeRasterEffectSettings: Command {
    public static let resolution = RegisterPath([2, 90, 1])
    public static let optimalCMYK = RegisterPath([2, 90, 2])

    public var resolution: UInt32?
    public var optimalCMYK: Bool?

    public init(resolution: UInt32? = nil, optimalCMYK: Bool? = nil) {
        self.resolution = resolution
        self.optimalCMYK = optimalCMYK
    }

    public var label: String { "Change raster effects settings" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let resolution, !(1...2400).contains(resolution) { throw ObjectEditError.invalidValue("resolution") }
        var paths: [RegisterPath] = []
        if resolution != nil { paths.append(Self.resolution) }
        if optimalCMYK != nil { paths.append(Self.optimalCMYK) }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: SettingsFields.values {
            $0.rasterEffects.resolutionPpi = resolution ?? 0
            $0.rasterEffects.optimalCmyk = optimalCMYK ?? false
        }))
    }

    /// The document's settings as they read (72 ppi when never set).
    public static func read(_ state: EngineState) -> (resolution: UInt32, optimalCMYK: Bool) {
        let settings = state.props(WellKnown.settings).settings.rasterEffects
        return (settings.resolutionPpi == 0 ? 72 : settings.resolutionPpi, settings.optimalCmyk)
    }
}

/// The Object panel's *Raster Effect Settings…*: each object's own raster resolution (1 to 2400
/// ppi), or with 0 the document's again.  One change "Change raster resolution".
public struct SetObjectRasterResolution: Command {
    public var nodes: [OpID]
    public var ppi: UInt32

    public init(_ nodes: [OpID], ppi: UInt32) {
        self.nodes = nodes
        self.ppi = ppi
    }

    public var label: String { fannedLabel("Change raster resolution", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard ppi <= 2400 else { throw ObjectEditError.invalidValue("ppi") }
        for node in nodes {
            let owner = try AppearanceEditing.owner(node, in: state)
            var stack = Wiretuner_Doc_V1_AppearanceProps()
            stack.rasterDpi = ppi
            builder.append(Ops.set(node, [owner.path.child(4)], values: owner.values(stack)))
        }
    }

    /// `node`'s own resolution; 0 when it uses the document's.
    public static func read(_ node: OpID, in state: EngineState) -> UInt32 {
        StackOwner.appearance(node, in: state)?.rasterDpi ?? 0
    }
}
