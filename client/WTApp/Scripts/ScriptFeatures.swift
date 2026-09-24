import AppKit
import Foundation
import Synchronization
import WTCRDT
import WTModel

/// The Scripts menu and the Script Editor (scripting.adoc, "Scripts menu and library",
/// "Running a script"; DATA-013, DATA-014): menu:Scripts[] built from the watched Scripts folder
/// (subfolders as submenus) and the front document's scripts, each registered in the command
/// registry with a `script:` id -- so the palette finds it and the Shortcuts settings bind it --
/// with *Open Scripts Folder*, *Script Editor* and *Reload Scripts*; `wiretuner.d.ts` installed
/// on first launch.  A script runs only when the person chooses it: never at launch, on opening a
/// document or on a timer (`runs` counts every run for that audit).
@MainActor
final class ScriptFeatures {
    enum ID {
        static let editor: CommandID = "window.scriptEditor"
        static let editorFromScripts: CommandID = "scripts.editor"
        static let openFolder: CommandID = "scripts.openFolder"
        static let reload: CommandID = "scripts.reload"
        static let documentPrefix = "script:document:"
    }

    static let menu = "Scripts"
    static let documentScripts = "Document Scripts"

    var folder: ScriptsFolder
    /// The data features: a run reads the front window's records (`wt.records`) and fetches
    /// through its session.
    var data: DataFeatures?
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The menu bar changed (scripts added or removed): the app rebuilds it.
    var menuDidChange: @MainActor () -> Void = {}
    /// Opens a folder in the Finder; replaceable in tests.
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// How many scripts have run (the audit that nothing runs without a user action).
    private(set) var runs = 0
    private(set) var editor: ScriptEditorController?
    private weak var registry: CommandRegistry?
    private var registered: Set<CommandID> = []
    private var watcher: FolderWatcher?
    private var observed: (document: DocumentHandle, token: DocumentHandle.ObservationToken)?
    private var documentList: [DocumentScript.Summary] = []
    private var observers: [NSObjectProtocol] = []

    init(folder: ScriptsFolder) {
        self.folder = folder
    }

    convenience init() {
        self.init(folder: ScriptsFolder(url: (try? ScriptsFolder.defaultURL()) ?? FileManager.default.temporaryDirectory.appending(path: "WireTunerScripts")))
    }

    func install(commands: CommandRegistry, watch: Bool = true, window: @escaping @MainActor () -> DocumentWindowController?) {
        registry = commands
        self.window = window
        _ = try? folder.installTypings()
        for command in fixedCommands() { commands.replace(command) }
        reload(notify: false)
        if watch { watcher = FolderWatcher(url: folder.url) { [weak self] in self?.reload() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontWindowChanged() }
        })
    }

    // MARK: The menu

    func fixedCommands() -> [Command] {
        let tools = MenuPath(Self.menu, section: 2)
        let open: CommandAction = .perform { [weak self] in self?.showEditor() }
        return [
            Command(id: ID.editor, title: "Script Editor", menu: MenuPath(StandardCommands.Menu.window, section: StandardCommands.Section.windowPanels),
                    keywords: ["javascript", "script", "console"], action: open),
            Command(id: ID.openFolder, title: "Open Scripts Folder", menu: tools, keywords: ["scripts", "finder"],
                    action: .perform { [weak self] in self?.openFolder() }),
            Command(id: ID.editorFromScripts, title: "Script Editor", menu: tools, keywords: ["javascript"], action: open),
            Command(id: ID.reload, title: "Reload Scripts", menu: tools, keywords: ["scripts", "refresh"], action: .perform { [weak self] in self?.reload() }),
        ]
    }

    /// The commands for the folder's scripts and the front document's.
    func scriptCommands() -> [Command] {
        var commands = folder.entries().map { entry in
            Command(id: entry.commandID, title: entry.title, menu: MenuPath(components: [Self.menu] + entry.folders, section: 0), keywords: ["script"],
                    action: .perform { [weak self] in self?.runFile(entry.url) })
        }
        for script in documentList {
            commands.append(Command(id: CommandID(ID.documentPrefix + "\(script.id.counter)-\(script.id.replica)"), title: script.title,
                                    menu: MenuPath(Self.menu, Self.documentScripts, section: 1), keywords: ["script", "document"],
                                    validation: { [weak self] in self?.window() == nil ? .disabled(DataFeatures.noDocument) : .enabled },
                                    action: .perform { [weak self] in self?.runDocumentScript(script.id) }))
        }
        return commands
    }

    /// *Reload Scripts* (and every change the watcher sees): the script commands again, then the
    /// menu bar.
    func reload(notify: Bool = true) {
        guard let registry else { return }
        let commands = scriptCommands()
        let ids = Set(commands.map(\.id))
        registry.remove(registered.subtracting(ids))
        for command in commands { registry.replace(command) }
        registered = ids
        if notify { menuDidChange() }
    }

    func openFolder() {
        _ = try? folder.installTypings()
        reveal(folder.url)
    }

    /// The front window changed: its document's scripts are the menu's.
    func frontWindowChanged() {
        let document = window()?.documentHandle
        guard observed?.document !== document else { return }
        if let observed { observed.document.stopObserving(observed.token) }
        observed = document.map { document in (document, document.observe { [weak self] change in if change.change != nil { self?.documentScriptsChanged() } }) }
        documentScriptsChanged(force: true)
    }

    /// Rebuilds the menu when the front document's script names change.
    func documentScriptsChanged(force: Bool = false) {
        editor?.model.documentChanged()
        let list = window().map { DocumentScript.list($0.documentHandle.state).map(DocumentScript.Summary.init) } ?? []
        guard force || list != documentList else { return }
        let changed = list != documentList
        documentList = list
        if changed { reload() }
    }

    // MARK: Running

    func runFile(_ url: URL) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        Task { await run(source, name: url.deletingPathExtension().lastPathComponent) }
    }

    func runDocumentScript(_ id: OpID) {
        guard let window = window(), let script = DocumentScript.script(id, in: window.documentHandle.state) else { return }
        Task { await run(script.source, name: script.name) }
    }

    /// Runs `source` on the front document; the console lines go to the Script Editor, which
    /// comes forward on an error with *Show script console on error* on.
    @discardableResult
    func run(_ source: String, name: String, runner: ScriptRunner = ScriptRunner(), console: (@MainActor (ScriptConsoleEntry) -> Void)? = nil) async -> ScriptRunResult? {
        guard let window = window(), let document = window.documentHandle.model else { return nil }
        runs += 1
        let session = data?.session(for: window)
        let fetcher = await session?.scriptFetcher()
        let target = DocumentScriptTarget(document, name: window.documentHandle.title, selection: window.selection.model.selection.ids.map(\.opID)) { [weak window] ids in
            window?.selection.model.set(Selection(ids.map(SelectionID.init)))
        }
        let host = WindowScriptHost(ui: ScriptUI(window: window, data: data))
        let sink = console ?? { [weak self] entry in self?.editor?.model.append(entry) }
        let result = await runner.runDetached(source, name: name, target: target, host: host, fetcher: fetcher, records: session?.records,
                                              current: session?.currentIndex ?? 0) { entry in Task { @MainActor in sink(entry) } }
        if result.error != nil, console == nil, data?.preferences[PreferenceCatalog.Automation.scriptConsoleOnError] ?? true {
            showEditor()
        }
        return result
    }

    /// menu:Window[Script Editor].
    @discardableResult
    func showEditor() -> ScriptEditorController {
        let controller = editor ?? ScriptEditorController(model: ScriptEditorModel(features: self))
        editor = controller
        controller.showWindow(nil)
        return controller
    }
}

extension DocumentScript {
    /// What the menu shows of a document script.
    struct Summary: Equatable {
        let id: OpID
        let title: String

        init(_ script: DocumentScript) {
            id = script.id
            title = script.name.isEmpty ? "Untitled script" : script.name
        }
    }
}

/// `wt.ui` for a run on a window (scripting.adoc, "`wt.ui`"): each call blocks the script's thread
/// while the main actor shows the alert, panel or sheet, and returns the answer.  `progress`
/// updates the progress sheet and reports its btn:[Cancel].
final class WindowScriptHost: ScriptHost, @unchecked Sendable {
    /// Set by the progress sheet's btn:[Cancel].
    final class Flag: @unchecked Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    private let presenter: ScriptUI
    private let cancelled = Flag()

    @MainActor
    init(ui presenter: ScriptUI) {
        self.presenter = presenter
        let flag = cancelled
        presenter.onCancel = { flag.set() }
    }

    func ui(_ call: String, _ arguments: [Any]) throws -> Any? {
        let arguments = ScriptArguments(arguments)
        let box = Mutex<Result<ScriptArguments, ScriptCallUnavailable>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let presenter = presenter
        Task { @MainActor in
            let answer = await presenter.handle(call, arguments.values)
            box.withLock { $0 = answer.map { .success(ScriptArguments([$0])) } ?? .failure(ScriptCallUnavailable(call: "wt.ui.\(call)")) }
            done.signal()
        }
        done.wait()
        let values = try box.withLock { $0! }.get().values
        return values.first.flatMap { $0 is NSNull ? nil : $0 }
    }

    func progress(_ fraction: Double, _ text: String) -> Bool {
        let presenter = presenter
        Task { @MainActor in presenter.update(fraction, text) }
        return !cancelled.isSet
    }
}

/// Values crossing to the main actor and back (JavaScript values are plain property lists).
struct ScriptArguments: @unchecked Sendable {
    let values: [Any]
    init(_ values: [Any]) { self.values = values }
}

/// A `wt.ui` call the window does not answer (it throws in the script).
struct ScriptCallUnavailable: Error, Hashable, CustomStringConvertible {
    let call: String
    var description: String { "\(call) is not available" }
}
