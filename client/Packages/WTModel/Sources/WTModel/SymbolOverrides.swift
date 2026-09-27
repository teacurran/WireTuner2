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

extension SymbolFields {
    /// `Override.tail_paragraph` of override element `element` (STRUCT; LIB-027).
    public static func overrideTailParagraph(_ element: OpID) -> RegisterPath { override(element).child(9) }
}

/// One edit of an instance's text override, in live offsets of the text as the instance shows it.
public enum OverrideTextEdit: Hashable, Sendable {
    /// Types `string` at `offset`.
    case insert(String, at: Int)
    /// Deletes the characters in `range`.
    case delete(Range<Int>)
    /// Types `string` over the characters in `range` (typing over a selection; one change).
    case replace(Range<Int>, with: String)
    /// Types `string` at `offset` under `marks` (a placeholder under its field's mark; typing in
    /// the pending format).
    case insertMarked(String, at: Int, marks: [Wiretuner_Doc_V1_TextMarkValue])
    /// One mark over the characters in `range`, as `ApplyMark` writes it (a cleared value removes
    /// the attribute; an empty range writes nothing) (LIB-027).
    case mark(Range<Int>, Wiretuner_Doc_V1_TextMarkValue)
    /// The paragraph registers `fields` (paths below `ParagraphProps`) from `props` on every
    /// paragraph `range` touches -- the caret's for an empty range -- as `SetParagraph` writes
    /// them: on a newline's own registers, and for the last paragraph on `Override.tail_paragraph`
    /// (the master's tail paragraph copied there with the first such write) (LIB-027).
    case paragraph(Range<Int>, Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]])
}

/// Editing a text block of an instance (the Text tool inside an instance; library.adoc, "Text tool
/// inside an instance"; LIB-025, formatting LIB-027).  When the instance has no live `TEXT`
/// override for the block, the same change creates the element and inserts a copy of the master's
/// characters, marks and newline paragraph registers as fresh inserts into it, then applies the
/// edits to the copy; afterwards edits go to the element's text, which merges as text always does.
/// Several edits are one change, applied in order, each in the offsets the one before left.
/// "Override text" unless given; a single insert coalesces as typing does.
public struct OverrideText: Command {
    public var instance: OpID
    public var master: OpID
    public var edits: [OverrideTextEdit]
    public let label: String

    public init(_ instance: OpID, master: OpID, edit: OverrideTextEdit) {
        self.init(instance, master: master, edits: [edit])
    }

    public init(_ instance: OpID, master: OpID, edits: [OverrideTextEdit], label: String = "Override text") {
        self.instance = instance
        self.master = master
        self.edits = edits
        self.label = label
    }

    /// The first edit (the only one for typing).
    public var edit: OverrideTextEdit { edits[0] }

    public var coalescing: UndoCoalescing {
        guard edits.count == 1, case .insert(let string, _) = edit else { return .none }
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
        var editor: Editor
        if let existing = Symbols.liveOverrides(of: instance, in: state)[key], let element = OpID(element: existing.id) {
            let field = SymbolFields.overrideText(element)
            let sequence = state.text(instance, field) ?? TextSequence()
            var newlines: Set<OpID> = []
            for char in sequence.liveChars where sequence.codepoint(char) == 0x0A { newlines.insert(char) }
            editor = Editor(node: instance, element: element, field: field, chars: sequence.liveChars, newlines: newlines,
                            hasTail: existing.hasTailParagraph, masterTail: source.props.tailParagraph)
            editor.stableOrigins = { state.insertionOrigins(instance, field, at: $0, stableSeq: 0) }
        } else {
            // First edit: the element, then the master's text copied into it, then the edits.
            var created = Wiretuner_Doc_V1_Override()
            created.masterNode = master.proto
            created.property = .text
            var values = Wiretuner_Doc_V1_NodeProps()
            values.instance.overrides = [created]
            let last = state.liveElements(instance, SymbolFields.overrides).last.flatMap { state.position(instance, SymbolFields.overrides, $0) }
            let element = builder.append(Ops.elementInsert(instance, SymbolFields.overrides, positions: try PathEditing.keys(between: last, and: nil, count: 1),
                                                           values: values))
            let field = SymbolFields.overrideText(element)
            let copied = TextCopying.copy(source.string, runs: source.runs, paragraphs: source.paragraphs.compactMap { $0.terminator == nil ? nil : $0.props },
                                          into: instance, field: field, builder: &builder)
            let newlines = Set(zip(copied, source.string.unicodeScalars).filter { $0.1 == "\n" }.map(\.0))
            editor = Editor(node: instance, element: element, field: field, chars: copied, newlines: newlines, hasTail: false,
                            masterTail: source.props.tailParagraph)
        }
        for edit in edits { try editor.apply(edit, builder: &builder) }
    }

    /// The override's live characters as the change so far leaves them, and how each edit is
    /// written against them.
    struct Editor {
        let node: OpID
        let element: OpID
        let field: RegisterPath
        var chars: [OpID]
        var newlines: Set<OpID>
        /// Whether the element already carries tail paragraph registers.
        var hasTail: Bool
        let masterTail: Wiretuner_Doc_V1_ParagraphProps
        /// The engine's origins for an insert at an offset of the state before the change; used
        /// for the change's first insert into an existing override.
        var stableOrigins: ((Int) -> (left: OpID, right: OpID))?

        mutating func origins(at offset: Int) -> (left: OpID, right: OpID) {
            if let stable = stableOrigins {
                stableOrigins = nil
                return stable(offset)
            }
            return (offset > 0 ? chars[offset - 1] : .zero, offset < chars.count ? chars[offset] : .zero)
        }

        func check(_ range: Range<Int>) throws {
            guard range.lowerBound >= 0, range.upperBound <= chars.count else { throw TextEditError.invalidValue("range") }
        }

        mutating func insert(_ string: String, at offset: Int, marks: [Wiretuner_Doc_V1_TextMarkValue], builder: inout ChangeBuilder) {
            let scalars = Array(string.unicodeScalars)
            guard !scalars.isEmpty else { return }
            let (left, right) = origins(at: offset)
            let first = builder.append(Ops.textInsert(node, field, string, left: left, right: right))
            let ids = (0..<scalars.count).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
            for (id, scalar) in zip(ids, scalars) where scalar == "\n" { newlines.insert(id) }
            for value in marks {
                builder.append(TextEditing.mark(node, value, first: ids[0], last: ids[ids.count - 1], next: right, field: field))
            }
            chars.insert(contentsOf: ids, at: offset)
        }

        mutating func delete(_ range: Range<Int>, builder: inout ChangeBuilder) {
            for op in TextCopying.deletes(node, field, Array(chars[range])) { builder.append(op) }
            chars.removeSubrange(range)
        }

        mutating func apply(_ edit: OverrideTextEdit, builder: inout ChangeBuilder) throws {
            switch edit {
            case .insert(let string, let offset), .insertMarked(let string, let offset, _):
                guard (0...chars.count).contains(offset) else { throw TextEditError.invalidValue("offset") }
                var marks: [Wiretuner_Doc_V1_TextMarkValue] = []
                if case .insertMarked(_, _, let given) = edit { marks = given }
                insert(string, at: offset, marks: marks, builder: &builder)
            case .delete(let range):
                try check(range)
                delete(range, builder: &builder)
            case .replace(let range, let string):
                try check(range)
                // Typed after the replaced characters (their tombstones keep the place), then they go.
                insert(string, at: range.upperBound, marks: [], builder: &builder)
                delete(range, builder: &builder)
            case .mark(let range, let value):
                try check(range)
                guard value.value != nil else { throw TextEditError.invalidValue("value") }
                guard !range.isEmpty else { return }
                let next = range.upperBound < chars.count ? chars[range.upperBound] : .zero
                builder.append(TextEditing.mark(node, value, first: chars[range.lowerBound], last: chars[range.upperBound - 1], next: next, field: field))
            case .paragraph(let range, let props, let fields):
                try check(range)
                guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty && $0[0] != TextFields.tabsField }) else { throw TextEditError.invalidValue("fields") }
                writeParagraphs(range, props, fields: fields, builder: &builder)
            }
        }

        /// The paragraphs `range` touches, as the newlines ending them (nil: the last paragraph),
        /// by `TextNode.paragraphs(touching:)`'s rule.
        func terminators(_ range: Range<Int>) -> [OpID?] {
            var paragraphs: [(end: Int, terminator: OpID?)] = []
            for (offset, char) in chars.enumerated() where newlines.contains(char) { paragraphs.append((offset + 1, char)) }
            paragraphs.append((chars.count, nil))
            func index(_ offset: Int) -> Int { paragraphs.firstIndex { offset < $0.end } ?? paragraphs.count - 1 }
            let first = index(range.lowerBound)
            let last = range.isEmpty ? first : index(range.upperBound - 1)
            return paragraphs[first...last].map(\.terminator)
        }

        mutating func writeParagraphs(_ range: Range<Int>, _ props: Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]], builder: inout ChangeBuilder) {
            for terminator in terminators(range) {
                if let newline = terminator {
                    NodeCopier.writeParagraphFields(props, fields: fields, newline: newline, node: node, field: field, builder: &builder)
                    continue
                }
                var written = props
                var paths = fields
                if !hasTail {
                    // The first write of the last paragraph's settings takes the master's with it.
                    written = Self.laid(props, fields: fields, over: masterTail)
                    let own = TextEditing.presentFields(masterTail).filter { $0 != TextFields.tabsField }.map { [$0] }
                    paths = own.filter { path in !fields.contains { $0.starts(with: path) || path.starts(with: $0) } } + fields
                    hasTail = true
                }
                var element = Wiretuner_Doc_V1_Override()
                element.tailParagraph = written
                var values = Wiretuner_Doc_V1_NodeProps()
                values.instance.overrides = [element]
                let base = SymbolFields.overrideTailParagraph(self.element)
                builder.append(Ops.set(node, paths.map { $0.reduce(base) { $0.child($1) } }, values: values))
            }
        }

        /// `base` with the registers `fields` taken from `props` (a top-level field whole).
        static func laid(_ props: Wiretuner_Doc_V1_ParagraphProps, fields: [[UInt32]], over base: Wiretuner_Doc_V1_ParagraphProps) -> Wiretuner_Doc_V1_ParagraphProps {
            var result = base
            result.tabs = []
            for top in Set(fields.map { $0[0] }) {
                switch top {
                case 1: result.alignment = props.alignment
                case 2: result.raggedWidth = props.raggedWidth
                case 3: result.flushZone = props.flushZone
                case 4: result.leftIndent = props.leftIndent
                case 5: result.rightIndent = props.rightIndent
                case 6: result.firstLineIndent = props.firstLineIndent
                case 7: result.spaceAbove = props.spaceAbove
                case 8: result.spaceBelow = props.spaceBelow
                case 10: result.hyphenation = props.hyphenation
                case 11: result.rule = props.rule
                case 12: result.hangPunctuation = props.hangPunctuation
                case 13: result.keepLines = props.keepLines
                case 14: result.keepWithNext = props.keepWithNext
                case 15: result.wordSpacing = props.wordSpacing
                case 16: result.letterSpacing = props.letterSpacing
                default: result.style = props.style
                }
            }
            return result
        }
    }
}

/// Copying characters and marks into a TEXT field as fresh inserts.
enum TextCopying {
    /// Inserts `string` at the start of the (empty) TEXT field `field` of `node` with one mark per
    /// value of each of `runs` (live offsets into `string`) and the paragraph registers of each of
    /// its newlines (`paragraphs`, in order); returns the new characters' ids.
    @discardableResult
    static func copy(_ string: String, runs: [TextMarkRun], paragraphs: [Wiretuner_Doc_V1_ParagraphProps] = [], into node: OpID, field: RegisterPath,
                     builder: inout ChangeBuilder) -> [OpID] {
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
        var newline = 0
        for (offset, scalar) in string.unicodeScalars.enumerated() where scalar == "\n" {
            defer { newline += 1 }
            guard newline < paragraphs.count else { break }
            NodeCopier.writeParagraph(paragraphs[newline], newline: ids[offset], node: node, field: field, builder: &builder)
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
    /// The override element whose text it is (nil: the master's).
    public var element: OpID? = nil
}

/// An instance's artwork as resolved (`Symbols.resolvedArtwork(of:)`): the symbol's children as
/// node trees with the live overrides applied -- hidden subtrees left out, basic fill and stroke
/// colours substituted, image sources swapped -- each tree's `source` the master node it came
/// from, and every text block's text (the override's where there is one) by master node.
public struct ResolvedArtwork: Hashable, Sendable {
    public var symbol: OpID
    public var nodes: [NodeTree]
    public var texts: [OpID: ResolvedText]

    /// The text blocks drawn (the keys of `texts`) in stacking order, bottom first: what the Text
    /// tool can click into.
    public var textBlocks: [OpID] {
        var result: [OpID] = []
        func collect(_ tree: NodeTree) {
            if case .text? = tree.props.kind, let master = tree.source { result.append(master) }
            tree.children.forEach(collect)
        }
        nodes.forEach(collect)
        return result
    }
}

extension Symbols {
    /// `instance`'s artwork with its live overrides applied, after the read-time rules; nil for an
    /// instance of a missing symbol (or a cut one).  Built fresh; `ResolvedArtworkCache` keeps it.
    public static func resolvedArtwork(of instance: OpID, in state: EngineState) -> ResolvedArtwork? {
        guard let symbol = symbol(of: instance, in: state) else { return nil }
        let overrides = liveOverrides(of: instance, in: state)
        let nodes = artwork(of: symbol, in: state).compactMap { SymbolEditing.resolved($0, state: state, overrides) }
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

    /// Text block `master` as `instance` shows it, for layout and editing (LIB-025, "Text tool
    /// inside an instance"): the characters, marks and paragraph registers of its live `TEXT`
    /// override where there is one -- with the override's tail paragraph when it has one (LIB-027)
    /// -- else the master's own; the master's block, inset, columns and transform either way (its
    /// `id` is the master's).  Nil when `master` is
    /// not a text block the instance draws.
    public static func textNode(_ master: OpID, in instance: OpID, state: EngineState) -> TextNode? {
        guard let symbol = symbol(of: instance, in: state), artworkNodes(of: symbol, in: state).contains(master) else { return nil }
        if let override = liveOverrides(of: instance, in: state)[OverrideKey(master: master, property: .text)], let element = OpID(element: override.id),
           let text = TextNode(master, text: instance, field: SymbolFields.overrideText(element),
                               tailParagraph: override.hasTailParagraph ? override.tailParagraph : nil, in: state) {
            return text
        }
        return TextNode(master, in: state)
    }

    /// Master node `master`'s own space → its symbol's space: its transform and those of the
    /// groups between it and the symbol (the symbol's own is not applied).  Nil when `master` is
    /// not in `symbol`'s artwork.
    public static func symbolSpaceTransform(of master: OpID, in symbol: OpID, state: EngineState) -> AffineTransform? {
        var result = AffineTransform.identity
        var current: OpID? = master
        while let id = current, id != symbol {
            result = result.concatenating(Objects.transform(of: id, in: state))
            current = state.store.placement(id)?.parent
        }
        return current == symbol ? result : nil
    }

    /// Master node `master`'s own space → pasteboard as `instance` draws it: through the groups to
    /// the symbol, the symbol's origin to the instance's place, and the instance's own placement
    /// (its transform, groups and layer).  Nil when the instance does not draw `master`'s symbol.
    public static func pasteboardTransform(ofMaster master: OpID, in instance: OpID, state: EngineState) -> AffineTransform? {
        guard let symbol = symbol(of: instance, in: state), let inner = symbolSpaceTransform(of: master, in: symbol, state: state) else { return nil }
        let origin = state.props(symbol).symbol.origin
        return inner.concatenating(.translation(x: -origin.x, y: -origin.y)).concatenating(Objects.pasteboardTransform(of: instance, in: state))
    }

    /// The text master text block `master` shows in `instance`.
    static func resolvedText(_ master: OpID, instance: OpID, overrides: [OverrideKey: Wiretuner_Doc_V1_Override], in state: EngineState) -> ResolvedText {
        if let override = overrides[OverrideKey(master: master, property: .text)], let element = OpID(element: override.id),
           let sequence = state.text(instance, SymbolFields.overrideText(element)) {
            let runs = sequence.runs.map { run in
                TextMarkRun(range: run.start..<run.start + run.length,
                            values: run.attributes.compactMap { try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: $0.value) })
            }
            return ResolvedText(string: sequence.string, runs: runs, isOverride: true, element: element)
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

extension DataPlaceholders {
    /// *Insert Field* inside an instance (LIB-027): the edit typing `{{name}}` of `field` at live
    /// offset `offset` of a text override under the field's mark and the formats in `marks`, as
    /// `InsertPlaceholder` types it in a block; nil when `field` is not a field.
    public static func overrideInsert(field: OpID, at offset: Int, marks: [Wiretuner_Doc_V1_TextMarkValue], in state: EngineState) -> OverrideTextEdit? {
        guard let info = DataModel(state).field(field) else { return nil }
        return .insertMarked("{{\(info.name)}}", at: offset, marks: formats(marks) + [mark(field)])
    }

    /// A completed `{{name}}` typed just before `caret` in `text` (an instance's text as it shows
    /// it) retyped under its field's mark, as `ConvertTypedPlaceholder` does in a block (LIB-027);
    /// nil when there is none.
    public static func overrideConversion(in text: TextNode, before caret: Int, state: EngineState) -> [OverrideTextEdit]? {
        guard let found = completed(in: text, before: caret) else { return nil }
        let field = DataModel(state).field(named: found.name)
        return [.delete(found.range), .insertMarked("{{\(field?.name ?? found.name)}}", at: found.range.lowerBound,
                                                    marks: formats(text.values(at: found.range.lowerBound)) + [mark(field?.id)])]
    }

    /// `marks` without a `field` mark.
    static func formats(_ marks: [Wiretuner_Doc_V1_TextMarkValue]) -> [Wiretuner_Doc_V1_TextMarkValue] {
        marks.filter { if case .field? = $0.value { return false } else { return true } }
    }
}

extension Symbols {
    /// The master text block whose override `field` names (`SymbolFields.overrideText` of one of
    /// `instance`'s override elements, a remote caret's TEXT field; LIB-027); nil for any other
    /// field or an element the instance does not hold.
    public static func overrideMaster(ofTextField field: RegisterPath, in instance: OpID, state: EngineState) -> OpID? {
        guard field.segments.count == 4, case .element(let element) = field.segments[2], field == SymbolFields.overrideText(element),
              state.nodeKind(instance) == .instance else { return nil }
        return state.props(instance).instance.overrides.first { OpID(element: $0.id) == element }.map { OpID($0.masterNode) }
    }
}
