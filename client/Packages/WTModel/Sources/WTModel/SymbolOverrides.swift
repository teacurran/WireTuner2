import Synchronization
import WTCRDT
import WTGeometry
import WTProto

// LIB-025: text overrides, override resolution and its cache (library.adoc, "Overriding parts of
// an instance", "Merge semantics" and "Client").  Fill, stroke, visibility and image overrides are
// `SetOverride` / `ResetOverrides` (LIB-026); the read-time rules are `Symbols.liveOverrides`.

extension SymbolFields {
    /// `Override.text` of override element `element` (MERGE_TEXT).
    public static func overrideText(_ element: OpID) -> RegisterPath { override(element).child(4) }
}

/// One edit of an instance's text override, in live offsets of the text as the instance shows it.
public enum OverrideTextEdit: Hashable, Sendable {
    /// Types `string` at `offset`.
    case insert(String, at: Int)
    /// Deletes the characters in `range`.
    case delete(Range<Int>)
}

/// Typing into a text block of an instance (the Text tool inside an instance; library.adoc, "Text
/// tool inside an instance").  When the instance has no live `TEXT` override for the block, the
/// same change creates the element and inserts a copy of the master's characters and marks as
/// fresh inserts into it, then applies the edit to the copy; afterwards edits go to the element's
/// text, which merges as text always does.  "Override text"; typing coalesces as typing does.
public struct OverrideText: Command {
    public var instance: OpID
    public var master: OpID
    public var edit: OverrideTextEdit
    public var label: String { "Override text" }

    public init(_ instance: OpID, master: OpID, edit: OverrideTextEdit) {
        self.instance = instance
        self.master = master
        self.edit = edit
    }

    public var coalescing: UndoCoalescing {
        guard case .insert(let string, _) = edit else { return .none }
        let endsWord = string.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .connectorPunctuation, .dashPunctuation, .openPunctuation,
                 .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation: true
            default: false
            }
        }
        return .typing(node: instance, field: SymbolFields.overrides.element(master), endsWord: endsWord)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.nodeKind(instance) == .instance, Objects.isObject(instance, in: state) else { throw SymbolError.notAnInstance(instance) }
        guard !Objects.isEffectivelyLocked(instance, in: state) else { return }
        guard let symbol = Symbols.symbol(of: instance, in: state), Symbols.artworkNodes(of: symbol, in: state).contains(master),
              let source = TextNode(master, in: state) else { throw SymbolError.notOverridable(master) }
        let key = OverrideKey(master: master, property: .text)
        if let existing = Symbols.liveOverrides(of: instance, in: state)[key], let element = OpID(element: existing.id) {
            let field = SymbolFields.overrideText(element)
            let sequence = state.text(instance, field) ?? TextSequence()
            try Self.apply(edit, node: instance, field: field, chars: sequence.liveChars,
                           origins: { state.insertionOrigins(instance, field, at: $0, stableSeq: 0) }, builder: &builder)
            return
        }
        // First edit: the element, then the master's text copied into it, then the edit.
        var created = Wiretuner_Doc_V1_Override()
        created.masterNode = master.proto
        created.property = .text
        var values = Wiretuner_Doc_V1_NodeProps()
        values.instance.overrides = [created]
        let last = state.liveElements(instance, SymbolFields.overrides).last.flatMap { state.position(instance, SymbolFields.overrides, $0) }
        let element = builder.append(Ops.elementInsert(instance, SymbolFields.overrides, positions: try PathEditing.keys(between: last, and: nil, count: 1),
                                                       values: values))
        let field = SymbolFields.overrideText(element)
        let copied = TextCopying.copy(source.string, runs: source.runs, into: instance, field: field, builder: &builder)
        try Self.apply(edit, node: instance, field: field, chars: copied, origins: { offset in
            (offset > 0 ? copied[offset - 1] : .zero, offset < copied.count ? copied[offset] : .zero)
        }, builder: &builder)
    }

    /// Appends `edit` against live characters `chars` of the TEXT field.
    static func apply(_ edit: OverrideTextEdit, node: OpID, field: RegisterPath, chars: [OpID], origins: (Int) -> (left: OpID, right: OpID),
                      builder: inout ChangeBuilder) throws {
        switch edit {
        case .insert(let string, let offset):
            guard (0...chars.count).contains(offset) else { throw TextEditError.invalidValue("offset") }
            guard !string.isEmpty else { return }
            let (left, right) = origins(offset)
            builder.append(Ops.textInsert(node, field, string, left: left, right: right))
        case .delete(let range):
            guard range.lowerBound >= 0, range.upperBound <= chars.count else { throw TextEditError.invalidValue("range") }
            for op in TextCopying.deletes(node, field, Array(chars[range])) { builder.append(op) }
        }
    }
}

/// Copying characters and marks into a TEXT field as fresh inserts.
enum TextCopying {
    /// Inserts `string` at the start of the (empty) TEXT field `field` of `node` with one mark per
    /// value of each of `runs` (live offsets into `string`); returns the new characters' ids.
    @discardableResult
    static func copy(_ string: String, runs: [TextMarkRun], into node: OpID, field: RegisterPath, builder: inout ChangeBuilder) -> [OpID] {
        let count = string.unicodeScalars.count
        guard count > 0 else { return [] }
        let first = builder.append(Ops.textInsert(node, field, string))
        let ids = (0..<count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
        for run in runs where !run.range.isEmpty && run.range.upperBound <= count {
            for value in run.values {
                var mark = Wiretuner_Doc_V1_TextMark()
                mark.node = node.proto
                mark.text = field.proto
                mark.start.char = ids[run.range.lowerBound].elementID
                mark.start.before = true
                mark.end.char = ids[run.range.upperBound - 1].elementID
                mark.value = value
                var op = Wiretuner_Doc_V1_Op()
                op.textMark = mark
                builder.append(op)
            }
        }
        return ids
    }

    /// `TextDelete` ops for live characters `ids` of `field`: one range per run of consecutive
    /// counters of one replica.
    static func deletes(_ node: OpID, _ field: RegisterPath, _ ids: [OpID]) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        var index = 0
        while index < ids.count {
            let first = ids[index]
            var count: UInt64 = 1
            while index + Int(count) < ids.count, ids[index + Int(count)] == OpID(counter: first.counter + count, replica: first.replica) {
                count += 1
            }
            ops.append(Ops.textDelete(node, field, first: first, count: count))
            index += Int(count)
        }
        return ops
    }
}

/// A text block's text as an instance shows it: the override's, or the master's.
public struct ResolvedText: Hashable, Sendable {
    public var string: String
    public var runs: [TextMarkRun]
    /// Whether a live `TEXT` override supplies it.
    public var isOverride: Bool
}

/// An instance's artwork as resolved (`Symbols.resolvedArtwork(of:)`): the symbol's children as
/// node trees with the live overrides applied -- hidden subtrees left out, basic fill and stroke
/// colours substituted, image sources swapped -- each tree's `source` the master node it came
/// from, and every text block's text (the override's where there is one) by master node.
public struct ResolvedArtwork: Hashable, Sendable {
    public var symbol: OpID
    public var nodes: [NodeTree]
    public var texts: [OpID: ResolvedText]
}

extension Symbols {
    /// `instance`'s artwork with its live overrides applied, after the read-time rules; nil for an
    /// instance of a missing symbol (or a cut one).  Built fresh; `ResolvedArtworkCache` keeps it.
    public static func resolvedArtwork(of instance: OpID, in state: EngineState) -> ResolvedArtwork? {
        guard let symbol = symbol(of: instance, in: state) else { return nil }
        let overrides = liveOverrides(of: instance, in: state)
        let nodes = state.liveChildren(symbol).compactMap { SymbolEditing.resolved($0, state: state, overrides) }
        var texts: [OpID: ResolvedText] = [:]
        func collect(_ tree: NodeTree) {
            if case .text? = tree.props.kind, let master = tree.source {
                texts[master] = resolvedText(master, instance: instance, overrides: overrides, in: state)
            }
            tree.children.forEach(collect)
        }
        nodes.forEach(collect)
        return ResolvedArtwork(symbol: symbol, nodes: nodes, texts: texts)
    }

    /// The text master text block `master` shows in `instance`.
    static func resolvedText(_ master: OpID, instance: OpID, overrides: [OverrideKey: Wiretuner_Doc_V1_Override], in state: EngineState) -> ResolvedText {
        if let override = overrides[OverrideKey(master: master, property: .text)], let element = OpID(element: override.id),
           let sequence = state.text(instance, SymbolFields.overrideText(element)) {
            let runs = sequence.runs.map { run in
                TextMarkRun(range: run.start..<run.start + run.length,
                            values: run.attributes.compactMap { try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: $0.value) })
            }
            return ResolvedText(string: sequence.string, runs: runs, isOverride: true)
        }
        let source = TextNode(master, in: state)
        return ResolvedText(string: source?.string ?? "", runs: source?.runs ?? [], isOverride: false)
    }
}

/// `Symbols.resolvedArtwork(of:)` cached per instance (library.adoc, "Override resolution"): an
/// entry is built once and reused until a change touches the instance or anything under its
/// symbol (`invalidate(by:state:)`), so resolving an instance with ten overrides costs one build
/// and a symbol edit rebuilds only the instances of that symbol.  Safe to share across threads.
public final class ResolvedArtworkCache: Sendable {
    private struct Entry: Sendable {
        var symbol: OpID?
        var artwork: ResolvedArtwork?
    }

    private let entries = Mutex<[OpID: Entry]>([:])
    private let counter = Mutex(0)

    public init() {}

    /// How many resolutions were built (not served from the cache).
    public var builds: Int { counter.withLock { $0 } }

    /// The resolved artwork of `instance` in `state`.
    public func artwork(of instance: OpID, in state: EngineState) -> ResolvedArtwork? {
        if let entry = entries.withLock({ $0[instance] }) { return entry.artwork }
        let artwork = Symbols.resolvedArtwork(of: instance, in: state)
        counter.withLock { $0 += 1 }
        entries.withLock { $0[instance] = Entry(symbol: artwork?.symbol ?? Symbols.symbol(of: instance, in: state), artwork: artwork) }
        return artwork
    }

    /// Drops the entries `change` may have altered (read against `state`, the state after it): an
    /// instance it wrote, and every instance of a symbol it wrote or wrote inside.  A change that
    /// creates, moves or deletes a symbol or touches the `symbols` tree drops everything.
    public func invalidate(by change: Wiretuner_Doc_V1_Change, state: EngineState) {
        var instances: Set<OpID> = []
        var symbols: Set<OpID> = []
        var everything = false
        for op in change.ops {
            for (node, _) in DocumentDisplayListBuilder.targets(op) {
                switch state.nodeKind(node) {
                case .instance?: instances.insert(node)
                case .symbol?: symbols.insert(node)
                default:
                    if node == WellKnown.symbols || state.store.kind(node) == 152 { everything = true }
                }
                if let symbol = Symbols.enclosingSymbol(of: node, in: state) { symbols.insert(symbol) }
            }
        }
        // A symbol nested in another (through an instance in its artwork) redraws its hosts.
        var grew = !symbols.isEmpty
        while grew {
            grew = false
            for host in Symbols.symbols(in: state) where !symbols.contains(host) {
                if Symbols.artworkNodes(of: host, in: state).contains(where: { Symbols.symbol(of: $0, in: state).map(symbols.contains) ?? false }) {
                    symbols.insert(host)
                    grew = true
                }
            }
        }
        entries.withLock { entries in
            if everything {
                entries = [:]
                return
            }
            entries = entries.filter { instance, entry in
                !instances.contains(instance) && !(entry.symbol.map(symbols.contains) ?? false)
            }
        }
    }
}
