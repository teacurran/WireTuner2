import Foundation
import WTCRDT
import WTProto

// Text styles (TYPE-034; type/text-styles.adoc): `style` nodes of kind PARAGRAPH or CHARACTER
// under the well-known `styles` node 0:6, their resolution along `based_on` chains into
// `TextStyleAttrs`, and the attributes a paragraph or run of text resolves to: document defaults,
// the paragraph style chain, the paragraph's own registers, the character style chain, then the
// character marks.

/// Which text style kind (`StyleProps.kind`).
public enum TextStyleKind: Hashable, Sendable {
    case paragraph
    case character

    var stored: Wiretuner_Doc_V1_StyleKind { self == .paragraph ? .paragraph : .character }
}

/// Register paths of a `style` node (`NodeProps.style = 154`, `StyleProps`).
public enum TextStyleFields {
    /// The `styles` collection (0:6).
    public static let collection = OpID.wellKnown(6)
    /// `NodeProps.style`.
    public static let kind: UInt32 = 154
    /// `CommonProps.name`.
    public static let name = RegisterPath([154, 1, 1])
    /// `StyleProps.based_on`.
    public static let basedOn = RegisterPath([154, 4])
    /// `StyleProps.text`: the `TextStyleAttrs` (STRUCT).
    public static let text = RegisterPath([154, 7])
    /// `TextStyleAttrs.character` / `.paragraph`.
    static let character = text.child(2)
    static let paragraph = text.child(3)
    /// The name the document template gives the Normal Text style.
    public static let normalTextName = "Normal Text"

    /// A sparse `NodeProps` of a style.
    static func values(_ build: (inout Wiretuner_Doc_V1_StyleProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.style)
        return props
    }
}

/// A text style as read from the merged state.
public struct TextStyle: Hashable, Sendable {
    public var id: OpID
    public var name: String
    public var kind: TextStyleKind
    /// Holds the NORMAL_TEXT role after the duplicate rule (the smallest such node id).
    public var isNormalText: Bool
    /// The parent as read: a live text style of the same kind, loops cut at their smallest node
    /// id; nil for a root.
    public var parent: OpID?
    /// The style's own settings.
    public var attrs: Wiretuner_Doc_V1_TextStyleAttrs
}

/// The text styles of one merged state with their resolutions (text-styles.adoc, "Client": the
/// `ResolvedTextAttributes` cache).  `update` keeps each style's resolution while no node in its
/// chain changed; `rebuilt` counts the ones it resolved again.
public struct TextStyleResolver: Sendable {
    struct Entry: Sendable {
        var props: Wiretuner_Doc_V1_StyleProps
        var deleted: Bool
        var version: Int
    }

    private(set) var entries: [OpID: Entry] = [:]
    private var cache: [OpID: (version: Int, attrs: Wiretuner_Doc_V1_TextStyleAttrs, chain: [OpID])] = [:]
    /// The Normal Text style.
    public private(set) var normalText: OpID?
    /// The document's text defaults (`SettingsProps.defaults.text`).
    public private(set) var defaults = Wiretuner_Doc_V1_TextStyleAttrs()
    /// How many styles the last `update` resolved again.
    public private(set) var rebuilt = 0

    public init() {}

    public init(_ state: EngineState) {
        update(state)
    }

    /// Reads the styles and defaults of `state`, keeping every resolution whose chain is unchanged.
    public mutating func update(_ state: EngineState) {
        var fresh: [OpID: Entry] = [:]
        for child in state.store.children(TextStyleFields.collection) where state.store.kind(child) == TextStyleFields.kind {
            let props = state.props(child).style
            guard props.kind == .paragraph || props.kind == .character else { continue }
            var hasher = Hasher()
            hasher.combine(props)
            let deleted = !state.isLive(child)
            hasher.combine(deleted)
            fresh[child] = Entry(props: props, deleted: deleted, version: hasher.finalize())
        }
        entries = fresh
        normalText = fresh.filter { $0.value.props.role == .normalText && $0.value.props.kind == .paragraph }.keys.min()
        defaults = state.props(WellKnown.settings).settings.defaults.text
        rebuilt = 0
        var kept: [OpID: (version: Int, attrs: Wiretuner_Doc_V1_TextStyleAttrs, chain: [OpID])] = [:]
        for id in fresh.keys {
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
                let attrs = chain.reversed().reduce(Wiretuner_Doc_V1_TextStyleAttrs()) { TextStyleAttributes.overlay($0, fresh[$1]!.props.text) }
                kept[id] = (version, attrs, chain)
                rebuilt += 1
            }
        }
        cache = kept
    }

    // MARK: Styles

    /// Whether `id` is a live text style (a deleted Normal Text reads as live).
    public func isLive(_ id: OpID) -> Bool {
        guard let entry = entries[id] else { return false }
        return !entry.deleted || id == normalText
    }

    /// The text style `id`, live or deleted; nil for anything else.
    public func style(_ id: OpID) -> TextStyle? {
        guard let entry = entries[id] else { return nil }
        return TextStyle(id: id, name: entry.props.common.name, kind: entry.props.kind == .paragraph ? .paragraph : .character,
                         isNormalText: id == normalText, parent: parent(of: id), attrs: entry.props.text)
    }

    /// The live styles of `kind`, by name then id.
    public func styles(_ kind: TextStyleKind) -> [TextStyle] {
        entries.keys.filter { isLive($0) && entries[$0]!.props.kind == kind.stored }.compactMap(style)
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The live children of `id` (styles whose stored `based_on` names it).
    public func children(of id: OpID) -> [OpID] {
        entries.filter { isLive($0.key) && $0.value.props.hasBasedOn && OpID($0.value.props.basedOn.id) == id }.keys.sorted()
    }

    /// The parent of `id` as read: a live text style of the same kind; dangling or other kinds
    /// read as unset.
    func parent(of id: OpID) -> OpID? {
        guard let props = entries[id]?.props, props.hasBasedOn else { return nil }
        let parent = OpID(props.basedOn.id)
        guard parent != id, isLive(parent), entries[parent]?.props.kind == props.kind else { return nil }
        return parent
    }

    /// `id` and its ancestors, nearest first; a loop is cut at its smallest node id, whose
    /// `based_on` reads as unset.
    public func chain(of id: OpID) -> [OpID] {
        var chain = [id]
        var index = [id: 0]
        var current = id
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

    /// The resolution of `id`: its chain's settings overlaid root to leaf (nil for an unknown id).
    public func resolved(_ id: OpID) -> Wiretuner_Doc_V1_TextStyleAttrs? {
        cache[id]?.attrs
    }

    // MARK: References

    /// What a `style` reference of `kind` reads as: the live referent's resolution; for a
    /// dangling reference or one to a style of the wrong kind, the cached settings (a reference is
    /// then read as unset, the cache applied); nil for none.
    public func reference(_ ref: Wiretuner_Doc_V1_NodeRef, kind: TextStyleKind) -> (style: OpID?, attrs: Wiretuner_Doc_V1_TextStyleAttrs)? {
        let id = OpID(ref.id)
        if isLive(id), entries[id]?.props.kind == kind.stored, let attrs = resolved(id) {
            return (id, attrs)
        }
        guard !ref.cached.isEmpty, let cached = try? Wiretuner_Doc_V1_TextStyleAttrs(serializedBytes: ref.cached) else { return nil }
        return (nil, cached)
    }

    /// The paragraph style a paragraph reads: its `style` reference, or Normal Text when it has
    /// none.
    public func paragraphStyle(_ props: Wiretuner_Doc_V1_ParagraphProps) -> (style: OpID?, attrs: Wiretuner_Doc_V1_TextStyleAttrs) {
        if props.hasStyle, props.style.id != Wiretuner_Doc_V1_OpId(), let read = reference(props.style, kind: .paragraph) {
            return read
        }
        return (normalText, normalText.flatMap(resolved) ?? Wiretuner_Doc_V1_TextStyleAttrs())
    }

    /// A `NodeRef` to `id` caching its current resolution.
    public func ref(_ id: OpID) -> Wiretuner_Doc_V1_NodeRef {
        var ref = Wiretuner_Doc_V1_NodeRef()
        ref.id = id.proto
        ref.cached = (try? (resolved(id) ?? Wiretuner_Doc_V1_TextStyleAttrs()).serializedData()) ?? Data()
        return ref
    }

    // MARK: Resolution

    /// The paragraph properties `paragraph` reads: its style's paragraph settings with its own
    /// registers over them (`style` kept).
    public func paragraph(_ paragraph: Wiretuner_Doc_V1_ParagraphProps) -> Wiretuner_Doc_V1_ParagraphProps {
        let base = TextStyleAttributes.overlay(defaults, paragraphStyle(paragraph).attrs)
        return TextStyleAttributes.paragraph(paragraph, over: TextStyleAttributes.paragraph(base.paragraph).props)
    }

    /// The character attribute values a run reads, in order of precedence (later wins): the
    /// defaults, the paragraph style chain, the character style chain and the run's own marks (a
    /// `style` mark is read as its style's settings).
    public func characterValues(_ values: [Wiretuner_Doc_V1_TextMarkValue], paragraph: Wiretuner_Doc_V1_ParagraphProps) -> [Wiretuner_Doc_V1_TextMarkValue] {
        var base = TextStyleAttributes.overlay(defaults, paragraphStyle(paragraph).attrs)
        var own: [Wiretuner_Doc_V1_TextMarkValue] = []
        for value in values {
            if case .style(let ref)? = value.value {
                if let character = reference(ref, kind: .character) { base = TextStyleAttributes.overlay(base, character.attrs) }
            } else {
                own.append(value)
            }
        }
        return TextStyleAttributes.markValues(base) + own
    }

    /// The style attributes of a run before its own marks: defaults, paragraph style, character
    /// style.
    func styleAttributes(_ values: [Wiretuner_Doc_V1_TextMarkValue], paragraph: Wiretuner_Doc_V1_ParagraphProps) -> Wiretuner_Doc_V1_TextStyleAttrs {
        var base = TextStyleAttributes.overlay(defaults, paragraphStyle(paragraph).attrs)
        for value in values {
            if case .style(let ref)? = value.value, let character = reference(ref, kind: .character) {
                base = TextStyleAttributes.overlay(base, character.attrs)
            }
        }
        return base
    }

    // MARK: Overrides

    /// Where text differs from its styles (text-styles.adoc, "Overrides"): the paragraph registers
    /// (`ParagraphProps` field numbers) of paragraph `index` whose value differs from what its
    /// style resolves to, and the attributes (`TextStyleAttributes.key`) of the marks in it whose
    /// value differs from the style chain's.  Both empty: no *+*.
    public func overrides(in text: TextNode, paragraph index: Int) -> (paragraph: [UInt32], character: Set<String>) {
        let paragraphs = text.paragraphs
        guard paragraphs.indices.contains(index) else { return ([], []) }
        let paragraph = paragraphs[index]
        let base = TextStyleAttributes.overlay(defaults, paragraphStyle(paragraph.props).attrs)
        let styled = TextStyleAttributes.paragraph(base.paragraph).props
        let fields = TextStyleAttributes.setFields(paragraph.props).filter {
            TextStyleAttributes.paragraphValue(paragraph.props, $0) != TextStyleAttributes.paragraphValue(styled, $0)
        }
        var character: Set<String> = []
        for run in text.runs where run.range.overlaps(paragraph.range) {
            // A style's mark values name each attribute once.
            var styledValues: [String: Wiretuner_Doc_V1_TextMarkValue] = [:]
            for value in TextStyleAttributes.markValues(styleAttributes(run.values, paragraph: paragraph.props)) {
                styledValues[TextStyleAttributes.key(value)] = value
            }
            for value in run.values {
                if case .style? = value.value { continue }
                if case .inlineGraphic? = value.value {
                    character.insert(TextStyleAttributes.key(value))
                    continue
                }
                let key = TextStyleAttributes.key(value)
                if styledValues[key] != value { character.insert(key) }
            }
        }
        return (fields, character)
    }
}

extension EngineState {
    /// The text styles of this state.
    public var textStyles: TextStyleResolver { TextStyleResolver(self) }
}
