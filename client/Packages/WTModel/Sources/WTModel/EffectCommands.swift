import WTCRDT
import WTProto
import WTRender

// FX-002: the effect stack commands (docs/_includes/effects/live-effects.adoc, "Effects in the
// Object panel", "Merge semantics", "Undo").  Effects are elements of `AppearanceProps.effects`
// sharing one position space with the fills and strokes; `attached_to` names the fill or stroke
// an effect applies to, unset for the object level.

/// Where an effect applies, as the stack reads it (live-effects.adoc, "Read-time
/// normalizations"): the object, one live fill or stroke, or nowhere -- an `attached_to` naming
/// an element that is deleted or is not a fill or stroke of this stack reads as unset and the
/// effect is skipped exactly as that element is.
public enum EffectAttachment: Hashable, Sendable {
    case object
    case element(AppearanceRow)
    case skipped
}

/// One effect of a stack as the Object panel reads it.
public struct EffectEntry: Hashable, Sendable {
    public var row: AppearanceRow
    public var effect: Wiretuner_Doc_V1_Effect
    public var attachment: EffectAttachment

    /// The kind, nil for an unset or unknown one (a newer client's).
    public var kind: Wiretuner_Doc_V1_EffectKind? {
        EffectNames.isKnown(effect.settings.kind) ? effect.settings.kind : nil
    }

    /// What the list shows: the kind's name, "Unsupported effect (update WireTuner)" for an
    /// unknown kind.
    public var title: String {
        kind.map(AttributeNames.effectKind) ?? EffectNames.unsupported
    }
}

/// Reading the effects of a stack.
public enum EffectReading {
    /// Every live effect of `node` in stack order (first applied first), with its attachment.
    public static func entries(_ node: OpID, in state: EngineState) -> [EffectEntry] {
        guard let stored = StackOwner.appearance(node, in: state), let owner = StackOwner.of(node, in: state) else { return [] }
        let appearance = completingSets(stored, owner: owner, node: node, in: state)
        let stack = AppearanceEditing.stack(node, in: state)
        let effects = Dictionary(appearance.effects.map { (Self.id($0.id), $0) }) { first, _ in first }
        return stack.filter { $0.list == .effects }.compactMap { row in
            effects[row.element].map { EffectEntry(row: row, effect: $0, attachment: attachment($0, stack: stack)) }
        }
    }

    /// An object's `props` with each Corners effect's `points` SET read in: a typed read
    /// (`EngineState.props`) holds registers and sequences only.  Returned unchanged when the
    /// object's stack has no Corners effect.
    public static func completingSets(_ props: Wiretuner_Doc_V1_NodeProps, node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_NodeProps {
        guard case .object(let kind)? = StackOwner.of(node, in: state), let appearance = NodeValues.appearance(props),
              appearance.effects.contains(where: { $0.settings.kind == .corners }) else { return props }
        return NodeValues.replacing(completingSets(appearance, owner: .object(kind), node: node, in: state), of: kind, in: props)
    }

    /// The element id an `ElementId` names (the zero id for an unset one).
    static func id(_ element: Wiretuner_Doc_V1_ElementId) -> OpID {
        OpID(counter: element.counter, replica: element.replica)
    }

    static func completingSets(_ appearance: Wiretuner_Doc_V1_AppearanceProps, owner: StackOwner, node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_AppearanceProps {
        var result = appearance
        for index in result.effects.indices where result.effects[index].settings.kind == .corners {
            let path = EffectEditing.element(owner, id(result.effects[index].id)).child(AppearanceList.effects.settingsField).appending(EffectFields.field(.corners, 3))
            result.effects[index].settings.corners.points = state.store.members(node, path).compactMap(elementID)
        }
        return result
    }

    /// An `ElementId` SET member (counter, then replica, big-endian).
    static func elementID(_ member: [UInt8]) -> Wiretuner_Doc_V1_ElementId? {
        guard member.count == 16 else { return nil }
        func u64(_ offset: Int) -> UInt64 { member[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) } }
        return OpID(counter: u64(0), replica: u64(8)).elementID
    }

    /// The attachment `effect.attached_to` reads as in `stack`.
    static func attachment(_ effect: Wiretuner_Doc_V1_Effect, stack: [AppearanceRow]) -> EffectAttachment {
        guard let target = OpID(element: effect.attachedTo) else { return .object }
        guard let row = stack.first(where: { $0.element == target && $0.list != .effects }) else { return .skipped }
        return .element(row)
    }

    /// The effects applying to `target` (nil: the object level), in stack order.
    public static func group(_ node: OpID, target: AppearanceRow?, in state: EngineState) -> [EffectEntry] {
        entries(node, in: state).filter { $0.attachment == (target.map(EffectAttachment.element) ?? .object) }
    }

    /// The Object panel's note for an effect that renders as nothing where it is: "Combine
    /// applies to groups" for a Combine anywhere but the object level of a group.
    public static func notice(_ entry: EffectEntry, node: OpID, in state: EngineState) -> String? {
        guard entry.kind == .combine else { return nil }
        return state.nodeKind(node) == .group && entry.attachment == .object ? nil : EffectNames.combineNotice
    }
}

/// Effect names that are not kinds.
public enum EffectNames {
    public static let unsupported = "Unsupported effect (update WireTuner)"
    public static let combineNotice = "Combine applies to groups"

    static func isKnown(_ kind: Wiretuner_Doc_V1_EffectKind) -> Bool {
        AttributeNames.effectKinds.contains { $0.0 == kind }
    }
}

/// Paths of the registers of an effect's `settings` message, relative to it (effects.proto).
public enum EffectFields {
    public static let kind: [UInt32] = [1]

    /// The field of the kind's settings message in `EffectSettings`.
    public static func settingsField(_ kind: Wiretuner_Doc_V1_EffectKind) -> UInt32? {
        let fields: [Wiretuner_Doc_V1_EffectKind: UInt32] = [
            .bend: 10, .duet: 11, .expandPath: 12, .ragged: 13, .sketch: 14, .transform: 15, .corners: 16, .combine: 17,
            .bevelEmboss: 20, .blur: 21, .shadow: 22, .sharpen: 23, .transparency: 24,
        ]
        return fields[kind]
    }

    /// The register `field` of `kind`'s settings message.
    public static func field(_ kind: Wiretuner_Doc_V1_EffectKind, _ field: UInt32) -> [UInt32] {
        [settingsField(kind) ?? 0, field]
    }

    /// The seed register of a seeded kind (Ragged, Sketch).
    public static func seed(_ kind: Wiretuner_Doc_V1_EffectKind) -> [UInt32]? {
        switch kind {
        case .ragged: field(.ragged, 6)
        case .sketch: field(.sketch, 4)
        default: nil
        }
    }

    /// The colour register of a kind with one (Bevel and Emboss, Shadow).
    public static func color(_ kind: Wiretuner_Doc_V1_EffectKind) -> [UInt32]? {
        switch kind {
        case .bevelEmboss: field(.bevelEmboss, 2)
        case .shadow: field(.shadow, 2)
        default: nil
        }
    }

    /// Every register of the kind's settings message that a freshly chosen kind is seeded with.
    static func seeded(_ kind: Wiretuner_Doc_V1_EffectKind) -> [[UInt32]] {
        let count: [Wiretuner_Doc_V1_EffectKind: UInt32] = [
            .bend: 2, .duet: 7, .expandPath: 5, .ragged: 6, .sketch: 4, .transform: 9, .corners: 2, .combine: 1,
            .bevelEmboss: 8, .blur: 2, .shadow: 6, .sharpen: 4, .transparency: 4,
        ]
        return (0..<(count[kind] ?? 0)).map { field(kind, $0 + 1) }
    }
}

/// Deterministic, never-zero seeds (live-effects.adoc "Seeds", stroke-attributes.adoc "seed"):
/// derived from the counter the change's next op takes and the replica, so every seed a replica
/// allocates differs and a test can predict it.
public enum Seeds {
    /// SplitMix64's finalizer over `replica` and `counter`; never 0.
    public static func allocate(replica: UInt64, counter: UInt64) -> UInt64 {
        var z = replica &* 0x9E37_79B9_7F4A_7C15 ^ counter &+ 0xD1B5_4A32_D192_ED03
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return max(z, 1)
    }

    /// A seed for the next op of `builder`; `salt` separates several seeds of one op.
    static func next(_ builder: ChangeBuilder, salt: UInt64 = 0) -> UInt64 {
        allocate(replica: builder.replica, counter: builder.nextCounter &+ salt &* 0x1_0000_0000)
    }
}

/// The working settings a new effect of each kind starts with (live-effects.adoc: "The new
/// effect starts with its default settings"; the pages leave the values to the implementation):
/// a visible, moderate result for every kind, a fresh seed for Ragged and Sketch.
public enum EffectDefaults {
    public static func settings(_ kind: Wiretuner_Doc_V1_EffectKind, seed: UInt64) -> Wiretuner_Doc_V1_EffectSettings {
        var settings = Wiretuner_Doc_V1_EffectSettings()
        settings.kind = kind
        fill(&settings, kind, seed: seed)
        return settings
    }

    /// Writes `kind`'s defaults into `settings` (its kind register untouched).
    static func fill(_ settings: inout Wiretuner_Doc_V1_EffectSettings, _ kind: Wiretuner_Doc_V1_EffectKind, seed: UInt64) {
        switch kind {
        case .bend:
            settings.bend.size = 20
            settings.bend.center = Wiretuner_Doc_V1_Point()
        case .duet:
            settings.duet.mode = .reflect
            settings.duet.center = Wiretuner_Doc_V1_Point()
            settings.duet.axisAngle = 90
            settings.duet.copies = 2
        case .expandPath:
            settings.expandPath.direction = .both
            settings.expandPath.width = 4
            settings.expandPath.cap = .butt
            settings.expandPath.join = .miter
            settings.expandPath.miterLimit = 4
        case .ragged:
            settings.ragged.size = 4
            settings.ragged.frequency = 12
            settings.ragged.seed = seed
        case .sketch:
            settings.sketch.amount = 3
            settings.sketch.copies = 3
            settings.sketch.seed = seed
        case .transform:
            settings.transform.scaleX = 100
            settings.transform.scaleY = 100
            settings.transform.uniform = true
            settings.transform.move = Wiretuner_Doc_V1_Point()
            settings.transform.center = Wiretuner_Doc_V1_Point()
            settings.transform.copies = 1
        case .corners:
            settings.corners.radius = 6
            settings.corners.style = .round
        case .combine:
            settings.combine.op = .union
        case .bevelEmboss:
            settings.bevelEmboss.style = .innerBevel
            settings.bevelEmboss.color = ColorResolver.inline(Color(white: 0.6))
            settings.bevelEmboss.width = 4
            settings.bevelEmboss.contrast = 50
            settings.bevelEmboss.softness = 3
            settings.bevelEmboss.angle = 135
            settings.bevelEmboss.edgeShape = .flat
            settings.bevelEmboss.buttonPreset = .raised
        case .blur:
            settings.blur.style = .gaussian
            settings.blur.radius = 2
        case .shadow:
            settings.shadow.style = .dropShadow
            settings.shadow.color = ColorResolver.inline(.black)
            settings.shadow.offset = 6
            settings.shadow.opacity = 50
            settings.shadow.softness = 5
            settings.shadow.angle = 315
        case .sharpen:
            settings.sharpen.style = .basic
            settings.sharpen.amount = 50
            settings.sharpen.pixelRadius = 1
            settings.sharpen.threshold = 0
        case .transparency:
            settings.transparency.style = .basic
            settings.transparency.amount = 50
            settings.transparency.radius = 4
            settings.transparency.softness = 50
        default:
            break
        }
    }

    /// Whether the kind's settings message was never written.
    static func isEmpty(_ settings: Wiretuner_Doc_V1_EffectSettings, _ kind: Wiretuner_Doc_V1_EffectKind) -> Bool {
        switch kind {
        case .bend: settings.bend == .init()
        case .duet: settings.duet == .init()
        case .expandPath: settings.expandPath == .init()
        case .ragged: settings.ragged == .init()
        case .sketch: settings.sketch == .init()
        case .transform: settings.transform == .init()
        case .corners: settings.corners == .init()
        case .combine: settings.combine == .init()
        case .bevelEmboss: settings.bevelEmboss == .init()
        case .blur: settings.blur == .init()
        case .shadow: settings.shadow == .init()
        case .sharpen: settings.sharpen == .init()
        case .transparency: settings.transparency == .init()
        default: true
        }
    }
}

/// Shared writing of effect elements.
enum EffectEditing {
    /// The live effect `row` of `node` and its stack owner, or throws.
    static func effect(_ node: OpID, _ row: AppearanceRow, in state: EngineState) throws -> (owner: StackOwner, effect: Wiretuner_Doc_V1_Effect) {
        guard row.list == .effects else { throw PathEditError.unknownPoint(row.element) }
        let owner = try AppearanceEditing.owner(node, row, in: state)
        let entry = AttributeEntry.read(node, row, owner: owner, state: state)
        return (owner, entry.effect)
    }

    /// The path of the effect element `element` on `owner`.
    static func element(_ owner: StackOwner, _ element: OpID) -> RegisterPath {
        owner.sequence(.effects).element(element)
    }

    /// A sparse `NodeProps` holding `effect` as the one element of `owner`'s effects.
    static func values(_ owner: StackOwner, _ effect: Wiretuner_Doc_V1_Effect) -> Wiretuner_Doc_V1_NodeProps {
        AppearanceEditing.values(owner) { $0.effects = [effect] }
    }

    /// The `SetFields` writing `fields` (relative to the settings message) of `row` from
    /// `settings`.
    static func set(_ node: OpID, _ owner: StackOwner, _ row: AppearanceRow, fields: [[UInt32]],
                    settings: Wiretuner_Doc_V1_EffectSettings) -> Wiretuner_Doc_V1_Op {
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings = settings
        let base = element(owner, row.element).child(AppearanceList.effects.settingsField)
        return Ops.set(node, fields.map { base.appending($0) }, values: values(owner, effect))
    }

    /// The `SetFields` writing `attached_to` of `row` (nil clears it: the object level).
    static func attach(_ node: OpID, _ owner: StackOwner, _ row: AppearanceRow, to target: OpID?) -> Wiretuner_Doc_V1_Op {
        var effect = Wiretuner_Doc_V1_Effect()
        if let target { effect.attachedTo = target.elementID }
        return Ops.set(node, [element(owner, row.element).child(3)], values: values(owner, effect))
    }
}

/// btn:[Add Effect] (live-effects.adoc, "To add a live effect"): one effect of `kind` with its
/// default settings on each node -- at the object level above `above` (or at the top of the
/// stack), or attached to the fill or stroke `attachTo` names on each node, directly above that
/// element's own effects.  Labelled "Add Bend effect".
public struct AddEffect: Command {
    public var nodes: [OpID]
    public var kind: Wiretuner_Doc_V1_EffectKind
    /// Per node, the fill or stroke to attach to (absent: the object level).
    public var attachTo: [OpID: AppearanceRow]
    /// Per node, the row to insert above at the object level.
    public var above: [OpID: AppearanceRow]

    public init(_ nodes: [OpID], kind: Wiretuner_Doc_V1_EffectKind, attachTo: [OpID: AppearanceRow] = [:], above: [OpID: AppearanceRow] = [:]) {
        self.nodes = nodes
        self.kind = kind
        self.attachTo = attachTo
        self.above = above
    }

    public var label: String { "Add \(AttributeNames.effectKind(kind)) effect" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard EffectNames.isKnown(kind) else { throw ObjectEditError.invalidValue("kind") }
        for node in nodes {
            let owner = try AppearanceEditing.owner(node, in: state)
            var effect = Wiretuner_Doc_V1_Effect()
            effect.settings = EffectDefaults.settings(kind, seed: Seeds.next(builder))
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
            builder.append(Ops.elementInsert(node, owner.sequence(.effects), positions: [key], values: EffectEditing.values(owner, effect)))
        }
    }
}

/// btn:[Remove Item] on effects: an `ElementDelete` of each; a concurrent edit stays on the
/// tombstone and *Restore* brings it back.  Labelled "Remove effect".
public struct RemoveEffect: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]

    public init(_ rows: [(node: OpID, row: AppearanceRow)]) {
        self.rows = rows
    }

    public var label: String { "Remove effect" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let (owner, _) = try EffectEditing.effect(node, row, in: state)
            builder.append(Ops.elementDelete(node, [EffectEditing.element(owner, row.element)]))
        }
    }
}

/// Dragging an effect in the appearance list (live-effects.adoc, "To reorder effects"): the
/// effect moves to `index` among the effects of the group it is dropped into -- the object level
/// (`target` nil) or the effects attached to the fill or stroke `target` -- writing `attached_to`
/// when the group changes and an `ElementMove` to a position among that group's effects.
/// Labelled "Reorder effects".
public struct ReorderEffect: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var target: AppearanceRow?
    public var index: Int

    public init(node: OpID, row: AppearanceRow, to index: Int, attachTo target: AppearanceRow? = nil) {
        self.node = node
        self.row = row
        self.index = index
        self.target = target
    }

    public var label: String { "Reorder effects" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (owner, effect) = try EffectEditing.effect(node, row, in: state)
        if let target {
            guard target.list != .effects else { throw PathEditError.unknownPoint(target.element) }
            _ = try AppearanceEditing.owner(node, target, in: state)
        }
        let stack = AppearanceEditing.stack(node, in: state)
        let current = EffectReading.attachment(effect, stack: stack)
        let wanted: EffectAttachment = target.map(EffectAttachment.element) ?? .object
        if current != wanted {
            builder.append(EffectEditing.attach(node, owner, row, to: target?.element))
        }
        let group = EffectReading.group(node, target: target, in: state).map(\.row).filter { $0 != row }
        let order = stack.filter { $0 != row }
        let clamped = min(max(index, 0), group.count)
        let stackIndex: Int
        if clamped < group.count {
            stackIndex = order.firstIndex(of: group[clamped])!
        } else if let last = group.last ?? target {
            stackIndex = order.firstIndex(of: last)! + 1
        } else {
            stackIndex = order.count
        }
        // Already there: the neighbours in the stack are the ones it has.
        let now = stack.firstIndex(of: row)!
        if current == wanted, now == stackIndex { return }
        let key = try AppearanceEditing.key(at: stackIndex, of: node, moving: row, owner: owner, state: state)
        builder.append(Ops.elementMove(node, EffectEditing.element(owner, row.element), position: key))
    }
}

/// The *Effect* pop-up (live-effects.adoc, "To change which effect an item is"): the `kind`
/// register only, so the other kinds' settings stay; a kind whose settings were never written is
/// seeded with its defaults in the same change.  Labelled "Change effect to Ragged".
public struct SetEffectKind: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var kind: Wiretuner_Doc_V1_EffectKind

    public init(_ rows: [(node: OpID, row: AppearanceRow)], kind: Wiretuner_Doc_V1_EffectKind) {
        self.rows = rows
        self.kind = kind
    }

    public var label: String { "Change effect to \(AttributeNames.effectKind(kind))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard EffectNames.isKnown(kind) else { throw ObjectEditError.invalidValue("kind") }
        for (node, row) in rows {
            let (owner, effect) = try EffectEditing.effect(node, row, in: state)
            var settings = Wiretuner_Doc_V1_EffectSettings()
            settings.kind = kind
            var fields = [EffectFields.kind]
            if EffectDefaults.isEmpty(effect.settings, kind) {
                EffectDefaults.fill(&settings, kind, seed: Seeds.next(builder))
                fields += EffectFields.seeded(kind)
            }
            builder.append(EffectEditing.set(node, owner, row, fields: fields, settings: settings))
        }
    }
}

/// Any setting of any effect (every field of the effect editors, a canvas centre-handle drag):
/// the registers at `fields` (paths relative to the settings message, `EffectFields`) of each
/// row, from `settings`.  One change over every selected object.
public struct EditEffect: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var fields: [[UInt32]]
    public var settings: Wiretuner_Doc_V1_EffectSettings
    public var baseLabel: String

    public init(_ rows: [(node: OpID, row: AppearanceRow)], label: String, fields: [[UInt32]],
                _ build: (inout Wiretuner_Doc_V1_EffectSettings) -> Void) {
        self.rows = rows
        self.baseLabel = label
        self.fields = fields
        var settings = Wiretuner_Doc_V1_EffectSettings()
        build(&settings)
        self.settings = settings
    }

    public var label: String { fannedLabel(baseLabel, count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.contains(EffectFields.field(.corners, 3)) else { throw ObjectEditError.invalidValue("points") }
        for (node, row) in rows {
            let (owner, _) = try EffectEditing.effect(node, row, in: state)
            builder.append(EffectEditing.set(node, owner, row, fields: fields, settings: settings))
        }
    }
}

/// btn:[Reseed] on Ragged and Sketch: a new seed for each row of a seeded kind (others are left
/// alone).  Labelled "Reseed".
public struct ReseedEffect: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]

    public init(_ rows: [(node: OpID, row: AppearanceRow)]) {
        self.rows = rows
    }

    public var label: String { fannedLabel("Reseed", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (index, (node, row)) in rows.enumerated() {
            let (owner, effect) = try EffectEditing.effect(node, row, in: state)
            let kind = effect.settings.kind
            guard let field = EffectFields.seed(kind) else { continue }
            var settings = Wiretuner_Doc_V1_EffectSettings()
            let seed = Seeds.next(builder, salt: UInt64(index))
            if kind == .ragged { settings.ragged.seed = seed } else { settings.sketch.seed = seed }
            builder.append(EffectEditing.set(node, owner, row, fields: [field], settings: settings))
        }
    }
}

/// A Corners effect's *Selected points* (btn:[Add Selection], btn:[Remove Selection], a widget
/// drag with points selected): `SetAdd` or `SetRemove` of path point element ids on the
/// `points` SET, so two people's selections both keep.  Labelled "Change corners".
public struct SetCornerPoints: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var points: [OpID]
    public var adding: Bool

    public init(_ rows: [(node: OpID, row: AppearanceRow)], points: [OpID], adding: Bool) {
        self.rows = rows
        self.points = points
        self.adding = adding
    }

    public var label: String { fannedLabel("Change corners", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !points.isEmpty else { return }
        for (node, row) in rows {
            let (owner, _) = try EffectEditing.effect(node, row, in: state)
            var effect = Wiretuner_Doc_V1_Effect()
            effect.settings.corners.points = points.map(\.elementID)
            let path = EffectEditing.element(owner, row.element).child(AppearanceList.effects.settingsField).appending(EffectFields.field(.corners, 3))
            let values = EffectEditing.values(owner, effect)
            builder.append(adding ? Ops.setAdd(node, path, values: values) : Ops.setRemove(node, path, values: values))
        }
    }
}
