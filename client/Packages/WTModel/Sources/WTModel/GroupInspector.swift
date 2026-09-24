import WTCRDT
import WTProto

/// The Object panel's rows for a group (OBJ-017, grouping.adoc "Client"; object-panel.adoc): the
/// root row's *Transform as unit* toggle and the *Contents* row, whose double-click subselects
/// every live member.
public enum GroupInspector {
    /// The register of `GroupProps.transform_as_unit`.
    public static let transformAsUnitField = RegisterPath([NodeKind.group.rawValue, 3])

    /// Whether `group` is a group whose matrix scales its members' strokes.
    public static func transformsAsUnit(_ group: OpID, in state: EngineState) -> Bool {
        state.nodeKind(group) == .group && state.props(group).group.transformAsUnit
    }

    /// What the *Contents* row selects: the live members of `group`, bottom first -- for a clip
    /// group, every one but the clip path (clipping-paths.adoc, "The Object panel").  Empty for
    /// anything that is not a live group.
    public static func contents(of group: OpID, in state: EngineState) -> [OpID] {
        guard state.isLive(group), state.nodeKind(group) == .group else { return [] }
        let clip = Arranging.clipPath(of: group, in: state)
        return state.liveChildren(group).filter { $0 != clip }
    }
}

/// The *Transform as unit* checkbox: writes `transform_as_unit` on each selected group (one
/// register each), skipping locked groups and groups already set so.  One change: "Transform as
/// unit" or "Transform as unit of 3 objects".
public struct SetTransformAsUnit: Command {
    public var groups: [OpID]
    public var asUnit: Bool

    public init(_ groups: [OpID], asUnit: Bool) {
        self.groups = groups
        self.asUnit = asUnit
    }

    public var label: String { fannedLabel("Transform as unit", count: groups.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.group.transformAsUnit = asUnit
        for group in Objects.editable(groups, in: state)
        where state.nodeKind(group) == .group && GroupInspector.transformsAsUnit(group, in: state) != asUnit {
            builder.append(Ops.set(group, [GroupInspector.transformAsUnitField], values: values))
        }
    }
}
