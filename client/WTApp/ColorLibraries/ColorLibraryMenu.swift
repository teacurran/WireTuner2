import AppKit
import Foundation
import UniformTypeIdentifiers
import WTInterchange
import WTModel
import WTProto

/// Colour libraries from the Swatches panel's Options menu (spot-process.adoc, "Color libraries";
/// exporting-colors.adoc; COLOR-013's and COLOR-018's WTApp halves): the four bundled libraries by
/// name, *My Libraries* (the library files in `ColorLibraryRegistry`'s folder), *Import…* (a
/// library file, copied into *My Libraries*, then shown in the library sheet), *Export…* (the
/// document's colours to a library file), and menu:Extensions[Colors > Import RGB Color Table…]
/// (a Photoshop `.act` file's colours added as sRGB process colours in a group named after the
/// file).  Panel menus are flat, so *My Libraries* is a disabled header followed by its libraries.
@MainActor
final class ColorLibraryMenu {
    let workspace: ColorWorkspace
    /// *My Libraries*.
    var registry: ColorLibraryRegistry
    var runOpenPanel: @MainActor (NSOpenPanel, NSWindow?) async -> [URL] = ModalUI.urls
    var runSavePanel: @MainActor (NSSavePanel, NSWindow?) async -> URL? = ModalUI.url
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert
    /// The import or table import running (tests await it).
    private(set) var running: Task<Void, Never>?

    static let myLibrariesHeader = "My Libraries"
    static let noDocument = "No document is open"

    init(workspace: ColorWorkspace, registry: ColorLibraryRegistry = ColorLibraryRegistry()) {
        self.workspace = workspace
        self.registry = registry
    }

    // MARK: Menu

    /// The Options menu's library items: the bundled libraries, *My Libraries*, *Import…* and
    /// *Export…*.  Everything but *Export…*'s file writing needs a document.
    func menuItems() -> [PanelMenuItem] {
        let hasDocument = workspace.swatches != nil
        var items = BundledColorLibraries.all.map { library in
            PanelMenuItem(title: library.name, isEnabled: hasDocument) { [weak self] in self?.show(library) }
        }
        let files = registry.files()
        if !files.isEmpty {
            items.append(PanelMenuItem(title: Self.myLibrariesHeader, isEnabled: false) {})
            items += files.map { url in
                PanelMenuItem(title: "    " + url.deletingPathExtension().lastPathComponent, isEnabled: hasDocument) { [weak self] in self?.show(url) }
            }
        }
        items.append(PanelMenuItem(title: "Import…", isEnabled: hasDocument) { [weak self] in self?.beginImport() })
        items.append(PanelMenuItem(title: "Export…", isEnabled: hasDocument) { [weak self] in self?.showExport() })
        return items
    }

    // MARK: Library sheet

    /// Shows `library` in the library sheet.
    func show(_ library: ColorLibrary) {
        let model = ColorLibrarySheetModel(workspace: workspace, library: library)
        workspace.present(ColorLibrarySheet(model: model), title: library.name, identifier: ColorLibrarySheetModel.sheet)
    }

    /// Shows the library file at `url` (one of *My Libraries*), or says why it cannot be read.
    func show(_ url: URL) {
        do {
            show(try ColorLibraryFiles.read(contentsOf: url))
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be opened.", String(describing: error), NSApp.mainWindow)
        }
    }

    // MARK: Import

    /// The allowed types of an open panel for `formats`.
    static func contentTypes(_ formats: [ColorLibraryFormat]) -> [UTType] {
        formats.compactMap { UTType(filenameExtension: $0.fileExtension) }
    }

    @discardableResult
    func beginImport() -> Task<Void, Never> {
        let task = Task { await importLibrary() }
        running = task
        return task
    }

    /// *Import…*: a library file chosen in an open panel, copied into *My Libraries* and shown in
    /// the library sheet.
    func importLibrary() async {
        let panel = NSOpenPanel()
        panel.title = "Import Color Library"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.contentTypes(ColorLibraryFormat.allCases)
        guard let url = await runOpenPanel(panel, NSApp.mainWindow).first else { return }
        do {
            let library = try ColorLibraryFiles.read(contentsOf: url)
            try registry.install(url)
            show(library)
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be imported.", String(describing: error), NSApp.mainWindow)
        }
    }

    @discardableResult
    func beginImportColorTable() -> Task<Void, Never> {
        let task = Task { _ = await importColorTable() }
        running = task
        return task
    }

    /// menu:Extensions[Colors > Import RGB Color Table…]: every colour of an `.act` file added as
    /// an sRGB process colour, in a group named after the file, as one change.
    @discardableResult
    func importColorTable() async -> Wiretuner_Doc_V1_Change? {
        let panel = NSOpenPanel()
        panel.title = "Import RGB Color Table"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.contentTypes([.act])
        guard let url = await runOpenPanel(panel, NSApp.mainWindow).first else { return nil }
        do {
            let library = try ColorLibraryFiles.read(contentsOf: url)
            return await workspace.perform(ImportLibraryColors(library, group: url.deletingPathExtension().lastPathComponent))?.value
        } catch {
            showAlert("“\(url.lastPathComponent)” could not be imported.", String(describing: error), NSApp.mainWindow)
            return nil
        }
    }

    // MARK: Export

    /// *Export…*: the export sheet over the front document's colours.
    func showExport() {
        let model = ColorLibraryExportModel(workspace: workspace, libraries: self)
        workspace.present(ColorLibraryExportSheet(model: model), title: "Export Colors", identifier: ColorLibraryExportModel.sheet)
    }
}
