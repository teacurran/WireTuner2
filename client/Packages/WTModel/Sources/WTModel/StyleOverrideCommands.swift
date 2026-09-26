import WTCRDT
import WTProto

/// *Clear Override* on a row of the Object panel's properties list (styles.adoc, "Overrides";
/// LIB-021): each object's own registers in `category` -- its live elements of that list, or its
/// halftone register (the clear-to-unset form) -- are cleared, so the object shows its style's
/// value there again; the style reference and the other categories are left alone.  Objects
/// without a style, or whose style does not govern the category, are skipped.  One change,
/// "Clear Override".
public struct ClearGraphicStyleOverride: Command {
    public var nodes: [OpID]
    public var category: StyleCategory
    public var label: String { "Clear Override" }

    public init(_ nodes: [OpID], category: StyleCategory) {
        self.nodes = nodes
        self.category = category
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            guard GraphicStyleDefaults.overrides(of: node, in: state).contains(category), let kind = state.nodeKind(node) else { continue }
            if category == .halftone {
                builder.append(Ops.set(node, [GraphicStyleFields.objectHalftone(kind)], values: NodeValues.common(kind: kind) { _ in }))
                continue
            }
            let host = StackHost.object(node, kind)
            StyleStacks.delete(StyleStacks.entries(host, in: state).filter { StyleStacks.category($0.row.list) == category }, of: host, builder: &builder)
        }
    }
}

public extension StyleCategory {
    /// The category an attribute list belongs to.
    init(_ list: AppearanceList) {
        switch list {
        case .fills: self = .fills
        case .strokes: self = .strokes
        case .effects: self = .effects
        }
    }
}
