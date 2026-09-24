import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel

/// A text field that applies as the user types (names-notes.adoc: "Names and notes apply as you
/// type; there is nothing to confirm"; OBJ-021): each burst of keystrokes is written once the
/// typing has paused for `idle` (200 ms), as one change and one undo step, and input stops at
/// `limit` characters.  The APP-007 rule holds while a burst is pending: a remote change of the
/// same register does not replace the draft; it shows once the burst is written or discarded.
@MainActor
@Observable
final class IdleTextEditor {
    static let idle: Duration = .milliseconds(200)

    /// What the field shows.
    private(set) var text: String
    /// The document's value as last bound; nil when the selection's values differ.
    private(set) var value: String?
    private(set) var draftIsDirty = false
    let limit: Int
    @ObservationIgnored let idle: Duration
    /// Where a burst goes: the view connects the current selection's writer on every render.
    @ObservationIgnored var writer: ((String) -> Void)?
    /// The writer when the burst began, so a burst written after the selection changed goes to
    /// the objects it was typed for.
    @ObservationIgnored private var burstWriter: ((String) -> Void)?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Signals input refused at the limit.
    @ObservationIgnored var beep: @MainActor () -> Void = NSSound.beep

    init(value: String?, limit: Int, idle: Duration = IdleTextEditor.idle) {
        self.value = value
        self.limit = limit
        self.idle = idle
        text = value ?? ""
    }

    func connect(_ writer: @escaping (String) -> Void) {
        self.writer = writer
    }

    /// The selection's value changed: shown unless a burst is pending.
    func bind(_ value: String?) {
        guard value != self.value else { return }
        self.value = value
        if !draftIsDirty { text = value ?? "" }
    }

    /// A keystroke: the text past the limit is refused; the burst restarts its idle wait.
    func edit(_ typed: String) {
        var typed = typed
        if typed.count > limit {
            typed = String(typed.prefix(limit))
            beep()
        }
        guard typed != text else { return }
        if !draftIsDirty { burstWriter = writer }
        text = typed
        draftIsDirty = true
        pending?.cancel()
        let idle = idle
        pending = Task { [weak self] in
            try? await Task.sleep(for: idle)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the pending burst now (the idle wait ended, or focus left the field).
    func flush() {
        pending?.cancel()
        pending = nil
        guard draftIsDirty else { return }
        (burstWriter ?? writer)?(text)
        value = text
        burstWriter = nil
        draftIsDirty = false
    }

    /// kbd:[Esc]: drops the pending burst and shows the document's value.
    func cancel() {
        pending?.cancel()
        pending = nil
        burstWriter = nil
        draftIsDirty = false
        text = value ?? ""
    }

    var isPending: Bool { pending != nil }
}

/// The Name field (one line, 256 characters) or the Note field (several lines, 8,192).
struct IdleTextField: View {
    let title: String
    let value: String?
    let limit: Int
    let multiline: Bool
    let identifier: String
    let commit: (String) -> Void
    @State private var editor: IdleTextEditor
    @FocusState private var focused: Bool

    init(title: String, value: String?, limit: Int, multiline: Bool = false, identifier: String, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.limit = limit
        self.multiline = multiline
        self.identifier = identifier
        self.commit = commit
        _editor = State(initialValue: IdleTextEditor(value: value, limit: limit))
    }

    static func text(_ editor: IdleTextEditor) -> Binding<String> {
        Binding(get: { editor.text }, set: { editor.edit($0) })
    }

    static func focusing(_ editor: IdleTextEditor) -> (Bool, Bool) -> Void {
        { _, now in if !now { editor.flush() } }
    }

    static func binding(_ editor: IdleTextEditor) -> (String?, String?) -> Void {
        { _, now in editor.bind(now) }
    }

    var body: some View {
        let _ = editor.connect(commit)
        Group {
            if multiline {
                TextField(title, text: Self.text(editor), prompt: Text(value == nil ? "Mixed" : ""), axis: .vertical).lineLimit(2...6)
            } else {
                TextField(title, text: Self.text(editor), prompt: Text(value == nil ? "Mixed" : ""))
            }
        }
        .focused($focused)
        .onSubmit(editor.flush)
        .onExitCommand(perform: editor.cancel)
        .onChange(of: focused, Self.focusing(editor))
        .onChange(of: value, Self.binding(editor))
        .accessibilityIdentifier(identifier)
    }
}

/// Change labels that name the object (names-notes.adoc: "The Undo menu and the document
/// history name changes by object name when there is one", `Move "Logo mark"`).
enum NamedChange {
    /// `command` under `Move "name"` when it moves one named object; otherwise unchanged.
    static func move(_ command: any WTModel.Command, nodes: [OpID], state: EngineState) -> any WTModel.Command {
        guard let label = state.namedLabel("Move", for: nodes) else { return command }
        return CompositeCommand(label, [command])
    }
}
