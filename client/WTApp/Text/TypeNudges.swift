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
    /// The nudge adding up, its node and the live range it applies to.
    private(set) var pending: (kind: TypeNudge.Kind, delta: Double, node: OpID, range: Range<Int>)?
    private var timer: Task<Void, Never>?
    /// The change the last flush performed (tests await it).
    private(set) var written: Task<Wiretuner_Doc_V1_Change?, Never>?

    init(editing: ObjectEditing) {
        self.editing = editing
    }

    /// Adds `nudge` for the Text tool's selection; false without one.
    @discardableResult
    func nudge(_ nudge: TypeNudge) -> Bool {
        guard let session = editing.textSession, let node = session.node, session.text != nil else { return false }
        let range = session.selectedRange
        if range.isEmpty, nudge.kind != .kerning {
            // At an insertion point, baseline shift and size become the pending format of what is typed next.
            flush()
            let values = session.formatRuns.last ?? []
            session.format(Self.mark(nudge.kind, pairKerning: false, values: values, delta: nudge.delta))
            return true
        }
        if let pending, pending.kind != nudge.kind || pending.node != node || pending.range != range { flush() }
        let delta = (pending?.delta ?? 0) + nudge.delta
        pending = (nudge.kind, delta, node, range)
        timer?.cancel()
        let pause = pause
        timer = Task { [weak self] in
            try? await Task.sleep(for: pause)
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
        guard let pending, let text = editing.document.state.textNode(pending.node) else {
            self.pending = nil
            return nil
        }
        self.pending = nil
        guard let command = Self.command(pending.kind, delta: pending.delta, node: pending.node, range: pending.range, in: text) else { return nil }
        written = editing.perform(command)
        return written
    }

    /// The marks of a nudge: at an insertion point a span-1 `kerning` mark on the character before
    /// it (kerning), or the run's value moved by `delta` over the run the caret is in (baseline
    /// shift, size); over a selection each run's value moved by `delta`.
    static func command(_ kind: TypeNudge.Kind, delta: Double, node: OpID, range: Range<Int>, in text: TextNode) -> (any WTModel.Command)? {
        guard delta != 0, text.length > 0 else { return nil }
        let label = switch kind {
        case .kerning: "Kern"
        case .baselineShift: "Baseline Shift"
        case .size: "Size"
        }
        if range.isEmpty {
            guard range.lowerBound > 0 else { return nil }
            let offset = range.lowerBound - 1
            let values = text.values(at: offset)
            let value = mark(kind, pairKerning: true, values: values, delta: delta)
            return ApplyMark(node: node, from: text.anchor(at: offset), to: text.anchor(at: offset + 1), value: value, label: label)
        }
        let commands: [any WTModel.Command] = text.runs.compactMap { run in
            let span = run.range.clamped(to: range)
            guard !span.isEmpty else { return nil }
            return ApplyMark(node: node, from: text.anchor(at: span.lowerBound), to: text.anchor(at: span.upperBound),
                             value: mark(kind, pairKerning: false, values: run.values, delta: delta), label: label)
        }
        return commands.isEmpty ? nil : CommandBatch(label, commands)
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
