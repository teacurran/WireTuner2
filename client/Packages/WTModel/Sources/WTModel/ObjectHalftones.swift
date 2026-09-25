import WTCRDT
import WTProto

// PRINT-010: object halftone screens from the Halftones panel (printing/halftones.adoc, "Merge
// semantics").  `CommonProps.halftone` (11) is ATOMIC: the panel writes the whole screen on each
// selected object in one change, and *Use document settings* writes it unset.

/// Reading object screens: an object's own, and the effective one through its groups.
public enum ObjectHalftones {
    /// `CommonProps.halftone` of an object of `kind`.
    public static func field(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 11]) }

    /// The screen `node` sets itself; nil when its register is unset (or it has no common props).
    public static func own(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_Halftone? {
        let kind = state.store.kind(node)
        guard state.register(node, RegisterPath([kind, 1, 11]))?.isSet == true, let common = NodeValues.common(state.props(node)) else { return nil }
        return common.halftone
    }

    /// The screen `node` prints with before the plate's: its own, else the nearest enclosing group's
    /// that has one (halftones.adoc: "A group's screen applies to every member that has no screen of
    /// its own"); nil when neither it nor any ancestor sets one.  Nothing is written.
    public static func effective(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_Halftone? {
        var current: OpID? = node
        var seen: Set<OpID> = []
        while let id = current, !seen.contains(id) {
            seen.insert(id)
            if let own = own(id, in: state) { return own }
            let parent = state.store.placement(id)?.parent
            current = parent.flatMap { state.store.kind($0) == NodeKind.group.rawValue ? $0 : nil }
        }
        return nil
    }
}

/// The Halftones panel's write: `halftone` (or nil, *Use document settings*) on every selected
/// unlocked object that has common props, one `SetFields` each in one change labelled "Change
/// halftone" or "Change halftone of N objects".
public struct SetObjectHalftone: Command {
    public var nodes: [OpID]
    public var halftone: Wiretuner_Doc_V1_Halftone?

    public init(_ nodes: [OpID], halftone: Wiretuner_Doc_V1_Halftone?) {
        self.nodes = nodes
        self.halftone = halftone
    }

    public var label: String { fannedLabel("Change halftone", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let halftone {
            guard halftone.angle.isFinite, (0...360).contains(halftone.angle), halftone.frequency.isFinite, (0...600).contains(halftone.frequency) else {
                throw PrintSettingsError.invalidValue("halftone")
            }
        }
        for node in nodes {
            guard state.isLive(node), let kind = NodeKind(rawValue: state.store.kind(node)), kind != .layer,
                  NodeValues.common(state.props(node))?.locked != true else { continue }
            let values = halftone.map { screen in NodeValues.common(kind: kind) { $0.halftone = screen } } ?? Wiretuner_Doc_V1_NodeProps()
            builder.append(Ops.set(node, [ObjectHalftones.field(kind)], values: values))
        }
    }
}
