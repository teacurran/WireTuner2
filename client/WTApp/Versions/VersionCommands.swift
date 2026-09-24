import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTSync

/// The Save Version sheet (saving.adoc, "Saving a version"): a name prefilled with the date and
/// time, so kbd:[Return] at once is fine, and an optional note.
enum SaveVersionSheet {
    static let identifier = NSUserInterfaceItemIdentifier("save-version-sheet")

    /// "Sep 23, 2026 at 10:04 AM": the prefilled name, and the name a silent save uses.
    static func defaultName(for date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = false
        return formatter.string(from: date)
    }

    @MainActor
    static func window(name: String, finish: @escaping @MainActor ((name: String, note: String)?) -> Void) -> NSWindow {
        let controller = NSHostingController(rootView: SaveVersionSheetView(initialName: name, finish: finish))
        let window = NSWindow(contentViewController: controller)
        window.identifier = identifier
        window.title = "Save Version"
        return window
    }
}

struct SaveVersionSheetView: View {
    let finish: @MainActor ((name: String, note: String)?) -> Void
    @State private var name: String
    @State private var note = ""

    init(initialName: String, finish: @escaping @MainActor ((name: String, note: String)?) -> Void) {
        self.finish = finish
        _name = State(initialValue: initialName)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    func cancel() { finish(nil) }
    func save() { finish((trimmedName, note)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Version").font(.headline)
            TextField("Name", text: $name, prompt: Text("Version name")).accessibilityIdentifier("save-version.name")
            Text("Note").font(.callout)
            TextEditor(text: $note).frame(height: 64).border(Color.secondary.opacity(0.3)).accessibilityIdentifier("save-version.note")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("save-version.cancel")
                Button("Save Version", action: save)
                    .keyboardShortcut(.defaultAction).disabled(trimmedName.isEmpty).accessibilityIdentifier("save-version.save")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// menu:File[Save Version…] (kbd:[Cmd+S]) and menu:File[Duplicate] (kbd:[Cmd+Shift+S]) for every
/// document window (saving.adoc; IO-003, IO-004).  One `VersionSaving` per open document keeps its
/// pending versions and sends them whenever the document reaches *Saved to cloud*.
@MainActor
final class VersionFeatures {
    /// Names versions on the server; nil sends nothing (signed out, tests), which keeps every
    /// version pending.
    var client: (any VersionClient)?
    var accessToken: @Sendable () async throws -> String = { throw AuthError.notSignedIn }
    /// *Ask for a version name when saving*.
    var asksForName: @MainActor () -> Bool = { true }
    /// The storage and head of a document (its local store in the app).
    var local: @MainActor (DocumentHandle) -> (storage: VersionSaving.Storage, head: @MainActor () async -> VersionHead?) = VersionSaving.localStore
    var now: @MainActor () -> Date = { Date() }
    /// Records a document not yet created on the server in `source`'s folder and returns its id
    /// (the library's deferred creation); nil keeps it in memory (tests).
    var recordDocument: @MainActor (_ name: String, _ source: String) -> String? = { _, _ in nil }
    /// Opens the document `id` titled `name` in a new window without the new-document template.
    var openDocument: @MainActor (_ id: String, _ name: String) -> DocumentHandle? = { _, _ in nil }
    private(set) var savers: [String: VersionSaving] = [:]
    private var statusTokens: [String: UUID] = [:]

    /// The saving of `document`, made on first use.
    func saver(for document: DocumentHandle) -> VersionSaving {
        if let saver = savers[document.id] { return saver }
        let local = local(document)
        let saver = VersionSaving(documentID: document.id, storage: local.storage, head: local.head)
        saver.now = now
        if let client {
            let token = accessToken
            saver.send = { request in try await client.nameVersion(request, accessToken: try await token()) }
        }
        savers[document.id] = saver
        return saver
    }

    /// A window opened: its document's pending versions go up whenever it is saved to the cloud.
    func documentDidOpen(_ window: DocumentWindowController) {
        let document = window.documentHandle
        let saver = saver(for: document)
        guard statusTokens[document.id] == nil else { return }
        let status = window.syncStatus
        statusTokens[document.id] = status.observe {
            if case .saved = status.state { Task { await saver.flush() } }
        }
        Task { await saver.flush() }
    }

    // MARK: Save Version

    /// menu:File[Save Version…]: the sheet, or with *Ask for a version name when saving* off a
    /// version named with the date and time and a confirmation in the status bar.
    @discardableResult
    func saveVersion(from window: DocumentWindowController) -> NSWindow? {
        let name = SaveVersionSheet.defaultName(for: now())
        guard asksForName() else {
            Task { await save(name: name, note: "", in: window) }
            return nil
        }
        let sheet = SaveVersionSheet.window(name: name) { [weak self, weak window] answer in
            guard let window, let sheet = window.window?.attachedSheet else { return }
            window.window?.endSheet(sheet)
            if let answer, let self { Task { await self.save(name: answer.name, note: answer.note, in: window) } }
        }
        window.window?.beginSheet(sheet)
        return sheet
    }

    /// Saves the version and says so in the window's status bar.
    @discardableResult
    func save(name: String, note: String, in window: DocumentWindowController) async -> VersionSaving.Outcome {
        let outcome = await saver(for: window.documentHandle).save(name: name, note: note)
        window.statusBar.show(message: Self.message(for: outcome, name: name))
        return outcome
    }

    static func message(for outcome: VersionSaving.Outcome, name: String) -> String {
        switch outcome {
        case .named: "Saved version “\(name)”"
        case .pending: "Saved version “\(name)”, pending until your changes upload"
        }
    }

    // MARK: Duplicate

    /// menu:File[Duplicate]: a new document "<name> copy" in the same folder, opened in a new
    /// window, holding the document as it is now re-issued from the copy's own replica.  Works
    /// offline: the copy is listed at once and created on the server when the library next
    /// connects.  The original keeps receiving changes meanwhile; the copy takes none of them.
    @discardableResult
    func duplicate(_ window: DocumentWindowController) async -> DocumentHandle? {
        let source = window.documentHandle
        await source.settle()
        let name = DocumentDuplicate.name(for: source.title)
        guard let plan = try? DocumentDuplicate.plan(source.state), let id = recordDocument(name, source.id), let copy = openDocument(id, name),
              let model = await copy.openedModel() else { return nil }
        model.beginGroup()
        defer { model.endGroup() }
        while !plan.isFinished, (try? await model.perform(DuplicateChunk(plan))) != nil {}
        return copy
    }

    // MARK: Commands

    enum ID {
        static let saveVersion = StandardCommands.ID.saveVersion
        static let duplicate: CommandID = "file.duplicate"
    }

    func commands(target: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> [Command] {
        let menu = StandardCommands.Menu.file
        let needsWindow: @MainActor @Sendable () -> CommandValidation = { target() == nil ? .disabled(ViewCommands.noDocument) : .enabled }
        return [
            Command(
                id: ID.saveVersion, title: "Save Version…", key: KeyEquivalent("s", .command), menu: MenuPath(menu, section: 1), keywords: ["save", "history"],
                validation: needsWindow, action: .perform { [weak self] in if let window = target() { self?.saveVersion(from: window) } }
            ),
            Command(
                id: ID.duplicate, title: "Duplicate", key: KeyEquivalent("s", [.command, .shift]), menu: MenuPath(menu, section: 1), keywords: ["copy", "document"],
                validation: needsWindow, action: .perform { [weak self] in if let window = target() { Task { await self?.duplicate(window) } } }
            ),
        ]
    }

    func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) {
        for command in commands(target: target) { registry.replace(command) }
    }
}
