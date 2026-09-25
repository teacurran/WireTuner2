import WTCRDT
import WTProto

// Alt text and *Decorative* (names-notes.adoc, "Describing objects for accessibility"; OBJ-040):
// `CommonProps.alt` (9) and `CommonProps.decorative` (10) of any object kind, each its own LWW
// register, and the readings the exporters and VoiceOver use.

/// Register paths of the description fields of any kind's `CommonProps`.
public enum DescriptionFields {
    public static func alt(_ kind: UInt32) -> RegisterPath { NavigationFields.common(kind).child(9) }
    public static func decorative(_ kind: UInt32) -> RegisterPath { NavigationFields.common(kind).child(10) }
    /// The longest alt text, in characters.
    public static let maxAlt = 512
}

/// Sets the alt text of each object (input stops at 512 characters).  "Change alt text", or "...
/// of N objects".
public struct SetAlt: Command {
    public var nodes: [OpID]
    public var alt: String

    public init(_ nodes: [OpID], alt: String) {
        self.nodes = nodes
        self.alt = alt
    }

    public var label: String { nodes.count == 1 ? "Change alt text" : "Change alt text of \(nodes.count) objects" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let limited = String(alt.prefix(DescriptionFields.maxAlt))
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            builder.append(Ops.set(node, [DescriptionFields.alt(kind)], values: NavigationFields.values(kind: kind) { $0.alt = limited }))
        }
    }
}

/// Ticks or unticks *Decorative* on each object; the alt text stays in its register.
/// "Decorative" / "Not decorative".
public struct SetDecorative: Command {
    public var nodes: [OpID]
    public var decorative: Bool

    public init(_ nodes: [OpID], decorative: Bool) {
        self.nodes = nodes
        self.decorative = decorative
    }

    public var label: String { decorative ? "Decorative" : "Not decorative" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, kind) in try Navigation.linkable(nodes, in: state) {
            builder.append(Ops.set(node, [DescriptionFields.decorative(kind)], values: NavigationFields.values(kind: kind) { $0.decorative = decorative }))
        }
    }
}

extension EngineState {
    /// What a screen reader says for `node`: its alt text when set, a text node's plain text,
    /// else nil.
    public func accessibleDescription(of node: OpID) -> String? {
        let common = NavigationFields.common(of: node, in: self)
        if let alt = common?.alt, !alt.isEmpty { return alt }
        if nodeKind(node) == .text, let text = textNode(node)?.string, !text.isEmpty { return text }
        return nil
    }

    /// Whether `node` is read: not decorative, and described or a group holding a readable node.
    public func isReadable(_ node: OpID) -> Bool {
        guard isLive(node), NavigationFields.common(of: node, in: self)?.decorative != true else { return false }
        if accessibleDescription(of: node) != nil { return true }
        return nodeKind(node) == .group && liveChildren(node).contains { isReadable($0) }
    }

    /// The nodes read for `nodes`, in order: a group with alt text is one figure; a group without
    /// is read as its readable members, in the group's stacking order.
    public func readableNodes(_ nodes: [OpID]) -> [OpID] {
        nodes.flatMap { node -> [OpID] in
            guard isReadable(node) else { return [] }
            if nodeKind(node) == .group, NavigationFields.common(of: node, in: self)?.alt.isEmpty != false {
                return readableNodes(liveChildren(node))
            }
            return [node]
        }
    }
}
