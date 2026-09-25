import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-014: editing a Gradient Mask transparency effect's gradient (transparency.adoc, "Gradient
// mask"): its type and its stops, each stop an element of the mask's stops SEQUENCE so concurrent
// stop edits merge individually as they do in gradient fills.  Only a stop's gray value matters;
// stops are written as inline grays.

/// The registers of a transparency effect's mask.
enum MaskEditing {
    /// `EffectSettings.transparency` and `TransparencyEffect.mask`; the mask's `type` and `stops`.
    static let transparencyField: UInt32 = 24
    static let maskField: UInt32 = 5
    static let typeField: UInt32 = 1
    static let stopsField: UInt32 = 5

    /// The transparency effect `row` of `node` and its owner, or throws.
    static func effect(_ node: OpID, _ row: AppearanceRow, in state: EngineState) throws -> (owner: StackOwner, effect: Wiretuner_Doc_V1_Effect) {
        let (owner, effect) = try EffectEditing.effect(node, row, in: state)
        guard effect.settings.kind == .transparency else { throw ObjectEditError.invalidValue("kind") }
        return (owner, effect)
    }

    static func mask(_ owner: StackOwner, _ row: AppearanceRow) -> RegisterPath {
        EffectEditing.element(owner, row.element).child(AppearanceList.effects.settingsField).appending([transparencyField, maskField])
    }

    static func stops(_ owner: StackOwner, _ row: AppearanceRow) -> RegisterPath { mask(owner, row).child(stopsField) }

    static func values(_ owner: StackOwner, _ mask: Wiretuner_Doc_V1_GradientFill) -> Wiretuner_Doc_V1_NodeProps {
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.transparency.mask = mask
        return EffectEditing.values(owner, effect)
    }

    static func stop(offset: Double? = nil, gray: Double? = nil) -> Wiretuner_Doc_V1_GradientStop {
        var stop = Wiretuner_Doc_V1_GradientStop()
        if let offset { stop.offset = min(max(offset, 0), 1) }
        if let gray { stop.color = ColorResolver.inline(Color(white: min(max(gray, 0), 1))) }
        return stop
    }

    /// Inserts stops after the ramp's last one.
    static func insert(_ stops: [(offset: Double, gray: Double)], node: OpID, owner: StackOwner, row: AppearanceRow, state: EngineState,
                       builder: inout ChangeBuilder) throws {
        let sequence = self.stops(owner, row)
        let last = state.liveElements(node, sequence).last.flatMap { state.position(node, sequence, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: stops.count)
        var mask = Wiretuner_Doc_V1_GradientFill()
        mask.stops = stops.map { stop(offset: $0.offset, gray: $0.gray) }
        builder.append(Ops.elementInsert(node, sequence, positions: keys, values: values(owner, mask)))
    }

    /// The stop `stop` of the effect's mask ramp, or throws.
    static func index(_ stop: OpID, in effect: Wiretuner_Doc_V1_Effect) throws -> (index: Int, ramp: [GradientRampStop]) {
        let ramp = MaskReading.ramp(effect)
        guard let index = ramp.firstIndex(where: { $0.id == stop }) else { throw PathEditError.unknownPoint(stop) }
        return (index, ramp)
    }
}

/// Reading a transparency effect's mask.
public enum MaskReading {
    /// The mask's stops in ramp order.
    public static func ramp(_ effect: Wiretuner_Doc_V1_Effect) -> [GradientRampStop] {
        GradientReading.ramp(effect.settings.transparency.mask)
    }

    /// The gray a stop's colour stands for (0 black, 1 white): its luminance.
    public static func gray(_ color: Wiretuner_Doc_V1_ColorRef, in state: EngineState) -> Double {
        guard let resolved = ColorResolver(state).color(color) else { return 0 }
        let rgb = resolved.srgb
        return 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
    }
}

/// Choosing *Gradient Mask* for transparency effects: the style, and a black-to-white linear ramp
/// on each mask that has no stops yet, so it draws at once.  Labelled "Change transparency".
public struct ChooseGradientMask: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]

    public init(_ rows: [(node: OpID, row: AppearanceRow)]) {
        self.rows = rows
    }

    public var label: String { fannedLabel("Change transparency", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let (owner, effect) = try MaskEditing.effect(node, row, in: state)
            var settings = Wiretuner_Doc_V1_EffectSettings()
            settings.transparency.style = .gradientMask
            builder.append(EffectEditing.set(node, owner, row, fields: [[MaskEditing.transparencyField, 1]], settings: settings))
            guard MaskReading.ramp(effect).isEmpty else { continue }
            var mask = Wiretuner_Doc_V1_GradientFill()
            mask.type = .linear
            builder.append(Ops.set(node, [MaskEditing.mask(owner, row).child(MaskEditing.typeField)], values: MaskEditing.values(owner, mask)))
            try MaskEditing.insert([(0, 0), (1, 1)], node: node, owner: owner, row: row, state: state, builder: &builder)
        }
    }
}

/// The mask's gradient type (linear, radial, …).  Labelled "Change mask type".
public struct SetMaskGradientType: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var type: Wiretuner_Doc_V1_GradientType

    public init(_ rows: [(node: OpID, row: AppearanceRow)], type: Wiretuner_Doc_V1_GradientType) {
        self.rows = rows
        self.type = type
    }

    public var label: String { fannedLabel("Change mask type", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let (owner, _) = try MaskEditing.effect(node, row, in: state)
            var mask = Wiretuner_Doc_V1_GradientFill()
            mask.type = type
            builder.append(Ops.set(node, [MaskEditing.mask(owner, row).child(MaskEditing.typeField)], values: MaskEditing.values(owner, mask)))
        }
    }
}

/// A stop added to the mask ramp at `offset` in `gray`.  Labelled "Add mask stop".
public struct AddMaskStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var offset: Double
    public var gray: Double

    public init(node: OpID, row: AppearanceRow, offset: Double, gray: Double) {
        self.node = node
        self.row = row
        self.offset = offset
        self.gray = gray
    }

    public var label: String { "Add mask stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard offset.isFinite, gray.isFinite else { throw ObjectEditError.invalidValue("stop") }
        let (owner, _) = try MaskEditing.effect(node, row, in: state)
        try MaskEditing.insert([(offset, gray)], node: node, owner: owner, row: row, state: state, builder: &builder)
    }
}

/// A mask stop's offset or gray (either, or both): its ATOMIC registers.  Labelled "Change mask stop".
public struct EditMaskStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID
    public var offset: Double?
    public var gray: Double?

    public init(node: OpID, row: AppearanceRow, stop: OpID, offset: Double? = nil, gray: Double? = nil) {
        self.node = node
        self.row = row
        self.stop = stop
        self.offset = offset
        self.gray = gray
    }

    public var label: String { "Change mask stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard offset?.isFinite != false, gray?.isFinite != false else { throw ObjectEditError.invalidValue("stop") }
        let (owner, effect) = try MaskEditing.effect(node, row, in: state)
        _ = try MaskEditing.index(stop, in: effect)
        let element = MaskEditing.stops(owner, row).element(stop)
        var paths: [RegisterPath] = []
        if offset != nil { paths.append(element.child(GradientFields.stopOffset)) }
        if gray != nil { paths.append(element.child(GradientFields.stopColor)) }
        guard !paths.isEmpty else { return }
        var mask = Wiretuner_Doc_V1_GradientFill()
        mask.stops = [MaskEditing.stop(offset: offset, gray: gray)]
        builder.append(Ops.set(node, paths, values: MaskEditing.values(owner, mask)))
    }
}

/// A mask stop removed; the ramp keeps at least two.  Labelled "Remove mask stop".
public struct RemoveMaskStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID

    public init(node: OpID, row: AppearanceRow, stop: OpID) {
        self.node = node
        self.row = row
        self.stop = stop
    }

    public var label: String { "Remove mask stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (owner, effect) = try MaskEditing.effect(node, row, in: state)
        let (_, ramp) = try MaskEditing.index(stop, in: effect)
        guard ramp.count > 2 else { throw ObjectEditError.invalidValue("stop") }
        builder.append(Ops.elementDelete(node, [MaskEditing.stops(owner, row).element(stop)]))
    }
}
