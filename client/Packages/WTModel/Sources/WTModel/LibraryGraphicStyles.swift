import WTCRDT
import WTProto

/// A category of attributes a graphic style can govern (styles.adoc, "Style behavior").
public enum StyleCategory: Int, CaseIterable, Hashable, Sendable, Comparable {
    case fills, strokes, effects, halftone

    public static func < (lhs: StyleCategory, rhs: StyleCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where one category of an object's effective appearance comes from.
public enum AppearanceSource: Hashable, Sendable {
    /// The object's own registers (an override when its style governs the category).
    case own
    /// The style in the object's chain that sets the category.
    case style(OpID)
    /// The document defaults (`SettingsProps.defaults`).
    case defaults
}

/// A graphic style as resolved: every category some style of its `based_on` chain governs and
/// sets, from the style nearest to it.
public struct ResolvedGraphicStyle: Hashable, Sendable {
    public var id: OpID
    /// The chain, this style first, its root last (loops cut).
    public var chain: [OpID]
    /// The fills, strokes and effects the chain supplies (a category nobody supplies is empty).
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    public var halftone: Wiretuner_Doc_V1_Halftone?
    /// The style supplying each category.
    public var sources: [StyleCategory: OpID]
    /// The categories this style itself governs (all-false behaviour reads as all).
    public var governs: Set<StyleCategory>
}

/// An object's effective appearance, computed on read (styles.adoc, "Resolution (read-time)").
public struct EffectiveAppearance: Hashable, Sendable {
    public var style: OpID?
    public var appearance: Wiretuner_Doc_V1_AppearanceProps
    public var halftone: Wiretuner_Doc_V1_Halftone?
    public var sources: [StyleCategory: AppearanceSource]
    /// Own values in categories the style governs: the plus sign.
    public var overridden: Set<StyleCategory>
}

/// LIB-018's style resolver for *graphic* styles (styles.adoc, "Resolution (read-time)", "Override
/// model", "Read-time normalizations").  `update` reads the `styles` collection (0:6) and keeps
/// one resolution per style, rebuilt only when the style or a style of its chain changed (its
/// version: the chain's ids and serialized properties), so a redefine re-resolves that style and
/// its descendants and nothing else.  Objects are then resolved from their own registers: the
/// style reference, whether each category's stack holds a live element, the halftone register.
///
/// Normalizations: `based_on` loops are cut at the smallest node id in the cycle; a dangling,
/// deleted, non-style or text-style `based_on` reads as unset; all-false behaviour reads as every
/// category; an object's style reference to a deleted style that is still present resolves
/// through the deleted node's registers, to a node that is not a style, or to a text style, reads
/// as unset; of several styles with one role the smallest node id holds it and a deleted Normal
/// reads as live.  (The spec's `StyleResolver` is named `GraphicStyleResolver`: the TYPE epic owns
/// the text-style side.)
public struct GraphicStyleResolver: Sendable {
    /// The well-known `styles` collection.
    public static let collection = OpID.wellKnown(6)
    /// `NodeProps.style`.
    static let styleKind: UInt32 = 154

    struct Entry: Sendable {
        var props: Wiretuner_Doc_V1_StyleProps
        var deleted: Bool
        var version: Int
    }

    private(set) var entries: [OpID: Entry] = [:]
    private var cache: [OpID: (version: Int, style: ResolvedGraphicStyle)] = [:]
    /// The Normal graphic style and the Normal Text style (smallest node id with the role).
    public private(set) var normal: OpID?
    public private(set) var normalText: OpID?
    private var defaults = Wiretuner_Doc_V1_AppearanceProps()
    /// How many styles the last `update` resolved again (the cache test's figure).
    public private(set) var rebuilt = 0

    public init() {}

    public init(_ state: EngineState) {
        update(state)
    }

    /// Reads the styles and the defaults of `state`, keeping every cached resolution whose chain
    /// did not change.
    public mutating func update(_ state: EngineState) {
        var fresh: [OpID: Entry] = [:]
        for child in state.store.children(Self.collection) where state.store.kind(child) == Self.styleKind {
            let props = state.props(child).style
            var hasher = Hasher()
            hasher.combine((try? props.serializedBytes()) ?? [])
            let deleted = !state.isLive(child)
            hasher.combine(deleted)
            fresh[child] = Entry(props: props, deleted: deleted, version: hasher.finalize())
        }
        entries = fresh
        normal = fresh.filter { $0.value.props.role == .normal }.keys.min()
        normalText = fresh.filter { $0.value.props.role == .normalText }.keys.min()
        defaults = state.props(WellKnown.settings).settings.defaults.appearance
        if defaults.fills.isEmpty && defaults.strokes.isEmpty && defaults.effects.isEmpty { defaults = Appearances.standard }
        rebuilt = 0
        var kept: [OpID: (version: Int, style: ResolvedGraphicStyle)] = [:]
        for id in fresh.keys where isGraphic(id) {
            let chain = chain(of: id)
            var hasher = Hasher()
            for link in chain {
                hasher.combine(link)
                hasher.combine(fresh[link]!.version)
            }
            let version = hasher.finalize()
            if let cached = cache[id], cached.version == version {
                kept[id] = cached
            } else {
                kept[id] = (version, resolve(id, chain: chain))
                rebuilt += 1
            }
        }
        cache = kept
    }

    // MARK: Styles

    /// The role `style` holds after the duplicate-role rule.
    public func role(of style: OpID) -> Wiretuner_Doc_V1_StyleRole {
        guard let entry = entries[style] else { return .unspecified }
        switch entry.props.role {
        case .normal: return style == normal ? .normal : .unspecified
        case .normalText: return style == normalText ? .normalText : .unspecified
        default: return .unspecified
        }
    }

    /// Whether `style` reads as live: not deleted, or the Normal style (a deleted Normal reads as
    /// live).
    public func isLive(_ style: OpID) -> Bool {
        guard let entry = entries[style] else { return false }
        return !entry.deleted || role(of: style) != .unspecified
    }

    /// Whether `style` is a graphic style (kind unset or GRAPHIC).
    public func isGraphic(_ style: OpID) -> Bool {
        guard let kind = entries[style]?.props.kind else { return false }
        return kind == .unspecified || kind == .graphic
    }

    /// The categories `style` governs: its behaviour, all-false read as all.
    public func governs(_ style: OpID) -> Set<StyleCategory> {
        guard let behavior = entries[style]?.props.behavior else { return [] }
        let set = Set(StyleCategory.allCases.filter {
            switch $0 {
            case .fills: behavior.fills
            case .strokes: behavior.strokes
            case .effects: behavior.effects
            case .halftone: behavior.halftone
            }
        })
        return set.isEmpty ? Set(StyleCategory.allCases) : set
    }

    /// The parent of `style` as read: a live graphic style, else none.
    public func parent(of style: OpID) -> OpID? {
        guard let props = entries[style]?.props, props.hasBasedOn else { return nil }
        let parent = OpID(props.basedOn.id)
        guard entries[parent] != nil, isLive(parent), isGraphic(parent) else { return nil }
        return parent
    }

    /// `style` and its ancestors, nearest first; a loop is cut at its smallest node id, whose
    /// `based_on` reads as unset.
    public func chain(of style: OpID) -> [OpID] {
        var chain = [style]
        var index = [style: 0]
        var current = style
        while let parent = parent(of: current) {
            if let start = index[parent] {
                let cut = chain[start...].min()!
                return Array(chain[...chain.firstIndex(of: cut)!])
            }
            index[parent] = chain.count
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The resolution of graphic style `style` (nil for an unknown or text style).
    public func resolved(_ style: OpID) -> ResolvedGraphicStyle? {
        cache[style]?.style
    }

    private func resolve(_ style: OpID, chain: [OpID]) -> ResolvedGraphicStyle {
        var result = ResolvedGraphicStyle(id: style, chain: chain, appearance: Wiretuner_Doc_V1_AppearanceProps(), halftone: nil,
                                          sources: [:], governs: governs(style))
        for link in chain.reversed() {
            let props = entries[link]!.props
            for category in governs(link) {
                switch category {
                case .fills where !props.appearance.fills.isEmpty: result.appearance.fills = props.appearance.fills
                case .strokes where !props.appearance.strokes.isEmpty: result.appearance.strokes = props.appearance.strokes
                case .effects where !props.appearance.effects.isEmpty: result.appearance.effects = props.appearance.effects
                case .halftone where props.common.hasHalftone: result.halftone = props.common.halftone
                default: continue
                }
                result.sources[category] = link
            }
        }
        return result
    }

    // MARK: Objects

    /// The graphic style `object` uses after the read-time rules.
    public func style(of object: OpID, in state: EngineState) -> OpID? {
        // A register holds its field's record: tag, length, the NodeRef.
        guard let bytes = state.register(object, RegisterPath([state.store.kind(object), 1, 7]))?.value,
              let record = WireReader.fields(bytes)?.first, let ref = try? Wiretuner_Doc_V1_NodeRef(serializedBytes: record.payload),
              ref.hasID else { return nil }
        let target = OpID(ref.id)
        return entries[target] != nil && isGraphic(target) ? target : nil
    }

    /// The categories `object` sets itself: a stack with a live element, a set halftone.
    public func ownCategories(of object: OpID, in state: EngineState) -> Set<StyleCategory> {
        let kind = state.store.kind(object)
        var result: Set<StyleCategory> = []
        if let known = NodeKind(rawValue: kind), let field = NodeValues.appearanceField(known) {
            for (category, list) in [(StyleCategory.fills, UInt32(1)), (.strokes, 2), (.effects, 3)]
            where state.store.elementOrder(object, RegisterPath([kind, field, list])).contains(where: {
                state.store.element(object, RegisterPath([kind, field, list]).element($0))?.isDeleted == false
            }) {
                result.insert(category)
            }
        }
        if state.register(object, RegisterPath([kind, 1, 11]))?.isSet == true { result.insert(.halftone) }
        return result
    }

    /// Where each category of `object` comes from, without reading its values.
    public func sources(of object: OpID, in state: EngineState) -> (style: OpID?, sources: [StyleCategory: AppearanceSource]) {
        let style = style(of: object, in: state)
        let own = ownCategories(of: object, in: state)
        let resolved = style.flatMap(resolved)
        var sources: [StyleCategory: AppearanceSource] = [:]
        for category in StyleCategory.allCases {
            sources[category] = own.contains(category) ? .own : resolved?.sources[category].map { .style($0) } ?? .defaults
        }
        return (style, sources)
    }

    /// The effective appearance of `object`: defaults, then its style's chain, then its own set
    /// categories.
    public func effective(of object: OpID, in state: EngineState) -> EffectiveAppearance {
        let (style, sources) = sources(of: object, in: state)
        let resolved = style.flatMap(resolved)
        let props = sources.values.contains(.own) ? state.props(object) : Wiretuner_Doc_V1_NodeProps()
        let own = NodeValues.appearance(props) ?? Wiretuner_Doc_V1_AppearanceProps()
        var result = EffectiveAppearance(style: style, appearance: Wiretuner_Doc_V1_AppearanceProps(), halftone: nil, sources: sources, overridden: [])
        for (category, source) in sources {
            let from: Wiretuner_Doc_V1_AppearanceProps
            switch source {
            case .own: from = own
            case .style: from = resolved!.appearance
            case .defaults: from = defaults
            }
            switch category {
            case .fills: result.appearance.fills = from.fills
            case .strokes: result.appearance.strokes = from.strokes
            case .effects: result.appearance.effects = from.effects
            case .halftone:
                switch source {
                case .own: result.halftone = NodeValues.common(props)?.halftone
                case .style: result.halftone = resolved!.halftone
                case .defaults: result.halftone = nil
                }
            }
            if source == .own, resolved?.governs.contains(category) == true { result.overridden.insert(category) }
        }
        return result
    }

    /// The style-to-objects index: every live object (on the layers, inside groups and in
    /// symbols' artwork) by the graphic style it uses after the read-time rules, in tree order.
    public func index(in state: EngineState) -> [OpID: [OpID]] {
        var result: [OpID: [OpID]] = [:]
        var pending = state.liveChildren(WellKnown.layers).flatMap(state.liveChildren) + Symbols.symbols(in: state).flatMap(state.liveChildren)
        var cursor = 0
        while cursor < pending.count {
            let next = pending[cursor]
            cursor += 1
            if let style = style(of: next, in: state) { result[style, default: []].append(next) }
            pending += state.liveChildren(next)
        }
        return result
    }
}
