import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTSync

/// Templates in the app (templates.adoc; DOC-019's gallery half, DOC-029, DOC-030): the gallery
/// window, menu:File[New] from the *New document template* with its fallback to Built-in and
/// one-time notice, and menu:File[Save as Template…].
@MainActor
final class TemplateFeatures {
    enum ID {
        static let newFromTemplate: CommandID = "file.newFromTemplate"
        static let saveAsTemplate: CommandID = "file.saveAsTemplate"
    }

    static let saveSheet = "save-as-template-sheet"
    /// The templates whose fallback notice was shown (local: the notice is per Mac).
    static let noticedKey = "wt.local.template_fallback_noticed"
    static let needsWindow = "Open a document first"

    static func fallbackMessage(_ name: String) -> String {
        "Your default template “\(name)” is no longer available, so new documents use Built-in. Choose another in Settings > Document."
    }

    let library: LibraryModel
    let preferences: PreferenceStore
    var states: TemplateStates
    let sheets: SheetPresenter
    /// Shows the one-time notice; replaceable in tests.
    var notify: @MainActor (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = "Default Template Unavailable"
        alert.informativeText = message
        alert.runModal()
    }
    /// Writes a template copy's content into its new document `id` (its local store, uploading in
    /// the background); replaceable in tests.
    var writeCopy: @MainActor (_ id: String, _ template: DocumentCreation.Template) async throws -> Void = { _, _ in }
    private(set) var gallery: TemplateGalleryWindowController?
    /// The Save as Template sheet's model while it is open.
    private(set) var saving: SaveAsTemplateModel?

    init(library: LibraryModel, preferences: PreferenceStore, states: TemplateStates = TemplateStates(), sheets: SheetPresenter = SheetPresenter()) {
        self.library = library
        self.preferences = preferences
        self.states = states
        self.sheets = sheets
    }

    // MARK: The gallery

    /// The gallery window, brought forward.
    @discardableResult
    func showGallery() -> TemplateGalleryWindowController {
        let controller = gallery ?? TemplateGalleryWindowController(model: TemplateGalleryModel(library: library, states: states))
        controller.model.states = states
        gallery = controller
        controller.show()
        return controller
    }

    // MARK: File > New and the default template

    /// The *New document template* preference's template, or nil for Built-in.
    var defaultTemplateID: String? {
        let id = preferences[PreferenceCatalog.Document.newTemplate]
        return id.isEmpty ? nil : id
    }

    /// menu:File[New]: an untitled document from the default template.  A template that is gone
    /// (trashed, unshared, not found) or cannot be read falls back to Built-in and says so once.
    @discardableResult
    func newDocument(name: String = LibraryModel.untitled) async -> LibraryDocument {
        guard let id = defaultTemplateID else { return library.createDocument(name: name) }
        let entry = library.cache.documents[id]
        if entry?.isTrashed != true, let state = try? await states.state(of: id) {
            return library.createDocument(name: name, template: .document(state, name: entry?.name ?? ""))
        }
        noticeFallback(id, name: entry?.name ?? LibraryModel.untitled)
        return library.createDocument(name: name)
    }

    /// menu:File[New] from a menu or button: at once for Built-in, after reading the template
    /// otherwise.
    func newDocumentNow() {
        if defaultTemplateID == nil {
            library.createDocument()
        } else {
            Task { await newDocument() }
        }
    }

    private func noticeFallback(_ id: String, name: String) {
        var noticed = preferences.defaults.stringArray(forKey: Self.noticedKey) ?? []
        guard !noticed.contains(id) else { return }
        noticed.append(id)
        preferences.defaults.set(noticed, forKey: Self.noticedKey)
        notify(Self.fallbackMessage(name))
    }

    /// The *New document template* pop-up: Built-in, then my templates and each team's.
    var templateChoices: [(id: String, title: String)] {
        [("", "Built-in")] + library.templateGroups.flatMap { group in
            group.templates.map { ($0.id, group.space.kind == .personal ? $0.name : "\($0.name) (\(group.space.name))") }
        }
    }

    // MARK: Save as Template

    /// menu:File[Save as Template…]: the sheet for `window`'s document.
    @discardableResult
    func showSaveAsTemplate(for window: DocumentWindowController) -> SaveAsTemplateModel {
        let model = SaveAsTemplateModel(name: window.documentHandle.title, spaces: library.spaces) { [weak self, weak window] result in
            guard let self else { return }
            self.saving = nil
            self.sheets.dismiss(Self.saveSheet)
            if let result, let window { Task { await self.saveAsTemplate(window.documentHandle, name: result.name, spaceID: result.spaceID) } }
        }
        saving = model
        sheets.present(SaveAsTemplateView(model: model), title: "Save as Template", identifier: Self.saveSheet)
        return model
    }

    /// A copy of `document` stored as a template named `name` at the top level of `spaceID`: its
    /// current content as one creation change, flagged once it exists on the server (offline it
    /// waits with the *Waiting to upload* badge).  The working document is not changed.
    @discardableResult
    func saveAsTemplate(_ document: DocumentHandle, name: String, spaceID: String) async -> LibraryDocument? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let template = DocumentCreation.Template.document(document.state, name: document.title)
        let copy = library.recordDocument(name: name, in: (spaceID, nil), isTemplate: true)
        do {
            try await writeCopy(copy.id, template)
        } catch {
            library.show(message: "The template could not be saved: \(error.localizedDescription)")
            return nil
        }
        library.keepAvailableOffline(copy.id)
        return copy
    }

    // MARK: Commands

    func commands(target: @escaping @MainActor @Sendable () -> DocumentWindowController?) -> [Command] {
        let file = StandardCommands.Menu.file
        return [
            Command(
                id: ID.newFromTemplate, title: "New from Template…", key: KeyEquivalent("n", [.command, .shift]), menu: MenuPath(file),
                keywords: ["template", "gallery", "starting point"], action: .perform { [weak self] in self?.showGallery() }
            ),
            Command(
                id: ID.saveAsTemplate, title: "Save as Template…", menu: MenuPath(file, section: 1), keywords: ["template"],
                validation: { target() == nil ? .disabled(Self.needsWindow) : .enabled },
                action: .perform { [weak self] in if let window = target() { self?.showSaveAsTemplate(for: window) } }
            ),
            Command(
                id: StandardCommands.ID.new, title: "New", key: KeyEquivalent("n", .command), menu: MenuPath(file), keywords: ["document"],
                action: .perform { [weak self] in self?.newDocumentNow() }
            ),
        ]
    }

    func install(into registry: CommandRegistry, target: @escaping @MainActor @Sendable () -> DocumentWindowController?) {
        for command in commands(target: target) { registry.replace(command) }
        library.showGallery = { [weak self] in self?.showGallery() }
        library.makeNewDocument = { [weak self] in self?.newDocumentNow() }
        TemplateChoices.provider = { [weak self] in self?.templateChoices ?? [("", "Built-in")] }
    }
}

/// The *New document template* pop-up's entries (the Preferences window reads them).
@MainActor
enum TemplateChoices {
    static var provider: @MainActor () -> [(id: String, title: String)] = { [("", "Built-in")] }

    /// The choices, with `current` listed even when it is not a known template (another Mac's).
    static func choices(current: String) -> [(id: String, title: String)] {
        let choices = provider()
        return current.isEmpty || choices.contains(where: { $0.id == current }) ? choices : choices + [(current, "Unavailable template")]
    }
}

/// The Save as Template sheet: a name and where it goes (*My Templates* or a team).
@MainActor
@Observable
final class SaveAsTemplateModel: Identifiable {
    var name: String
    var spaceID: String
    let spaces: [LibrarySpace]
    @ObservationIgnored let finish: @MainActor ((name: String, spaceID: String)?) -> Void

    init(name: String, spaces: [LibrarySpace], finish: @escaping @MainActor ((name: String, spaceID: String)?) -> Void) {
        self.name = name
        self.spaces = spaces
        spaceID = spaces.first?.id ?? LibraryModel.localPersonalID
        self.finish = finish
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    func save() {
        guard canSave else { return }
        finish((name, spaceID))
    }

    func cancel() { finish(nil) }

    static func title(of space: LibrarySpace) -> String {
        space.kind == .personal ? TemplateGalleryModel.myTemplates : space.name
    }
}

struct SaveAsTemplateView: View {
    @Bindable var model: SaveAsTemplateModel

    var body: some View {
        Form {
            TextField("Name", text: $model.name).accessibilityIdentifier("saveTemplate.name")
            Picker("Save to", selection: $model.spaceID) {
                ForEach(model.spaces) { Text(SaveAsTemplateModel.title(of: $0)).tag($0.id) }
            }
            .accessibilityIdentifier("saveTemplate.space")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.canSave)
                    .accessibilityIdentifier("saveTemplate.save")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
