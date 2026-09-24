import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel

/// What the Script Editor holds (scripting.adoc, "Script Editor panel"; DATA-013): the script open
/// -- untitled, a file in the Scripts folder or a document script -- its buffer, the console, a run
/// in progress and the line and column of the last error.  btn:[Save] writes the file or the
/// document script (one change "Save script"); btn:[Save to Document] stores the buffer as a new
/// document script.  A remote change to the open document script shows *Reload* and keeps the
/// buffer.
@MainActor
@Observable
final class ScriptEditorModel {
    enum Choice: Hashable {
        case untitled
        case file(URL)
        case document(OpID)
    }

    static let untitledSource = "// A new script: runs on the front document.\nconsole.log(wt.document.name);\n"

    var text = ScriptEditorModel.untitledSource
    var name = "Untitled"
    private(set) var choice: Choice = .untitled
    private(set) var console: [ScriptConsoleEntry] = []
    private(set) var isRunning = false
    /// Where the last run's error is (1-based line and column).
    private(set) var errorLocation: (line: Int, column: Int)?
    /// Someone else saved the open document script while it was being edited.
    private(set) var reloadNotice = false
    @ObservationIgnored private var saved: String?
    @ObservationIgnored weak var features: ScriptFeatures?
    @ObservationIgnored private var runner: ScriptRunner?
    @ObservationIgnored let completions = ScriptCompletions()
    /// Chooses where an untitled script is saved (a save panel in the Scripts folder by default).
    @ObservationIgnored var chooseSaveURL: @MainActor (String, URL) async -> URL? = { name, folder in
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name + ".js"
        panel.allowedContentTypes = [.javaScript]
        return await ModalUI.url(panel, on: nil)
    }

    init(features: ScriptFeatures?) {
        self.features = features
    }

    var window: DocumentWindowController? { features?.window() }

    /// The chooser's items: untitled, the Scripts folder's files, the front document's scripts.
    var choices: [(choice: Choice, title: String)] {
        var items: [(Choice, String)] = [(.untitled, "Untitled")]
        items += (features?.folder.entries() ?? []).map { (.file($0.url), ($0.folders + [$0.title]).joined(separator: " › ")) }
        if let state = window?.documentHandle.state {
            items += DocumentScript.list(state).map { (.document($0.id), "Document: \($0.name.isEmpty ? "Untitled script" : $0.name)") }
        }
        return items
    }

    func choose(_ choice: Choice) {
        reloadNotice = false
        errorLocation = nil
        switch choice {
        case .untitled:
            text = Self.untitledSource
            name = "Untitled"
            saved = nil
        case .file(let url):
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            name = url.deletingPathExtension().lastPathComponent
            saved = nil
        case .document(let id):
            guard let script = window.flatMap({ DocumentScript.script(id, in: $0.documentHandle.state) }) else { return }
            text = script.source
            name = script.name
            saved = script.source
        }
        self.choice = choice
    }

    // MARK: Running

    /// btn:[Run] (kbd:[Cmd+Return]): the buffer on the front document.
    func run() async {
        guard !isRunning, let features else { return }
        isRunning = true
        errorLocation = nil
        console = []
        let runner = ScriptRunner()
        self.runner = runner
        let result = await features.run(text, name: name, runner: runner) { [weak self] entry in self?.append(entry) }
        if case .exception(_, let line?, let column)? = result?.error { errorLocation = (line, column ?? 1) }
        if result == nil { append(ScriptConsoleEntry(.error, "No document is open.")) }
        self.runner = nil
        isRunning = false
    }

    /// btn:[Stop]: after the current statement; what the script did stays.
    func stop() { runner?.stop() }

    func append(_ entry: ScriptConsoleEntry) { console.append(entry) }

    func clearConsole() { console = [] }

    // MARK: Saving

    /// btn:[Save]: the file, or the document script (one change); an untitled script goes to
    /// the Scripts folder.
    @discardableResult
    func save() async -> Bool {
        switch choice {
        case .untitled:
            guard let folder = features?.folder.url, let url = await chooseSaveURL(name, folder) else { return false }
            guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return false }
            choice = .file(url)
            name = url.deletingPathExtension().lastPathComponent
            features?.reload()
            return true
        case .file(let url):
            return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        case .document(let id):
            guard let window else { return false }
            saved = text
            reloadNotice = false
            _ = await window.objectEditing.perform(SaveScript(id, name: name, source: text)).value
            return true
        }
    }

    /// btn:[Save to Document]: a new document script from the buffer; it travels with the
    /// document and shows under menu:Scripts[Document Scripts] for everyone in it.
    @discardableResult
    func saveToDocument() async -> Bool {
        guard let window else { return false }
        let before = Set(DocumentScript.list(window.documentHandle.state).map(\.id))
        let change = await window.objectEditing.perform(SaveScript(nil, name: name.isEmpty ? "Untitled" : name, source: text)).value
        guard change != nil, let created = DocumentScript.list(window.documentHandle.state).first(where: { !before.contains($0.id) }) else { return false }
        choice = .document(created.id)
        saved = text
        return true
    }

    /// The front document changed: a remote save of the open script shows *Reload*.
    func documentChanged() {
        guard case .document(let id) = choice, let state = window?.documentHandle.state, let script = DocumentScript.script(id, in: state) else { return }
        if script.source != saved {
            if script.source != text { reloadNotice = true }
            saved = script.source
        }
    }

    /// *Reload*: the document's version replaces the buffer.
    func reload() {
        reloadNotice = false
        choose(choice)
    }

    // MARK: Completion

    /// The completion items for the text before the caret.
    func completions(before prefix: String) -> [ScriptCompletions.Member] { completions.completions(before: prefix) }

    /// The console line of an entry.
    static func line(_ entry: ScriptConsoleEntry) -> String {
        switch entry.level {
        case .log, .table: entry.text
        case .warn: "⚠︎ " + entry.text
        case .error: "✖︎ " + entry.text
        case .request: "→ " + entry.text
        }
    }
}

/// The editor's text view: JavaScript coloring on every change and completion from the typings.
final class ScriptTextView: NSTextView {
    var completionSource: ((String) -> [String])?

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let prefix = (string as NSString).substring(to: NSMaxRange(charRange))
        return completionSource?(prefix) ?? []
    }
}

/// The buffer as an `NSTextView` in SwiftUI.
struct ScriptTextEditor: NSViewRepresentable {
    let model: ScriptEditorModel

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ScriptEditorModel
        weak var textView: ScriptTextView?

        init(model: ScriptEditorModel) {
            self.model = model
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            MainActor.assumeIsolated {
                model.text = textView.string
                if let storage = textView.textStorage { ScriptSyntax.highlight(storage) }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ScriptTextView.scrollableTextView()
        let textView = ScriptTextView(frame: scroll.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        let model = self.model
        textView.completionSource = { prefix in MainActor.assumeIsolated { model.completions(before: prefix).map(\.name) } }
        textView.setAccessibilityIdentifier("script.editor")
        scroll.documentView = textView
        context.coordinator.textView = textView
        update(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ScriptTextView else { return }
        update(textView)
    }

    /// Shows the model's text (when it changed elsewhere) and marks the error's line.
    func update(_ textView: ScriptTextView) {
        if textView.string != model.text {
            textView.string = model.text
            if let storage = textView.textStorage { ScriptSyntax.highlight(storage) }
        }
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
        if let line = model.errorLocation?.line, let range = ScriptSyntax.range(ofLine: line, in: textView.string) {
            textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.2), forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }
    }
}

struct ScriptEditorView: View {
    @Bindable var model: ScriptEditorModel

    static func choose(_ model: ScriptEditorModel) -> Binding<ScriptEditorModel.Choice> {
        Binding(get: { model.choice }, set: { model.choose($0) })
    }

    static func run(_ model: ScriptEditorModel) -> () -> Void { { Task { await model.run() } } }
    static func save(_ model: ScriptEditorModel) -> () -> Void { { Task { await model.save() } } }
    static func saveToDocument(_ model: ScriptEditorModel) -> () -> Void { { Task { await model.saveToDocument() } } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Script", selection: Self.choose(model)) {
                    ForEach(model.choices, id: \.choice) { Text($0.title).tag($0.choice) }
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("script.chooser")
                TextField("Name", text: $model.name).frame(width: 140).accessibilityIdentifier("script.name")
                Spacer()
                Button("Run", action: Self.run(model)).keyboardShortcut(.return, modifiers: .command).disabled(model.isRunning)
                    .accessibilityIdentifier("script.run")
                Button("Stop", action: model.stop).disabled(!model.isRunning).accessibilityIdentifier("script.stop")
                Button("Save", action: Self.save(model)).keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("script.save")
                Button("Save to Document", action: Self.saveToDocument(model)).accessibilityIdentifier("script.saveToDocument")
            }
            .padding(8)
            if model.reloadNotice {
                HStack {
                    Text("Someone else saved this script.").font(.callout)
                    Button("Reload", action: model.reload).accessibilityIdentifier("script.reload")
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.2))
            }
            VSplitView {
                ScriptTextEditor(model: model).frame(minHeight: 200)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Console").font(.caption.bold())
                        if let error = model.errorLocation { Text("Error at line \(error.line), column \(error.column)").font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Button("Clear", action: model.clearConsole).font(.caption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(model.console.indices, id: \.self) { index in
                                Text(ScriptEditorModel.line(model.console[index])).font(.caption.monospaced())
                                    .foregroundStyle(model.console[index].level == .error ? .red : .primary).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("script.console")
                }
                .padding(6)
                .frame(minHeight: 90)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// menu:Window[Script Editor]: the editor in a window of its own.
@MainActor
final class ScriptEditorController: NSWindowController {
    let model: ScriptEditorModel

    init(model: ScriptEditorModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "Script Editor"
        window.identifier = NSUserInterfaceItemIdentifier("script-editor")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScriptEditorView(model: model))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ScriptEditorController is built in code")
    }
}
