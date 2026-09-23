import Synchronization
import WTCRDT
import WTModel
import WTProto

/// The command a text command wrapper ran, kept so its undo grouping can be read after `execute`
/// (`InsertText` and `DeleteText` decide theirs while they build the change).
final class TextCommandBox: Sendable {
    private let value = Mutex<(any WTModel.Command)?>(nil)
    private let key = Mutex<UndoCoalescing?>(nil)

    var command: (any WTModel.Command)? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    /// A grouping the wrapper decided itself.
    var coalescing: UndoCoalescing? {
        get { key.withLock { $0 } }
        set { key.withLock { $0 = newValue } }
    }
}

/// The first keystroke into a block that does not exist yet (creating-text, "Merge semantics",
/// *Creation*): `CreateTextBlock` with that character, one change labelled "Type".  A single typed
/// character leaves the undo step open at it, so the rest of the first word joins it (the
/// grouping rule of `InsertText`).
struct TypeNewTextBlock: WTModel.Command {
    let create: CreateTextBlock
    /// Whether this is one keystroke (a paste or a committed input-method string is its own step).
    let typing: Bool
    private let box = TextCommandBox()

    init(_ create: CreateTextBlock, typing: Bool) {
        self.create = create
        self.typing = typing
    }

    var label: String { create.label }
    var coalescing: UndoCoalescing { box.coalescing ?? .none }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let first = builder.ops.count
        try create.execute(&builder, state: state)
        let scalars = Array(create.text.unicodeScalars)
        guard typing, create.text.count == 1, let last = scalars.last, !["\n", "\t", "\u{2028}", "\u{0C}", "\u{FFFC}"].contains(last) else { return }
        // The ids the ops took: each op the counters `EngineState.counters` says, from the start.
        var counter = builder.startCounter
        for op in builder.ops[..<first] { counter &+= EngineState.counters(op) }
        var node: OpID?
        var typed: OpID?
        for op in builder.ops[first...] {
            let id = OpID(counter: counter, replica: builder.replica)
            if case .create(let create)? = op.op, case .text? = create.props.kind { node = id }
            if case .textInsert? = op.op { typed = OpID(counter: counter + EngineState.counters(op) - 1, replica: builder.replica) }
            counter &+= EngineState.counters(op)
        }
        if let node, let typed {
            box.coalescing = .text(joins: nil, opens: .text(TextEditKey(node: node, kind: .typing, caret: typed, afterWhitespace: last.properties.isWhitespace)))
        }
    }
}

/// One edit at the text tool's selection, resolved against the state it runs on (creating-text,
/// "Typing"; editing-text, "Editing on the page"): the selection's anchors are turned into live
/// offsets when the change is built, so keystrokes queued behind one another each act on the text
/// the one before left.  Typing replaces a selection (one change, its own undo step) or inserts at
/// the insertion point (`InsertText` with the typing rule); the deletions remove a selection or,
/// at an insertion point, the character before (with the backspace grouping rule), the character
/// after, or the word before or after.
struct TextKeystroke: WTModel.Command {
    enum Action: Hashable, Sendable {
        case insert(String)
        case backspace
        case forwardDelete
        case deleteWordBackward
        case deleteWordForward
        /// Removes just the selection (Cut, or a line deletion the session resolved).
        case deleteSelection
    }

    let node: OpID
    let start: Anchor
    let end: Anchor
    let action: Action
    /// The pending format: marks over typed characters.
    let marks: [Wiretuner_Doc_V1_TextMarkValue]
    /// A keystroke (the undo grouping rule applies) rather than a paste or a committed string.
    let typing: Bool
    private let box = TextCommandBox()

    init(node: OpID, from start: Anchor, to end: Anchor, _ action: Action, marks: [Wiretuner_Doc_V1_TextMarkValue] = [], typing: Bool = true) {
        self.node = node
        self.start = start
        self.end = end
        self.action = action
        self.marks = marks
        self.typing = typing
    }

    var label: String {
        if case .insert = action { return "Type" }
        return "Delete text"
    }

    var coalescing: UndoCoalescing { box.command?.coalescing ?? .none }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let text = state.textNode(node) else { throw TextEditError.notText(node) }
        let range = try text.range(start, end)
        guard let command = command(text, range) else { return }
        box.command = command
        try command.execute(&builder, state: state)
    }

    /// What the action does to `range` of `text`; nil when it does nothing.
    private func command(_ text: TextNode, _ range: Range<Int>) -> (any WTModel.Command)? {
        func delete(_ deleted: Range<Int>, backspace: Bool = false) -> (any WTModel.Command)? {
            deleted.isEmpty ? nil : DeleteText(node: node, from: text.anchor(at: deleted.lowerBound), to: text.anchor(at: deleted.upperBound), backspace: backspace)
        }
        let scalars = Array(text.string.unicodeScalars)
        switch action {
        case .insert(let string):
            let insert = InsertText(node: node, text: string, at: text.anchor(at: range.upperBound), marks: marks, typing: typing && range.isEmpty)
            guard let removal = delete(range) else { return string.isEmpty ? nil : insert }
            return CommandBatch("Type", string.isEmpty ? [removal] : [removal, insert])
        case .deleteSelection:
            return delete(range)
        case .backspace:
            guard range.isEmpty else { return delete(range) }
            return range.lowerBound > 0 ? delete(range.lowerBound - 1..<range.lowerBound, backspace: typing) : nil
        case .forwardDelete:
            guard range.isEmpty else { return delete(range) }
            return delete(range.lowerBound..<min(range.lowerBound + 1, text.length))
        case .deleteWordBackward:
            guard range.isEmpty else { return delete(range) }
            return delete(TextNavigation.wordStart(before: range.lowerBound, in: scalars)..<range.lowerBound)
        case .deleteWordForward:
            guard range.isEmpty else { return delete(range) }
            return delete(range.lowerBound..<TextNavigation.wordEnd(after: range.lowerBound, in: scalars))
        }
    }
}
