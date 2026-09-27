import AppKit
import WTCRDT
import WTModel
import WTProto

/// One keyboard type nudge (type-tools.adoc, "Adjusting with the keyboard"; TYPE-019).
struct TypeNudge: Equatable {
    enum Kind: Equatable {
        /// Kerning at the insertion point, or range kerning of the selection (% of an em).
        case kerning
        /// Baseline shift (points).
        case baselineShift
        /// Type size (points).
        case size
    }

    var kind: Kind
    var delta: Double

    static let kernLeft: UInt16 = 123, kernRight: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let comma: UInt16 = 43, period: UInt16 = 47

    /// The nudge a key means: kbd:[Cmd+Option+←/→] (kbd:[Shift] ×10), kbd:[Control+Option+↑/↓]
    /// (kbd:[Shift] ×10), kbd:[Cmd+Shift+,/.].  Nil for any other key.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        let coarse = flags.contains(.shift) ? 10.0 : 1.0
        let arrows = flags.subtracting(.shift)
        if keyCode == Self.kernLeft || keyCode == Self.kernRight, arrows == [.command, .option] {
            self.init(kind: .kerning, delta: (keyCode == Self.kernLeft ? -1 : 1) * coarse)
        } else if keyCode == Self.up || keyCode == Self.down, arrows == [.control, .option] {
            self.init(kind: .baselineShift, delta: (keyCode == Self.down ? -1 : 1) * coarse)
        } else if keyCode == Self.comma || keyCode == Self.period, flags == [.command, .shift] {
            self.init(kind: .size, delta: keyCode == Self.comma ? -1 : 1)
        } else {
            return nil
        }
    }

    init(kind: Kind, delta: Double) {
        self.kind = kind
        self.delta = delta
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }
}

/// The nudges of one window's Text tool: nudges of one kind on one selection within a second of
/// each other add up, and are written as one change -- one undo step, "Kern", "Baseline Shift"
/// or "Size" -- once a second passes without another (or another kind, or `flush`).
@MainActor
final class TypeNudger {
    private static var nudgers: [ObjectIdentifier: TypeNudger] = [:]

    /// The nudger of `editing` (one per window).
    static func nudger(for editing: ObjectEditing) -> TypeNudger {
        let key = ObjectIdentifier(editing)
        if let existing = nudgers[key] { return existing }
        let nudger = TypeNudger(editing: editing)
        nudgers[key] = nudger
        return nudger
    }

    static let pause: Duration = .seconds(1)

    unowned let editing: ObjectEditing
    var pause: Duration = TypeNudger.pause
    /// Waits out the pause (tests replace it to end the pause themselves).
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The nudge adding up, its node and the live range it applies to.
    private(set) var pending: (kind: TypeNudge.Kind, delta: Double, target: TextEditingSession.Target, range: Range<Int>)?
    private var timer: Task<Void, Never>?
    /// The change the last flush performed (tests await it).
    private(set) var written: Task<Wiretuner_Doc_V1_Change?, Never>?

    init(editing: ObjectEditing) {
        self.editing = editing
    }

    /// Adds `nudge` for the Text tool's selection; false without one.
    @discardableResult
    func nudge(_ nudge: TypeNudge) -> Bool {
        guard let session = editing.textSession, session.text != nil, session.node != nil || session.override != nil else { return false }
        let target = session.target
        let range = session.selectedRange
        if range.isEmpty, nudge.kind != .kerning {
            // At an insertion point, baseline shift and size become the pending format of what is typed next.
            flush()
            let values = session.formatRuns.last ?? []
            session.format(Self.mark(nudge.kind, pairKerning: false, values: values, delta: nudge.delta))
            return true
        }
        if let pending, pending.kind != nudge.kind || pending.target != target || pending.range != range { flush() }
        let delta = (pending?.delta ?? 0) + nudge.delta
        pending = (nudge.kind, delta, target, range)
        timer?.cancel()
        let pause = pause, sleep = sleep
        timer = Task { [weak self] in
            try? await sleep(pause)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
        return true
    }

    /// Writes the nudges added up so far.
    @discardableResult
    func flush() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        timer?.cancel()
        timer = nil
        guard let pending else { return nil }
        self.pending = nil
        let state = editing.document.state
        let command: (any WTModel.Command)?
        switch pending.target {
        case .node(let node):
            command = state.textNode(node).flatMap { Self.command(pending.kind, delta: pending.delta, node: node, range: pending.range, in: $0) }
        case .override(let instance, let master):
            // Inside an instance: the same marks on its text override (LIB-027).
            command = Symbols.textNode(master, in: instance, state: state).flatMap { text in
                Self.marks(pending.kind, delta: pending.delta, range: pending.range, in: text).map { label, marks in
                    OverrideText(instance, master: master, edits: marks.map { .mark($0.range, $0.value) }, label: label)
                }
            }
        default:
            command = nil
        }
        guard let command else { return nil }
        written = editing.perform(command)
        return written
    }

    /// The marks `command` writes, by live range, with the label; nil when it writes nothing.
    static func marks(_ kind: TypeNudge.Kind, delta: Double, range: Range<Int>, in text: TextNode)
        -> (label: String, marks: [(range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)])? {
        guard delta != 0, text.length > 0 else { return nil }
        let label = switch kind {
        case .kerning: "Kern"
        case .baselineShift: "Baseline Shift"
        case .size: "Size"
        }
        if range.isEmpty {
            guard range.lowerBound > 0 else { return nil }
            let offset = range.lowerBound - 1
            return (label, [(offset..<offset + 1, mark(kind, pairKerning: true, values: text.values(at: offset), delta: delta))])
        }
        let marks = text.runs.compactMap { run -> (range: Range<Int>, value: Wiretuner_Doc_V1_TextMarkValue)? in
            let span = run.range.clamped(to: range)
            return span.isEmpty ? nil : (span, mark(kind, pairKerning: false, values: run.values, delta: delta))
        }
        return marks.isEmpty ? nil : (label, marks)
    }

    /// The marks of a nudge: at an insertion point a span-1 `kerning` mark on the character before
    /// it (kerning), or the run's value moved by `delta` over the run the caret is in (baseline
    /// shift, size); over a selection each run's value moved by `delta`.
    static func command(_ kind: TypeNudge.Kind, delta: Double, node: OpID, range: Range<Int>, in text: TextNode) -> (any WTModel.Command)? {
        guard let (label, marks) = marks(kind, delta: delta, range: range, in: text) else { return nil }
        let commands = marks.map { ApplyMark(node: node, from: text.anchor(at: $0.range.lowerBound), to: text.anchor(at: $0.range.upperBound), value: $0.value, label: label) }
        return range.isEmpty ? commands[0] : CommandBatch(label, commands)
    }

    /// The mark value moved by `delta` from the winning value in `values`.
    static func mark(_ kind: TypeNudge.Kind, pairKerning: Bool, values: [Wiretuner_Doc_V1_TextMarkValue], delta: Double) -> Wiretuner_Doc_V1_TextMarkValue {
        let attributes = TextLayoutReading.attributes(values)
        var value = Wiretuner_Doc_V1_TextMarkValue()
        switch kind {
        case .kerning where pairKerning: value.kerning = attributes.kerning + delta
        case .kerning: value.rangeKerning = attributes.rangeKerning + delta
        case .baselineShift: value.baselineShift = attributes.baselineShift + delta
        case .size: value.size = min(max(attributes.size + delta, 0.1), 10_000)
        }
        return value
    }
}
