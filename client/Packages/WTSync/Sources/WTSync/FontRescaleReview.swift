import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto

// The units-per-em rows of the review sheet (font-info.adoc, "UPM scale vs. concurrent drawing";
// FONT-007).  A *Scale to N UPM* change group writes `metrics.upm` and pre-multiplies the
// transform of every object that existed on a glyph canvas by s = new / old.  Two things drawn on
// the other side at the same time cannot merge by construction and are listed with a rescale:
//
// * an object *created* on a glyph canvas concurrently -- it was not in the scaler's change, so it
//   stays at its original size: "drawn while the font was rescaled", with *Rescale mine*;
// * an object whose `transform` the other side dragged concurrently and whose drag won -- it sits
//   at its dragged, unscaled transform: listed as *same register* (the ordinary overlap entry,
//   with *Use mine*) and here with *Rescale*.
//
// Both rescales apply s to the current transform (`RescaleObjects`), one normal, undoable change.
// The rows are measured on the side that did *not* scale: a replica that also scaled (two
// concurrent scales) sees one factor win every register, which the metric-setting entry lists.

/// One object to rescale.
public struct RescaleEntry: Sendable, Hashable, Identifiable {
    /// Why it is listed.
    public enum Reason: Sendable, Hashable {
        /// Created on a glyph canvas concurrently with the scale.
        case drawnWhileRescaled
        /// Its transform was written on both sides and the local drag won.
        case transformKept

        public var title: String {
            switch self {
            case .drawnWhileRescaled: "Drawn while the font was rescaled"
            case .transformKept: "Same attribute"
            }
        }

        /// The button: *Rescale mine* for a new object, *Rescale* on a transform conflict.
        public var actionTitle: String {
            switch self {
            case .drawnWhileRescaled: "Rescale mine"
            case .transformKept: "Rescale"
            }
        }
    }

    public var node: OpID
    /// The glyph whose canvas holds it.
    public var glyph: OpID
    public var reason: Reason
    /// The factor the other side scaled by (new UPM / old UPM).
    public var factor: Double
    /// The replicas that scaled.
    public var authors: [UInt64]

    public init(node: OpID, glyph: OpID, reason: Reason, factor: Double, authors: [UInt64]) {
        self.node = node
        self.glyph = glyph
        self.reason = reason
        self.factor = factor
        self.authors = authors
    }

    public var id: String { "rescale:\(node)" }

    /// The row's rescale as one change.
    public var command: RescaleObjects { RescaleObjects([node], by: factor) }
}

/// *Rescale mine* / *Rescale*: multiplies the transforms of `nodes` by the uniform scale `factor`
/// about the origin, as the UPM scale did to every object that existed.  One change.
public struct RescaleObjects: Command {
    public var nodes: [OpID]
    public var factor: Double

    public init(_ nodes: [OpID], by factor: Double) {
        self.nodes = nodes
        self.factor = factor
    }

    public var label: String { nodes.count == 1 ? "Rescale Object" : "Rescale \(nodes.count) Objects" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try TransformObjects(nodes, matrix: .scale(factor), kind: .scale).execute(&builder, state: state)
    }
}

/// Measuring the units-per-em rows.
public enum FontRescaleReview {
    /// Whether `label` is a UPM scale's ("Scale to 2048 UPM", or a part of its change group, "Scale
    /// to 2048 UPM [1/8]").
    public static func isScaleLabel(_ label: String) -> Bool {
        label.hasSuffix("UPM") || label.hasSuffix("]") ? label.range(of: #"(^|\s)Scale to [0-9]+ UPM( \[[0-9]+/[0-9]+\])?$"#, options: .regularExpression) != nil : false
    }

    /// The rows for `local` measured against `remote` in `state`: empty unless a remote change
    /// scaled the units per em and no local one wrote it.
    public static func rows(local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], state: EngineState) -> [RescaleEntry] {
        let upm = FontFields.metric(1)
        var scalers: Set<UInt64> = []
        var scaled: Set<OpID> = []
        var firstWrite: OpID?
        for change in remote where isScaleLabel(change.label) {
            for (op, id) in zip(change.ops, change.opIDs) {
                guard case .set(let set)? = op.op else { continue }
                let paths = set.paths.compactMap(RegisterPath.init)
                if OpID(set.node) == WellKnown.settings, paths.contains(upm) {
                    scalers.insert(change.replica)
                    firstWrite = min(firstWrite ?? id, id)
                } else if paths.contains(where: isTransform) {
                    scaled.insert(OpID(set.node))
                }
            }
        }
        guard let firstWrite, !writesUPM(local), let factor = factor(since: firstWrite, state: state) else { return [] }
        let authors = scalers.sorted()
        var rows: [RescaleEntry] = []
        var listed: Set<OpID> = []
        for change in local {
            for (op, id) in zip(change.ops, change.opIDs) {
                switch op.op {
                case .create:
                    guard !listed.contains(id), let glyph = glyphCanvas(of: id, state: state) else { continue }
                    listed.insert(id)
                    rows.append(RescaleEntry(node: id, glyph: glyph, reason: .drawnWhileRescaled, factor: factor, authors: authors))
                case .set(let set):
                    let node = OpID(set.node)
                    guard scaled.contains(node), !listed.contains(node), let path = set.paths.compactMap(RegisterPath.init).first(where: isTransform),
                          let glyph = glyphCanvas(of: node, state: state), localHolds(node, path, local: local, state: state) else { continue }
                    listed.insert(node)
                    rows.append(RescaleEntry(node: node, glyph: glyph, reason: .transformKept, factor: factor, authors: authors))
                default:
                    break
                }
            }
        }
        return rows.sorted { ($0.glyph, $0.node) < ($1.glyph, $1.node) }
    }

    /// *Rescale mine* for every row at once: one change.
    public static func rescaleAll(_ rows: [RescaleEntry]) -> RescaleObjects? {
        guard let factor = rows.first?.factor else { return nil }
        return RescaleObjects(rows.map(\.node), by: factor)
    }

    /// A `CommonProps.transform` path (`[kind, 1, 4]`).
    static func isTransform(_ path: RegisterPath) -> Bool {
        let fields = path.fields
        return fields.count == 3 && fields[1] == 1 && fields[2] == 4
    }

    /// Whether `changes` write the units per em.
    static func writesUPM(_ changes: [Wiretuner_Doc_V1_Change]) -> Bool {
        changes.contains { change in
            change.ops.contains { op in
                guard case .set(let set)? = op.op, OpID(set.node) == WellKnown.settings else { return false }
                return set.paths.compactMap(RegisterPath.init).contains { $0 == FontFields.metric(1) || $0 == FontFields.font || $0 == RegisterPath([2, 21, 2]) }
            }
        }
    }

    /// The merged units per em over the value before the write `first` (1000 when unset), or nil
    /// when they are equal.
    static func factor(since first: OpID, state: EngineState) -> Double? {
        let path = FontFields.metric(1)
        let writes = state.store.writes(WellKnown.settings, path)
        func value(_ bytes: [UInt8]?) -> Double {
            let stored = SparseProps.wrap(path, bytes).settings.font.metrics.upm
            return Double(stored == 0 ? 1000 : stored)
        }
        let before = writes.filter { $0.op < first }.max { $0.op < $1.op }
        let old = value(before?.value)
        let new = value(state.store.register(WellKnown.settings, path)?.value)
        return old == new ? nil : new / old
    }

    /// The glyph `node` is drawn on: a live top-level object whose `canvas` is a glyph.
    static func glyphCanvas(of node: OpID, state: EngineState) -> OpID? {
        guard state.isLive(node), let parent = state.store.placement(node)?.parent, state.nodeKind(parent) == .layer,
              let common = NavigationFields.common(of: node, in: state), common.hasCanvas else { return nil }
        let canvas = OpID(common.canvas.id)
        return state.store.kind(canvas) == GlyphFields.kind ? canvas : nil
    }

    /// Whether the register `path` of `node` is held by one of the `local` changes' writes.
    static func localHolds(_ node: OpID, _ path: RegisterPath, local: [Wiretuner_Doc_V1_Change], state: EngineState) -> Bool {
        guard let holder = state.store.register(node, path)?.op else { return false }
        return local.contains { $0.replica == holder.replica && $0.opIDs.contains(holder) }
    }
}
