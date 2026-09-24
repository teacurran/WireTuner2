import AppKit
import Observation
import WTModel

/// An editor of one property of the selection (object-panel.adoc, "Client"; APP-007).  The
/// framework applies one rule to every editor: `bind(selection:)` hands it the value the document
/// holds now (nil when the selected objects differ), and while `draftIsDirty` that value does not
/// replace what the user is typing -- the canvas shows the remote value and the field keeps the
/// keystrokes until `commit(value:)` writes them as a fresh change (a greater OpId, so it wins) or
/// kbd:[Esc] discards them and the document's value shows again.
@MainActor
protocol PropertyEditor: AnyObject {
    associatedtype Value: Equatable

    /// The value the selection holds now; nil shows `Mixed`.
    func bind(selection value: Value?)
    /// Writes `value` to the selection (one change) and ends the draft.
    func commit(value: Value)
    /// Whether the editor holds keystrokes not yet committed.
    var draftIsDirty: Bool { get }
}

/// How a field shows, reads and steps its value.
struct FieldFormat<Value: Equatable> {
    /// The text for a value; nil (mixed) is empty, the field shows the `Mixed` prompt.
    var format: (Value?) -> String
    /// The value typed text stands for, given the current value (`50%` of it); nil refuses it.
    var parse: (String, Value?) -> Value?
    /// The value `steps` arrow presses away from a value (kbd:[Up] +1, kbd:[Shift+Down] -10);
    /// nil when the field does not step.
    var step: ((Value?, Double) -> Value?)?
}

extension FieldFormat where Value == Double {
    /// A plain number (degrees, percentages, counts): steps by one.
    static var number: FieldFormat {
        FieldFormat(
            format: { value in value.map { $0.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) } ?? "" },
            parse: { text, _ in Double(text.trimmingCharacters(in: .whitespaces)) },
            step: { value, steps in value.map { $0 + steps } }
        )
    }

    /// A length in the document's unit (`Measure`: unit suffixes, `2p6`, arithmetic, `%` of the
    /// current value), stored in points and rounded to 1/1000 pt; steps by one document unit.
    static func measure(_ unit: MeasureUnit) -> FieldFormat {
        FieldFormat(
            format: { value in value.map { Measure.format($0, unit: unit, suffix: false) } ?? "" },
            parse: { text, value in try? Measure.parse(text, unit: unit, current: value ?? 0) },
            step: { value, steps in value.map { Measure.rounded($0 + steps * unit.points) } }
        )
    }
}

extension FieldFormat where Value == Double {
    /// A length in the document's units (`WTModel.Units`, DOC-003): suffixes -- a custom unit's
    /// name among them -- `7p6`, `+ - * /` with mixed units; `%` of the current value and
    /// parentheses through `Measure`.  Shown rounded to the unit's display precision, stored in
    /// points; steps by one document unit.
    static func length(_ units: Units) -> FieldFormat {
        let perUnit = units.pointsPerUnit(units.documentUnit)
        return FieldFormat(
            format: { value in value.map { units.format($0) } ?? "" },
            parse: { text, value in
                units.parse(text) ?? (try? Measure.parse(text, unit: units.documentUnit.measureUnit, current: value ?? 0))
            },
            step: { value, steps in value.map { $0 + steps * perUnit } }
        )
    }
}

extension FieldFormat where Value == String {
    /// Free text (a name, a note): any entry is accepted, `accepts` aside.
    static func text(accepts: @escaping (String) -> Bool = { _ in true }) -> FieldFormat {
        FieldFormat(format: { $0 ?? "" }, parse: { text, _ in accepts(text) ? text : nil }, step: nil)
    }
}

/// The state of one text field of the inspector: the draft the user types and the document value
/// it was started from, with the APP-007 focus-preservation rule.  Views stay thin: the field view
/// forwards keystrokes (`edit`), kbd:[Return] and kbd:[Tab] (`submit`), kbd:[Esc] (`cancel`), the
/// arrow keys (`step`) and focus changes (`focusChanged`), and re-binds when the value it shows
/// changes.
@MainActor
@Observable
final class FieldEditor<Value: Equatable>: PropertyEditor {
    /// What the field shows.
    private(set) var text: String
    /// The document's value as last bound; nil when the selection's values differ.
    private(set) var value: Value?
    private(set) var draftIsDirty = false
    /// The document's value changed while the draft was dirty: shown as a subtle highlight, not
    /// applied into the field (client.adoc, "Panels").
    private(set) var remoteChanged = false
    @ObservationIgnored private(set) var format: FieldFormat<Value>
    /// Where a commit goes: the view connects the current selection's writer on every render.
    @ObservationIgnored var writer: ((Value) -> Void)?
    /// The writer when the draft began, so a draft committed after the selection changed (a click
    /// on the canvas ends the edit) writes to the objects it was typed for.
    @ObservationIgnored private var draftWriter: ((Value) -> Void)?
    /// Signals refused input.
    @ObservationIgnored var beep: @MainActor () -> Void = NSSound.beep

    init(format: FieldFormat<Value>, value: Value?) {
        self.format = format
        self.value = value
        text = format.format(value)
    }

    /// Connects the writer of the current render (returns nothing, so a view body can call it).
    func connect(_ writer: @escaping (Value) -> Void) {
        self.writer = writer
    }

    func bind(selection value: Value?) {
        guard value != self.value else { return }
        self.value = value
        if draftIsDirty {
            remoteChanged = true
        } else {
            text = format.format(value)
        }
    }

    /// The format changed (the document's unit): an untouched field shows the value in it.
    func reformat(_ format: FieldFormat<Value>) {
        self.format = format
        if !draftIsDirty { text = format.format(value) }
    }

    /// A keystroke: the text becomes the draft.
    func edit(_ text: String) {
        guard text != self.text else { return }
        if !draftIsDirty { draftWriter = writer }
        self.text = text
        draftIsDirty = true
    }

    /// kbd:[Return] or kbd:[Tab]: commits the draft when it parses; refused input beeps and stays.
    /// An untouched field commits nothing (a `Mixed` field left alone leaves the objects different).
    @discardableResult
    func submit() -> Bool {
        guard draftIsDirty else { return false }
        guard let parsed = format.parse(text, value) else {
            beep()
            return false
        }
        commit(value: parsed)
        return true
    }

    func commit(value: Value) {
        (draftWriter ?? writer)?(value)
        // The value written is what the field stands on until the document says otherwise (a held
        // arrow key steps on from it before the change comes back).
        self.value = value
        draftWriter = nil
        draftIsDirty = false
        remoteChanged = false
        text = format.format(value)
    }

    /// kbd:[Esc]: discards the draft and shows what the document holds now.
    func cancel() {
        draftWriter = nil
        draftIsDirty = false
        remoteChanged = false
        text = format.format(value)
    }

    /// kbd:[Up] / kbd:[Down] (kbd:[Shift]: ten): commits the value `steps` away from the draft or
    /// the value.  False when the field does not step or there is nothing to step from (`Mixed`).
    @discardableResult
    func step(_ steps: Double) -> Bool {
        guard let step = format.step else { return false }
        let base = draftIsDirty ? format.parse(text, value) : value
        guard let next = step(base, steps) else { return false }
        commit(value: next)
        return true
    }

    /// Focus left the field (a click elsewhere): the draft commits, or reverts when it does not
    /// parse.
    func focusChanged(_ focused: Bool) {
        guard !focused, draftIsDirty, !submit() else { return }
        cancel()
    }

    /// The arrow steps a key press stands for: ±1, ±10 with kbd:[Shift]; nil for another key.
    static func steps(up: Bool?, shift: Bool) -> Double? {
        guard let up else { return nil }
        return (up ? 1 : -1) * (shift ? 10 : 1)
    }
}
