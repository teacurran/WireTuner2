import SwiftUI
import WTModel

/// The inspector's text field (APP-007): a `FieldEditor` behind a `TextField`.  It commits on
/// kbd:[Return], kbd:[Tab] or a click elsewhere, discards on kbd:[Esc], steps with the arrow keys,
/// shows `Mixed` when the objects differ, and while the user types a remote change to the same
/// value tints the field instead of replacing the text.
struct InspectorField<Value: Equatable>: View {
    let title: String
    /// The value the selection holds; nil shows `Mixed`.
    let value: Value?
    let format: FieldFormat<Value>
    /// Changes when `format` does (the document's unit), so the field re-formats.
    var formatID: AnyHashable = 0
    let identifier: String
    let commit: (Value) -> Void
    @State private var editor: FieldEditor<Value>
    @FocusState private var focused: Bool

    init(title: String, value: Value?, format: FieldFormat<Value>, formatID: AnyHashable = 0, identifier: String, commit: @escaping (Value) -> Void) {
        self.title = title
        self.value = value
        self.format = format
        self.formatID = formatID
        self.identifier = identifier
        self.commit = commit
        _editor = State(initialValue: FieldEditor(format: format, value: value))
    }

    /// The text binding: reads the editor, keystrokes become its draft.
    static func text(_ editor: FieldEditor<Value>) -> Binding<String> {
        Binding(get: { editor.text }, set: { editor.edit($0) })
    }

    /// An arrow key press: steps the value when the field steps.
    /// A held key's repeats (`repeating`) preview the stepped value and write it once the key is
    /// released and the repeats pause (D-076); the first press writes at once.
    static func step(_ editor: FieldEditor<Value>, key: SwiftUI.KeyEquivalent, shift: Bool, repeating: Bool = false) -> KeyPress.Result {
        let up: Bool? = key == .upArrow ? true : key == .downArrow ? false : nil
        guard let steps = FieldEditor<Value>.steps(up: up, shift: shift) else { return .ignored }
        var stepped = false
        if repeating {
            ContinuousInput.settle { stepped = editor.step(steps) }
        } else {
            stepped = editor.step(steps)
        }
        return stepped ? .handled : .ignored
    }

    // The field's handlers, as closures the tests can call.

    /// kbd:[Return] (and kbd:[Tab], which ends editing through the focus change).
    static func submitting(_ editor: FieldEditor<Value>) -> () -> Void {
        { editor.submit() }
    }

    /// kbd:[Esc] in the field.
    static func cancelling(_ editor: FieldEditor<Value>) -> () -> Void {
        { editor.cancel() }
    }

    static func focusing(_ editor: FieldEditor<Value>) -> (Bool, Bool) -> Void {
        { _, now in editor.focusChanged(now) }
    }

    /// The selection's value changed (a remote change, undo, another selection).
    static func binding(_ editor: FieldEditor<Value>) -> (Value?, Value?) -> Void {
        { _, now in editor.bind(selection: now) }
    }

    static func reformatting(_ editor: FieldEditor<Value>, _ format: FieldFormat<Value>) -> (AnyHashable, AnyHashable) -> Void {
        { _, _ in editor.reformat(format) }
    }

    /// The tint of a field whose value someone else changed while the user types.
    static func highlight(_ editor: FieldEditor<Value>) -> SwiftUI.Color {
        editor.remoteChanged ? SwiftUI.Color.accentColor.opacity(0.18) : SwiftUI.Color.clear
    }

    static func help(_ editor: FieldEditor<Value>) -> String {
        editor.remoteChanged ? "Changed by someone else. Return keeps your value; Esc shows theirs." : ""
    }

    /// The accessibility value: what the field holds, and whether someone else changed it.
    static func accessibilityValue(_ editor: FieldEditor<Value>) -> String {
        editor.remoteChanged ? "\(editor.text), changed by someone else" : editor.text
    }

    var body: some View {
        let _ = editor.connect(commit)
        TextField(title, text: Self.text(editor), prompt: Text(value == nil ? "Mixed" : ""))
            .focused($focused)
            .onSubmit(Self.submitting(editor))
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { Self.step(editor, key: $0.key, shift: $0.modifiers.contains(.shift), repeating: $0.phase == .repeat) }
            .onExitCommand(perform: Self.cancelling(editor))
            .onChange(of: focused, Self.focusing(editor))
            .onChange(of: value, Self.binding(editor))
            .onChange(of: formatID, Self.reformatting(editor, format))
            .background(RoundedRectangle(cornerRadius: 3).fill(Self.highlight(editor)))
            .help(Self.help(editor))
            .accessibilityIdentifier(identifier)
            .accessibilityValue(Self.accessibilityValue(editor))
    }
}

/// A number field (degrees, percentages, counts).
struct CommitField: View {
    let title: String
    let value: Double?
    let identifier: String
    let commit: (Double) -> Void

    var body: some View {
        InspectorField(title: title, value: value, format: .number, identifier: identifier, commit: commit)
    }
}

/// A length in the document's unit: units, the pica-point form, arithmetic and `%` of the
/// current value, stepping by one unit.  With the document's `Units` (given, or the
/// `documentUnits` environment value a panel sets) every unit reads -- kyus and the document's
/// custom units included (DOC-003); without them the nearest `MeasureUnit` does.
struct MeasureField: View {
    let title: String
    /// The value in points; nil shows `Mixed`.
    let value: Double?
    let unit: MeasureUnit
    /// The document's units, overriding `unit` and the environment.
    var units: Units?
    let identifier: String
    let commit: (Double) -> Void
    @Environment(\.documentUnits) private var environmentUnits

    init(title: String, value: Double?, unit: MeasureUnit, identifier: String, commit: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.unit = unit
        self.identifier = identifier
        self.commit = commit
    }

    init(title: String, value: Double?, units: Units, identifier: String, commit: @escaping (Double) -> Void) {
        self.init(title: title, value: value, unit: units.documentUnit.measureUnit, identifier: identifier, commit: commit)
        self.units = units
    }

    var body: some View {
        if let units = units ?? environmentUnits {
            InspectorField(title: title, value: value, format: .length(units), formatID: units, identifier: identifier, commit: commit)
        } else {
            InspectorField(title: title, value: value, format: .measure(unit), formatID: unit, identifier: identifier, commit: commit)
        }
    }
}

extension EnvironmentValues {
    /// The front document's units for the length fields under a panel (`MeasureField`); nil
    /// leaves each field its own `MeasureUnit`.
    @Entry var documentUnits: Units?
}

/// Gives the length fields of `content` the front document's units, following a change of them.
struct DocumentUnitsScope<Content: View>: View {
    let selection: ActiveSelection?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let document = selection?.document
        let _ = document?.model?.revision
        content().environment(\.documentUnits, document?.unitConverter)
    }
}

/// A text field (a name, a note).
struct CommitTextField: View {
    let title: String
    let value: String?
    let identifier: String
    let commit: (String) -> Void

    var body: some View {
        InspectorField(title: title, value: value, format: .text(), identifier: identifier, commit: commit)
    }
}
