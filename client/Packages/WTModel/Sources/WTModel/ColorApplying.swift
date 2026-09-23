import WTCRDT
import WTProto

/// Which paint a colour applied to objects goes to (applying-color.adoc: the Swatches panel's
/// *Fill*, *Stroke* and *Both* selectors, the Tools panel wells, a drop with kbd:[Shift] or
/// kbd:[Cmd]).
public enum ColorTarget: String, CaseIterable, Hashable, Sendable {
    case fill, stroke, both

    /// The attribute lists the target writes.
    public var lists: [AppearanceList] {
        switch self {
        case .fill: [.fills]
        case .stroke: [.strokes]
        case .both: [.fills, .strokes]
        }
    }

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .stroke: "Stroke"
        case .both: "Both"
        }
    }
}

/// Applies a colour to objects (applying-color.adoc, "Applying color to selected objects";
/// COLOR-011): on each object the *topmost* Basic fill, Basic stroke or both takes the colour,
/// gradient and pattern rows are left alone, and an object without such a row is skipped.  A
/// group applies to every object in it.  One change for every object, labelled `Apply "Grape"
/// to 12 objects` (or `Apply color` for an unnamed colour).
public struct ApplyColor: Command {
    public var nodes: [OpID]
    public var target: ColorTarget
    public var color: Wiretuner_Doc_V1_ColorRef
    /// The swatch name for the label; empty for an unnamed colour.
    public var name: String

    public init(_ nodes: [OpID], target: ColorTarget, color: Wiretuner_Doc_V1_ColorRef, name: String = "") {
        self.nodes = nodes
        self.target = target
        self.color = color
        self.name = name
    }

    public var label: String {
        let what = name.isEmpty ? (ColorBridgeNames.isNone(color) ? "None" : "color") : Swatches.quoted(name)
        return nodes.count > 1 ? "Apply \(what) to \(nodes.count) objects" : "Apply \(what)"
    }

    /// The rows the colour goes to: per object (groups expanded), the topmost Basic row of each
    /// list the target names.
    public static func rows(_ nodes: [OpID], target: ColorTarget, in state: EngineState) -> [(node: OpID, row: AppearanceRow)] {
        var result: [(node: OpID, row: AppearanceRow)] = []
        var seen: Set<OpID> = []
        func visit(_ node: OpID) {
            guard seen.insert(node).inserted, state.isLive(node) else { return }
            if state.nodeKind(node) == .group {
                state.liveChildren(node).forEach(visit)
                return
            }
            let entries = AppearanceEditing.entries(node, in: state)
            for list in target.lists {
                let basic: AttributeKind = list == .fills ? .fill(.basic) : .stroke(.basic)
                if let top = entries.last(where: { $0.row.list == list && $0.kind == basic }) {
                    result.append((node, top.row))
                }
            }
        }
        nodes.forEach(visit)
        return result
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let rows = Self.rows(nodes, target: target, in: state)
        guard !rows.isEmpty else { return }
        try SetAppearanceColor(rows, color: color).execute(&builder, state: state)
    }
}

/// *None* recognition shared by labels.
enum ColorBridgeNames {
    static func isNone(_ ref: Wiretuner_Doc_V1_ColorRef) -> Bool {
        if case .none? = ref.ref { return true }
        return false
    }
}
