import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// The registers of the vector effects' settings messages (effects.proto), by field number.
enum EffectField {
    static func bend(_ field: UInt32) -> [UInt32] { EffectFields.field(.bend, field) }
    static func duet(_ field: UInt32) -> [UInt32] { EffectFields.field(.duet, field) }
    static func expand(_ field: UInt32) -> [UInt32] { EffectFields.field(.expandPath, field) }
    static func ragged(_ field: UInt32) -> [UInt32] { EffectFields.field(.ragged, field) }
    static func sketch(_ field: UInt32) -> [UInt32] { EffectFields.field(.sketch, field) }
    static func transform(_ field: UInt32) -> [UInt32] { EffectFields.field(.transform, field) }
    static func corners(_ field: UInt32) -> [UInt32] { EffectFields.field(.corners, field) }
    static func combine(_ field: UInt32) -> [UInt32] { EffectFields.field(.combine, field) }
}

/// What the effect editors read and the commands they perform (live-effects.adoc; FX-003): the
/// *Effect* pop-up and the form of each vector effect with every option of the page's tables.
/// Values are nil when the selected objects' effects differ; every edit is one change over all of
/// them (`EditEffect`, `SetEffectKind`, `ReseedEffect`, `SetCornerPoints`).
@MainActor
struct EffectEditorModel {
    let context: AttributeEditorContext
    /// The window's selection: *Selected points* and btn:[Add Selection] read its points.
    var selection: Selection?

    /// The *Effect* pop-up: vector effects, then raster ones, then Transparency (the Add Effect
    /// menu's order).
    static let kinds: [(Wiretuner_Doc_V1_EffectKind, String)] = EffectMenu.vector + EffectMenu.raster + EffectMenu.transparency

    static let duetModes: [(Wiretuner_Doc_V1_DuetMode, String)] = [(.reflect, "Reflect"), (.rotate, "Rotate")]
    static let directions: [(Wiretuner_Doc_V1_ExpandDirection, String)] = [(.inside, "Inside"), (.outside, "Outside"), (.both, "Both")]
    static let cornerStyles: [(Wiretuner_Doc_V1_CornerStyle, String)] = [(.round, "Round"), (.invertedRound, "Inverted round"), (.chamfer, "Chamfer")]
    static let operations: [(Wiretuner_Doc_V1_BooleanOp, String)] = [(.union, "Union"), (.subtract, "Subtract"), (.intersect, "Intersect"), (.exclude, "Exclude")]

    var pairs: [(node: OpID, row: AppearanceRow)] { context.pairs }

    func settings<T: Equatable>(_ read: (Wiretuner_Doc_V1_EffectSettings) -> T) -> T? {
        context.shared { read($0.effect.settings) }
    }

    func edit(_ label: String, _ fields: [[UInt32]], _ build: (inout Wiretuner_Doc_V1_EffectSettings) -> Void) -> EditEffect {
        EditEffect(pairs, label: label, fields: fields, build)
    }

    /// The live kind: nil when the effects differ or the kind is one this build does not know.
    var kind: Wiretuner_Doc_V1_EffectKind? {
        settings(\.kind).flatMap { kind in Self.kinds.contains { $0.0 == kind } ? kind : nil }
    }

    /// Whether the effects share a kind this build does not know (a newer client's).
    var isUnsupported: Bool { settings(\.kind) != nil && kind == nil }

    func setKind(_ kind: Wiretuner_Doc_V1_EffectKind) -> any WTModel.Command {
        SetEffectKind(pairs, kind: kind)
    }

    /// The Object panel's note for a Combine that renders as nothing where it is.
    var notice: String? {
        guard let first = context.item.targets.first,
              let entry = EffectReading.entries(first.node, in: context.document.state).first(where: { $0.row == first.row }) else { return nil }
        return EffectReading.notice(entry, node: first.node, in: context.document.state)
    }

    /// The document's unit for centre and move fields.
    var unit: MeasureUnit { context.document.units.measureUnit }

    static func point(_ x: Double, _ y: Double) -> Wiretuner_Doc_V1_Point {
        var point = Wiretuner_Doc_V1_Point()
        point.x = x
        point.y = y
        return point
    }

    /// A centre or move typed one coordinate at a time: the point is ATOMIC, so the other
    /// coordinate is written as it is.
    static func replacing(_ point: Wiretuner_Doc_V1_Point, x: Double?, y: Double?) -> Wiretuner_Doc_V1_Point {
        Self.point(x ?? point.x, y ?? point.y)
    }

    private var first: Wiretuner_Doc_V1_EffectSettings { context.entries.first?.effect.settings ?? Wiretuner_Doc_V1_EffectSettings() }

    // MARK: Bend

    var bendSize: Double? { settings(\.bend.size) }
    var bendCenterX: Double? { settings(\.bend.center.x) }
    var bendCenterY: Double? { settings(\.bend.center.y) }

    func setBendSize(_ size: Double) -> any WTModel.Command {
        edit("Change bend size", [EffectField.bend(1)]) { $0.bend.size = size }
    }

    func setBendCenter(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let center = Self.replacing(first.bend.center, x: x, y: y)
        return edit("Move bend center", [EffectField.bend(2)]) { $0.bend.center = center }
    }

    func setBendCenterX(_ value: Double) -> any WTModel.Command { setBendCenter(x: value) }
    func setBendCenterY(_ value: Double) -> any WTModel.Command { setBendCenter(y: value) }

    // MARK: Duet

    var duetMode: Wiretuner_Doc_V1_DuetMode? { settings { $0.duet.mode == .rotate ? .rotate : .reflect } }
    var duetCenterX: Double? { settings(\.duet.center.x) }
    var duetCenterY: Double? { settings(\.duet.center.y) }
    var duetAxis: Double? { settings(\.duet.axisAngle) }
    /// 0 reads 1.
    var duetCopies: Double? { settings { Double(max($0.duet.copies, 1)) } }
    var duetJoined: Bool? { settings(\.duet.joined) }
    var duetClosed: Bool? { settings(\.duet.closed) }
    var duetEvenOdd: Bool? { settings(\.duet.evenOdd) }

    func setDuetMode(_ mode: Wiretuner_Doc_V1_DuetMode) -> any WTModel.Command {
        edit("Change duet mode", [EffectField.duet(1)]) { $0.duet.mode = mode }
    }

    func setDuetCenter(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let center = Self.replacing(first.duet.center, x: x, y: y)
        return edit("Move duet center", [EffectField.duet(2)]) { $0.duet.center = center }
    }

    func setDuetCenterX(_ value: Double) -> any WTModel.Command { setDuetCenter(x: value) }
    func setDuetCenterY(_ value: Double) -> any WTModel.Command { setDuetCenter(y: value) }

    func setDuetAxis(_ degrees: Double) -> any WTModel.Command {
        edit("Rotate duet axis", [EffectField.duet(3)]) { $0.duet.axisAngle = degrees }
    }

    /// 1 ... 100.
    func setDuetCopies(_ copies: Double) -> any WTModel.Command {
        edit("Change copies", [EffectField.duet(4)]) { $0.duet.copies = UInt32(min(max(copies.rounded(), 1), 100)) }
    }

    func setDuetJoined(_ on: Bool) -> any WTModel.Command { edit("Joined", [EffectField.duet(5)]) { $0.duet.joined = on } }
    func setDuetClosed(_ on: Bool) -> any WTModel.Command { edit("Closed", [EffectField.duet(6)]) { $0.duet.closed = on } }
    func setDuetEvenOdd(_ on: Bool) -> any WTModel.Command { edit("Even/Odd fill", [EffectField.duet(7)]) { $0.duet.evenOdd = on } }

    // MARK: Expand Path

    var expandDirection: Wiretuner_Doc_V1_ExpandDirection? { settings { $0.expandPath.direction == .unspecified ? .both : $0.expandPath.direction } }
    var expandWidth: Double? { settings(\.expandPath.width) }
    var expandCap: Wiretuner_Doc_V1_LineCap? { settings { $0.expandPath.cap == .unspecified ? .butt : $0.expandPath.cap } }
    var expandJoin: Wiretuner_Doc_V1_LineJoin? { settings { $0.expandPath.join == .unspecified ? .miter : $0.expandPath.join } }
    /// 0 reads 4.
    var expandMiter: Double? { settings { $0.expandPath.miterLimit == 0 ? 4 : $0.expandPath.miterLimit } }
    /// A stored width outside 0 ... 50 (a hand-built change) is drawn clamped and shown in red.
    var expandWidthOutOfRange: Bool { expandWidth.map { !(0...50).contains($0) } ?? false }

    func setExpandDirection(_ direction: Wiretuner_Doc_V1_ExpandDirection) -> any WTModel.Command {
        edit("Change direction", [EffectField.expand(1)]) { $0.expandPath.direction = direction }
    }

    /// 0 ... 50 pt.
    func setExpandWidth(_ width: Double) -> any WTModel.Command {
        edit("Change expand width", [EffectField.expand(2)]) { $0.expandPath.width = min(max(width, 0), 50) }
    }

    func setExpandCap(_ cap: Wiretuner_Doc_V1_LineCap) -> any WTModel.Command { edit("Change cap", [EffectField.expand(3)]) { $0.expandPath.cap = cap } }
    func setExpandJoin(_ join: Wiretuner_Doc_V1_LineJoin) -> any WTModel.Command { edit("Change join", [EffectField.expand(4)]) { $0.expandPath.join = join } }

    /// 1 ... 57.
    func setExpandMiter(_ limit: Double) -> any WTModel.Command {
        edit("Change miter limit", [EffectField.expand(5)]) { $0.expandPath.miterLimit = min(max(limit, 1), 57) }
    }

    // MARK: Ragged

    var raggedSize: Double? { settings(\.ragged.size) }
    var raggedFrequency: Double? { settings(\.ragged.frequency) }
    var raggedCopies: Double? { settings { Double($0.ragged.copies) } }
    var raggedSmooth: Bool? { settings(\.ragged.smooth) }
    var raggedUniform: Bool? { settings(\.ragged.uniform) }

    func setRaggedSize(_ size: Double) -> any WTModel.Command { edit("Change ragged size", [EffectField.ragged(1)]) { $0.ragged.size = max(size, 0) } }
    func setRaggedFrequency(_ value: Double) -> any WTModel.Command { edit("Change frequency", [EffectField.ragged(2)]) { $0.ragged.frequency = max(value, 0) } }

    /// 0 ... 10.
    func setRaggedCopies(_ copies: Double) -> any WTModel.Command {
        edit("Change copies", [EffectField.ragged(3)]) { $0.ragged.copies = UInt32(min(max(copies.rounded(), 0), 10)) }
    }

    /// *Rough* (false) or *Smooth* (true).
    func setRaggedSmooth(_ smooth: Bool) -> any WTModel.Command { edit(smooth ? "Smooth" : "Rough", [EffectField.ragged(4)]) { $0.ragged.smooth = smooth } }
    func setRaggedUniform(_ on: Bool) -> any WTModel.Command { edit("Uniform", [EffectField.ragged(5)]) { $0.ragged.uniform = on } }

    /// btn:[Reseed] on Ragged and Sketch.
    func reseed() -> any WTModel.Command { ReseedEffect(pairs) }

    // MARK: Sketch

    var sketchAmount: Double? { settings(\.sketch.amount) }
    var sketchCopies: Double? { settings { Double(max($0.sketch.copies, 1)) } }
    var sketchClosed: Bool? { settings(\.sketch.closed) }

    func setSketchAmount(_ amount: Double) -> any WTModel.Command { edit("Change amount", [EffectField.sketch(1)]) { $0.sketch.amount = max(amount, 0) } }

    /// 1 ... 20.
    func setSketchCopies(_ copies: Double) -> any WTModel.Command {
        edit("Change copies", [EffectField.sketch(2)]) { $0.sketch.copies = UInt32(min(max(copies.rounded(), 1), 20)) }
    }

    func setSketchClosed(_ on: Bool) -> any WTModel.Command { edit("Closed", [EffectField.sketch(3)]) { $0.sketch.closed = on } }

    // MARK: Transform

    var scaleX: Double? { settings(\.transform.scaleX) }
    var scaleY: Double? { settings(\.transform.scaleY) }
    var uniform: Bool? { settings(\.transform.uniform) }
    var skewH: Double? { settings(\.transform.skewH) }
    var skewV: Double? { settings(\.transform.skewV) }
    var rotate: Double? { settings(\.transform.rotate) }
    var moveX: Double? { settings(\.transform.move.x) }
    var moveY: Double? { settings(\.transform.move.y) }
    var transformCenterX: Double? { settings(\.transform.center.x) }
    var transformCenterY: Double? { settings(\.transform.center.y) }
    var transformCopies: Double? { settings { Double(max($0.transform.copies, 1)) } }

    /// *Scale X*: with *Uniform*, Y is written equal to X.
    func setScaleX(_ value: Double) -> any WTModel.Command {
        let locked = uniform ?? false
        return edit("Change scale", locked ? [EffectField.transform(1), EffectField.transform(2)] : [EffectField.transform(1)]) { settings in
            settings.transform.scaleX = value
            if locked { settings.transform.scaleY = value }
        }
    }

    func setScaleY(_ value: Double) -> any WTModel.Command {
        let locked = uniform ?? false
        return edit("Change scale", locked ? [EffectField.transform(1), EffectField.transform(2)] : [EffectField.transform(2)]) { settings in
            settings.transform.scaleY = value
            if locked { settings.transform.scaleX = value }
        }
    }

    /// *Uniform* on writes Y equal to X.
    func setUniform(_ on: Bool) -> any WTModel.Command {
        let x = first.transform.scaleX
        return edit("Uniform", on ? [EffectField.transform(3), EffectField.transform(2)] : [EffectField.transform(3)]) { settings in
            settings.transform.uniform = on
            if on { settings.transform.scaleY = x }
        }
    }

    func setSkewH(_ value: Double) -> any WTModel.Command { edit("Change skew", [EffectField.transform(4)]) { $0.transform.skewH = value } }
    func setSkewV(_ value: Double) -> any WTModel.Command { edit("Change skew", [EffectField.transform(5)]) { $0.transform.skewV = value } }
    func setRotate(_ value: Double) -> any WTModel.Command { edit("Change rotation", [EffectField.transform(6)]) { $0.transform.rotate = value } }

    func setMove(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let move = Self.replacing(first.transform.move, x: x, y: y)
        return edit("Change move", [EffectField.transform(7)]) { $0.transform.move = move }
    }

    func setMoveX(_ value: Double) -> any WTModel.Command { setMove(x: value) }
    func setMoveY(_ value: Double) -> any WTModel.Command { setMove(y: value) }

    func setTransformCenter(x: Double? = nil, y: Double? = nil) -> any WTModel.Command {
        let center = Self.replacing(first.transform.center, x: x, y: y)
        return edit("Move transform center", [EffectField.transform(8)]) { $0.transform.center = center }
    }

    func setTransformCenterX(_ value: Double) -> any WTModel.Command { setTransformCenter(x: value) }
    func setTransformCenterY(_ value: Double) -> any WTModel.Command { setTransformCenter(y: value) }

    /// 1 ... 1000.
    func setTransformCopies(_ copies: Double) -> any WTModel.Command {
        edit("Change copies", [EffectField.transform(9)]) { $0.transform.copies = UInt32(min(max(copies.rounded(), 1), 1000)) }
    }

    // MARK: Corners

    var cornerRadius: Double? { settings(\.corners.radius) }
    var cornerStyle: Wiretuner_Doc_V1_CornerStyle? { settings { $0.corners.style == .unspecified ? .round : $0.corners.style } }

    /// Each target's *Selected points* as the effect reads them (the SET completed).
    var cornerPoints: [[OpID]] {
        context.item.targets.map { target in
            let entry = EffectReading.entries(target.node, in: context.document.state).first { $0.row == target.row }
            return (entry?.effect.settings.corners.points ?? []).compactMap { OpID(element: $0) }
        }
    }

    /// *All* when no target lists points; nil when some do and some do not.
    var cornersAll: Bool? { WireTuner.shared(cornerPoints.map(\.isEmpty)) }

    func setCornerRadius(_ radius: Double) -> any WTModel.Command {
        edit("Change corner radius", [EffectField.corners(1)]) { $0.corners.radius = max(radius, 0) }
    }

    func setCornerStyle(_ style: Wiretuner_Doc_V1_CornerStyle) -> any WTModel.Command {
        edit("Change corner style", [EffectField.corners(2)]) { $0.corners.style = style }
    }

    /// The points of `node` selected in the window.
    func selectedPoints(of node: OpID) -> [OpID] {
        guard case .points(let points)? = selection?.subSelection(of: SelectionID(node)) else { return [] }
        return points.map(\.point).sorted()
    }

    /// btn:[Add Selection] (and choosing *Selected points*): each target's selected points join
    /// its set; btn:[Remove Selection] takes them out.  Nil when no target has points selected.
    func changeCornerPoints(adding: Bool) -> (any WTModel.Command)? {
        let changes = context.item.targets.compactMap { target -> (any WTModel.Command)? in
            let points = selectedPoints(of: target.node)
            return points.isEmpty ? nil : SetCornerPoints([target.pair], points: points, adding: adding)
        }
        return changes.isEmpty ? nil : CompositeCommand(Objects.label("Change corners", count: changes.count), changes)
    }

    /// *All*: every listed point leaves the set.  Nil when there is none.
    func treatAllCorners() -> (any WTModel.Command)? {
        let changes = zip(context.item.targets, cornerPoints).compactMap { target, points -> (any WTModel.Command)? in
            points.isEmpty ? nil : SetCornerPoints([target.pair], points: points, adding: false)
        }
        return changes.isEmpty ? nil : CompositeCommand(Objects.label("Change corners", count: changes.count), changes)
    }

    /// The *Corners* pop-up: *All* clears the set; *Selected points* adds the selection.
    func setCornersAll(_ all: Bool) -> (any WTModel.Command)? {
        all ? treatAllCorners() : changeCornerPoints(adding: true)
    }

    // MARK: Combine

    var operation: Wiretuner_Doc_V1_BooleanOp? { settings { $0.combine.op == .unspecified ? .union : $0.combine.op } }

    func setOperation(_ op: Wiretuner_Doc_V1_BooleanOp) -> any WTModel.Command {
        edit("Change operation", [EffectField.combine(1)]) { $0.combine.op = op }
    }

    /// The selected groups whose Combine draws (btn:[Expand] is enabled for them).
    var expandableGroups: [OpID] {
        let state = context.document.state
        var seen: Set<OpID> = []
        return pairs.map(\.node).filter { CombineReading.canExpand($0, in: state) && seen.insert($0).inserted }
    }

    /// btn:[Expand] (FX-049): each group's combined outline written as one path in its place, one
    /// change "Expand Combine"; nil when no selected group's Combine draws.
    func expandCombine() -> (any WTModel.Command)? {
        let groups = expandableGroups
        return groups.isEmpty ? nil : ExpandCombine(groups)
    }
}

/// The btn:[Add Effect] menu's groups (live-effects.adoc, "To add a live effect"): vector effects
/// first, then the raster effects, then Transparency.
enum EffectMenu {
    static let vector: [(Wiretuner_Doc_V1_EffectKind, String)] = [
        (.bend, "Bend"), (.combine, "Combine"), (.corners, "Corners"), (.duet, "Duet"), (.expandPath, "Expand Path"), (.ragged, "Ragged"),
        (.sketch, "Sketch"), (.transform, "Transform"),
    ]
    static let raster: [(Wiretuner_Doc_V1_EffectKind, String)] = [(.bevelEmboss, "Bevel and Emboss"), (.blur, "Blur"), (.shadow, "Shadow"), (.sharpen, "Sharpen")]
    static let transparency: [(Wiretuner_Doc_V1_EffectKind, String)] = [(.transparency, "Transparency")]
}

/// The effect editor: the *Effect* pop-up and the live kind's form.
struct EffectEditorView: View {
    let model: EffectEditorModel

    /// btn:[Reseed].
    static func reseeding(_ model: EffectEditorModel) -> () -> Void {
        { model.context.perform(model.reseed()) }
    }

    /// btn:[Add Selection] (`adding`) and btn:[Remove Selection].
    static func changingCorners(_ model: EffectEditorModel, adding: Bool) -> () -> Void {
        { model.context.perform(model.changeCornerPoints(adding: adding)) }
    }

    /// The *Corners* pop-up's binding.
    static func cornersAll(_ model: EffectEditorModel) -> Binding<Bool> {
        Binding(get: { model.cornersAll ?? true }, set: { model.context.perform(model.setCornersAll($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isUnsupported {
                Text(EffectNames.unsupported).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("effect.unsupported")
            }
            AttributePicker(title: "Effect", value: model.kind, choices: EffectEditorModel.kinds, identifier: "effect.kind",
                            commit: model.context.committing(model.setKind))
            switch model.kind {
            case .bend?: bend
            case .duet?: duet
            case .expandPath?: expand
            case .ragged?: ragged
            case .sketch?: sketch
            case .transform?: transform
            case .corners?: corners
            case .combine?: combine
            case .none: EmptyView()
            case let kind?:
                Text("\(AttributeNames.effectKind(kind)) options arrive with the raster effect editors.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("effect.raster")
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("effect.notice")
            }
        }
    }

    private func field(_ title: String, _ value: Double?, _ id: String, _ command: @escaping (Double) -> any WTModel.Command) -> some View {
        CommitField(title: title, value: value, identifier: "effect.\(id)", commit: model.context.committing(command))
    }

    private func measure(_ title: String, _ value: Double?, _ id: String, _ command: @escaping (Double) -> any WTModel.Command) -> some View {
        MeasureField(title: title, value: value, unit: model.unit, identifier: "effect.\(id)", commit: model.context.committing(command))
    }

    private func toggle(_ title: String, _ value: Bool?, _ id: String, _ command: @escaping (Bool) -> any WTModel.Command) -> some View {
        AttributeToggle(title: title, value: value, identifier: "effect.\(id)", commit: model.context.committing(command))
    }

    @ViewBuilder private var bend: some View {
        field("Size", model.bendSize, "bend.size", model.setBendSize)
        measure("Center X", model.bendCenterX, "bend.center-x", model.setBendCenterX)
        measure("Center Y", model.bendCenterY, "bend.center-y", model.setBendCenterY)
    }

    @ViewBuilder private var duet: some View {
        AttributePicker(title: "Mode", value: model.duetMode, choices: EffectEditorModel.duetModes, identifier: "effect.duet.mode",
                        commit: model.context.committing(model.setDuetMode))
            .pickerStyle(.segmented)
        measure("Center X", model.duetCenterX, "duet.center-x", model.setDuetCenterX)
        measure("Center Y", model.duetCenterY, "duet.center-y", model.setDuetCenterY)
        field("Axis", model.duetAxis, "duet.axis", model.setDuetAxis)
        field("Copies", model.duetCopies, "duet.copies", model.setDuetCopies)
            .disabled(model.duetMode != .rotate)
        toggle("Joined", model.duetJoined, "duet.joined", model.setDuetJoined)
        toggle("Closed", model.duetClosed, "duet.closed", model.setDuetClosed)
        toggle("Even/Odd fill", model.duetEvenOdd, "duet.even-odd", model.setDuetEvenOdd)
    }

    @ViewBuilder private var expand: some View {
        AttributePicker(title: "Direction", value: model.expandDirection, choices: EffectEditorModel.directions, identifier: "effect.expand.direction",
                        commit: model.context.committing(model.setExpandDirection))
        field("Width", model.expandWidth, "expand.width", model.setExpandWidth)
            .foregroundStyle(model.expandWidthOutOfRange ? SwiftUI.Color.red : SwiftUI.Color.primary)
        AttributePicker(title: "Cap", value: model.expandCap, choices: StrokeEditorModel.caps, identifier: "effect.expand.cap",
                        commit: model.context.committing(model.setExpandCap))
            .pickerStyle(.segmented)
        AttributePicker(title: "Join", value: model.expandJoin, choices: StrokeEditorModel.joins, identifier: "effect.expand.join",
                        commit: model.context.committing(model.setExpandJoin))
            .pickerStyle(.segmented)
        field("Miter limit", model.expandMiter, "expand.miter", model.setExpandMiter)
    }

    @ViewBuilder private var ragged: some View {
        field("Size", model.raggedSize, "ragged.size", model.setRaggedSize)
        field("Frequency", model.raggedFrequency, "ragged.frequency", model.setRaggedFrequency)
        field("Copies", model.raggedCopies, "ragged.copies", model.setRaggedCopies)
        AttributePicker(title: "Points", value: model.raggedSmooth, choices: [(false, "Rough"), (true, "Smooth")], identifier: "effect.ragged.smooth",
                        commit: model.context.committing(model.setRaggedSmooth))
            .pickerStyle(.segmented)
        toggle("Uniform", model.raggedUniform, "ragged.uniform", model.setRaggedUniform)
        Button("Reseed", action: Self.reseeding(model)).accessibilityIdentifier("effect.ragged.reseed")
    }

    @ViewBuilder private var sketch: some View {
        field("Amount", model.sketchAmount, "sketch.amount", model.setSketchAmount)
        field("Copies", model.sketchCopies, "sketch.copies", model.setSketchCopies)
        toggle("Closed", model.sketchClosed, "sketch.closed", model.setSketchClosed)
        Button("Reseed", action: Self.reseeding(model)).accessibilityIdentifier("effect.sketch.reseed")
    }

    @ViewBuilder private var transform: some View {
        field("Scale X %", model.scaleX, "transform.scale-x", model.setScaleX)
        field("Scale Y %", model.scaleY, "transform.scale-y", model.setScaleY)
        toggle("Uniform", model.uniform, "transform.uniform", model.setUniform)
        field("Skew H", model.skewH, "transform.skew-h", model.setSkewH)
        field("Skew V", model.skewV, "transform.skew-v", model.setSkewV)
        field("Rotate", model.rotate, "transform.rotate", model.setRotate)
        measure("Move X", model.moveX, "transform.move-x", model.setMoveX)
        measure("Move Y", model.moveY, "transform.move-y", model.setMoveY)
        measure("Center X", model.transformCenterX, "transform.center-x", model.setTransformCenterX)
        measure("Center Y", model.transformCenterY, "transform.center-y", model.setTransformCenterY)
        field("Copies", model.transformCopies, "transform.copies", model.setTransformCopies)
    }

    @ViewBuilder private var corners: some View {
        field("Radius", model.cornerRadius, "corners.radius", model.setCornerRadius)
        AttributePicker(title: "Style", value: model.cornerStyle, choices: EffectEditorModel.cornerStyles, identifier: "effect.corners.style",
                        commit: model.context.committing(model.setCornerStyle))
        Picker("Corners", selection: Self.cornersAll(model)) {
            Text("All").tag(true)
            Text("Selected points").tag(false)
        }
        .accessibilityIdentifier("effect.corners.mode")
        HStack {
            Button("Add Selection", action: Self.changingCorners(model, adding: true))
                .accessibilityIdentifier("effect.corners.add")
            Button("Remove Selection", action: Self.changingCorners(model, adding: false))
                .accessibilityIdentifier("effect.corners.remove")
        }
        .disabled(model.cornersAll != false)
    }

    /// btn:[Expand] in the Combine form.
    static func expanding(_ model: EffectEditorModel) -> () -> Void {
        { model.context.perform(model.expandCombine()) }
    }

    @ViewBuilder private var combine: some View {
        AttributePicker(title: "Operation", value: model.operation, choices: EffectEditorModel.operations, identifier: "effect.combine.op",
                        commit: model.context.committing(model.setOperation))
        Button("Expand", action: Self.expanding(model)).disabled(model.expandableGroups.isEmpty)
            .help("Replace the group with its combined outline as one path")
            .accessibilityIdentifier("effect.combine.expand")
    }
}
