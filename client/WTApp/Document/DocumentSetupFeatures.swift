import AppKit
import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel

/// The document setup features (the DOC epic's client-ui tasks): the Page tool, the Document
/// panel, the View menu's grid, guide and unit commands, the Links window with its missing-link
/// search when a document opens.  One object per app; everything acts on the front window.
@MainActor
final class DocumentSetupFeatures {
    enum ID {
        static let links: CommandID = "edit.links"
    }

    static let noDocument = "No document is open"

    let preferences: PreferenceStore
    /// This Mac's `wt-device` id (link status and repairs are per Mac).
    let device: String
    let panel = DocumentPanelState()
    /// The front document window.
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// Where blobs go before a change references them, and where stored copies are read.
    var blobs = BlobPlacement()
    private(set) var links: LinksWindowController?

    init(preferences: PreferenceStore, device: String) {
        self.preferences = preferences
        self.device = device
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, tools: ToolRegistry, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        panel.window = window
        tools.replace(PageTool.descriptor)
        panels.registerIfAbsent(DocumentPanel.descriptor(state: panel))
        for command in self.commands() { commands.replace(command) }
    }

    // MARK: Commands

    func commands() -> [Command] {
        let ids = StandardCommands.ID.self
        let view = StandardCommands.Menu.view
        let rulers = StandardCommands.Section.viewRulers
        let window = self.window
        func checked(_ value: @escaping @MainActor @Sendable (DocumentWindowController) -> Bool) -> @MainActor @Sendable () -> CommandValidation {
            { window().map { .checked(value($0)) } ?? .disabled(Self.noDocument) }
        }
        let needsWindow: @MainActor @Sendable () -> CommandValidation = { window() == nil ? .disabled(Self.noDocument) : .enabled }
        return [
            Command(id: ids.showGrid, title: "Show", menu: MenuPath(view, StandardCommands.Menu.grid, section: rulers), keywords: ["grid"],
                    validation: checked { $0.showsGrid }, action: .perform { window().map { $0.showsGrid.toggle() } }),
            Command(id: ids.editGrid, title: "Edit Grid…", menu: MenuPath(view, StandardCommands.Menu.grid, section: rulers, subsection: 1), keywords: ["grid"],
                    validation: needsWindow, action: .perform { _ = window()?.presentGridSheet() }),
            Command(id: ids.showGuides, title: "Show", menu: MenuPath(view, StandardCommands.Menu.guides, section: rulers), keywords: ["guides"],
                    validation: checked { $0.showsGuides }, action: .perform { window().map { $0.showsGuides.toggle() } }),
            Command(id: ids.lockGuides, title: "Lock", menu: MenuPath(view, StandardCommands.Menu.guides, section: rulers), keywords: ["guides"],
                    validation: checked { $0.documentHandle.settings.guidesLocked }, action: .perform { _ = window()?.toggleGuidesLocked() }),
            Command(id: ids.editGuides, title: "Edit…", menu: MenuPath(view, StandardCommands.Menu.guides, section: rulers, subsection: 1), contexts: [.guide],
                    keywords: ["guides"], validation: needsWindow, action: .perform { _ = window()?.presentGuidesSheet() }),
            Command(id: ids.pageRulerUnits, title: "Edit Units…", menu: MenuPath(view, StandardCommands.Menu.pageRulers, section: rulers, subsection: 1),
                    keywords: ["rulers", "units", "custom units"], validation: needsWindow, action: .perform { _ = window()?.presentUnitsSheet() }),
            Command(id: ID.links, title: "Links…", menu: MenuPath(StandardCommands.Menu.edit, section: 2), keywords: ["links", "images", "relink", "embed"],
                    validation: needsWindow, action: .perform { [weak self] in self?.showLinks() }),
        ]
    }

    // MARK: Links

    /// The Links model of `window`'s document, wired to the window.
    func linksModel(for window: DocumentWindowController) -> LinksModel {
        let model = LinksModel(document: window.documentHandle, device: device) { [weak window] command in
            window?.objectEditing.perform(command) ?? Task { nil }
        }
        let blobs = self.blobs
        let document = window.documentHandle
        model.storeBlob = { blob in try await blobs.store([blob], for: document) }
        model.cachedBlob = { blobs.cached($0) }
        model.isUploading = { [weak window] sha256 in window.map { LinkUploads.isUploading(sha256, in: $0) } ?? false }
        model.chooseFile = { [weak window] in await ModalUI.urls(NSOpenPanel(), on: window?.window).first }
        model.chooseDestination = { [weak window] name in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            return await ModalUI.url(panel, on: window?.window)
        }
        model.confirmReplace = { url in
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” already exists. Replace it?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        model.selectObjects = { [weak window] ids in window?.select(ids) }
        return model
    }

    /// menu:Edit[Links…]: the window, on the front document.
    @discardableResult
    func showLinks() -> LinksWindowController? {
        guard let window = window() else { return nil }
        let model = linksModel(for: window)
        if let links {
            links.show(model)
        } else {
            links = LinksWindowController(model: model)
        }
        links?.showWindow(nil)
        return links
    }

    // MARK: Opening documents

    /// A document's first view opened: with *Search for missing links* on, its broken links on
    /// this Mac are searched for and repaired.
    @discardableResult
    func documentDidOpen(_ window: DocumentWindowController) -> Task<[FoundLink], Never>? {
        guard preferences[PreferenceCatalog.Document.searchMissingLinks] else { return nil }
        let folder = preferences[PreferenceCatalog.Document.missingLinksFolder]
        let device = self.device
        let document = window.documentHandle
        return Task { [weak window] in
            _ = await document.openedModel()
            return await MissingLinks.repair(document, device: device, searchFolder: folder.isEmpty ? nil : folder) { command in
                window?.objectEditing.perform(command) ?? Task { nil }
            }
        }
    }
}

extension DocumentWindowController {
    /// Selects `ids` and scrolls them into the middle of the view (the Links window's rows).
    func select(_ ids: [OpID]) {
        selection.model.set(Selection(ids.map(SelectionID.init)))
        guard let bounds = selection.selectedBounds else { return }
        setViewport(canvas.navigation.clamped(canvas.navigation.centring(viewport, on: bounds.center)))
    }
}

extension AppDelegate {
    /// The DOC epic's commands, tool and panels, and the missing-link search on open.
    func installDocumentSetup() {
        let documents = documents!
        documentSetup.blobs = imports.blobs
        documentSetup.install(commands: commands, panels: panels, tools: tools) { documents.activeWindowController }
    }
}
