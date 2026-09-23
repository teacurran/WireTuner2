import WTCRDT
import WTProto
import WTRender

/// Brush nodes (docs/_includes/appearance/stroke-attributes.adoc, "Brush strokes", "Data model";
/// ATTR-008): `BrushProps` nodes (kind 80) in the well-known `brushes` collection (0:8), each
/// painting the symbols its `symbols` sequence names.
public enum BrushFields {
    public static let collection = OpID.wellKnown(8)
    public static let kind: UInt32 = 80
    public static let name = RegisterPath([80, 1, 1])
    public static let mode = RegisterPath([80, 2])
    public static let count = RegisterPath([80, 3])
    public static let symbols = RegisterPath([80, 4])
    public static let orientOnPath = RegisterPath([80, 5])
    public static let foldCorners = RegisterPath([80, 6])
    public static let spacing = RegisterPath([80, 7])
    public static let angle = RegisterPath([80, 8])
    public static let offset = RegisterPath([80, 9])
    public static let scaling = RegisterPath([80, 10])
    /// Every register of a brush's settings (what *Change* writes), name included.
    public static let settings = [name, mode, count, orientOnPath, foldCorners, spacing, angle, offset, scaling]

    /// `NodeProps` holding `props` as a brush.
    public static func values(_ props: Wiretuner_Doc_V1_BrushProps) -> Wiretuner_Doc_V1_NodeProps {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.brush = props
        return values
    }
}

/// One brush as the pop-up lists it.
public struct BrushEntry: Hashable, Sendable {
    public var id: OpID
    public var props: Wiretuner_Doc_V1_BrushProps
    /// The symbols it paints that are live, bottom first (a deleted symbol is skipped).
    public var symbols: [OpID]

    public var name: String { props.common.name }
}

/// Reading and resolving brushes.
public enum Brushes {
    /// The live brushes in collection order.
    public static func list(_ state: EngineState) -> [BrushEntry] {
        // Read on every scene build: a document without brushes costs one lookup.
        let children = state.liveChildren(BrushFields.collection)
        guard !children.isEmpty else { return [] }
        let live = Set(Symbols.symbols(in: state))
        return children.compactMap { id in
            guard state.store.kind(id) == BrushFields.kind else { return nil }
            let props = state.props(id).brush
            let symbols = props.symbols.compactMap { $0.hasSymbol ? OpID($0.symbol.id) : nil }.filter(live.contains)
            return BrushEntry(id: id, props: props, symbols: symbols)
        }
    }

    /// Whether `id` is a live brush.
    public static func isBrush(_ id: OpID, in state: EngineState) -> Bool {
        state.isLive(id) && state.store.kind(id) == BrushFields.kind && state.store.placement(id)?.parent == BrushFields.collection
    }

    /// Every live brush resolved for drawing, its symbols' artwork from `library`.
    static func resolve(_ state: EngineState, library: SymbolLibrary, renderer: SymbolRenderer) -> [OpID: Brush] {
        var result: [OpID: Brush] = [:]
        for entry in list(state) {
            let symbols = entry.symbols.compactMap { library.symbols[NodeID($0)] }.map { artwork in
                BrushSymbol(items: renderer.artworkItems(artwork, overrides: [], in: library))
            }
            result[entry.id] = brush(entry.props, symbols: symbols)
        }
        return result
    }

    /// `props` lowered with `symbols` (read-time rules: unspecified mode reads Spray, a count of 0
    /// reads 1, an unset variation reads its default).
    static func brush(_ props: Wiretuner_Doc_V1_BrushProps, symbols: [BrushSymbol]) -> Brush {
        Brush(mode: props.mode == .paint ? .paint : .spray, count: Int(max(props.count, 1)), symbols: symbols, orientOnPath: props.orientOnPath,
              foldCorners: props.foldCorners, spacing: variation(props.hasSpacing ? props.spacing : nil, default: 100),
              angle: variation(props.hasAngle ? props.angle : nil, default: 0), offset: variation(props.hasOffset ? props.offset : nil, default: 0),
              scaling: variation(props.hasScaling ? props.scaling : nil, default: 100))
    }

    static func variation(_ stored: Wiretuner_Doc_V1_BrushVariation?, default value: Double) -> BrushVariation {
        guard let stored else { return .fixed(value) }
        let modes: [Wiretuner_Doc_V1_VariationMode: VariationMode] = [.random: .random, .variable: .variable, .flare: .flare]
        return BrushVariation(mode: modes[stored.mode] ?? .fixed, value: stored.value, min: stored.min, max: stored.max)
    }

    /// The brush a stroke's `brush` reference draws while a scene is built; nil (the cached
    /// Basic stroke) outside a build or when the brush is gone.
    static func definition(_ ref: Wiretuner_Doc_V1_NodeRef) -> Brush? {
        guard ref.hasID else { return nil }
        return SceneContext.current?.brushes[OpID(ref.id)]
    }

    /// The brush nodes `props`' strokes reference (a node's dependencies for redrawing).
    static func referenced(_ props: Wiretuner_Doc_V1_AppearanceProps?) -> [OpID] {
        (props?.strokes ?? []).compactMap { stroke in
            stroke.settings.kind == .brush && stroke.settings.brush.brush.hasID ? OpID(stroke.settings.brush.brush.id) : nil
        }
    }
}
