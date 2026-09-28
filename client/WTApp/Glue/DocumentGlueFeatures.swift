import AppKit
import WTCRDT
import WTModel

/// The app half of commit cbda22a's model features, installed by `AppDelegate` in one call: the
/// master page tab and its notices (DOC-012 on DOC-011), named views (BASIC-015), Select Similar
/// (OBJ-042), Combine and the Path Operations toolbar (OBJ-025), the contents handle (OBJ-028),
/// the polygon handles (DRAW-010), kbd:[Option]-drag image resizing in printer-resolution steps
/// (IMG-004), new documents through `CreateDocument` (DOC-019), the *Team libraries* sections
/// (COLLAB-015), the *Profiles…* sheet and the profile reference scan (CMS-010); the Trace tool's
/// *Photo* tracer (IMG-029) lives with the tool.
@MainActor
final class DocumentGlueFeatures {
    static let profilesSheet = "profiles-sheet"

    let preferences: PreferenceStore
    let window: @MainActor () -> DocumentWindowController?
    let masters = MasterTabs()
    let views: NamedViewFeatures
    let similar: SelectSimilarCommands
    let combine: CombineCommands
    let teamLibraries = TeamLibraryCatalogModel()
    let profileScan = ProfileScanTimer()
    let sheets: SheetPresenter
    /// Each document window's master notices.
    private(set) var notices: [ObjectIdentifier: MasterNotices] = [:]
    /// Each window's status-line note of shapes converted to paths (D-078).
    private(set) var shapeNotices: [ObjectIdentifier: ShapeConversionNotice] = [:]
    /// The *Profiles…* sheet's model while it is open.
    private(set) var profiles: ProfilesModel?
    /// Called after commands were added to the registry (the bundled shape model loaded).
    var onMenuChange: (@MainActor () -> Void)?
    /// Loads the *Shape* item's classifier (IMG-030); replaceable in tests.
    var loadShapeClassifier: @MainActor () async -> (any ShapeClassifying)? = { await ShapeClassifierResource.load() }
    /// The classifier load under way at launch.
    private(set) var shapeLoading: Task<Void, Never>?

    init(preferences: PreferenceStore, sheets: SheetPresenter = SheetPresenter(), window: @escaping @MainActor () -> DocumentWindowController?) {
        self.preferences = preferences
        self.window = window
        self.sheets = sheets
        views = NamedViewFeatures(window: window, sheets: sheets)
        similar = SelectSimilarCommands(window: window)
        combine = CombineCommands(target: { window()?.objectEditing }, store: preferences)
        teamLibraries.window = window
    }

    func install(commands: CommandRegistry, panels: PanelRegistry, extensions: ExtensionRegistry, documents: DocumentController?) {
        masters.documents = documents
        let masters = masters
        DocumentPanelModel.editMaster = { window, master in masters.open(master, from: window) }
        views.install(commands: commands)
        similar.install(commands: commands)
        // The bundled shape model compiles once at launch; *Shape* joins the menu when it is ready.
        let load = loadShapeClassifier
        shapeLoading = Task { [weak self] in
            guard let classifier = await load(), let self else { return }
            self.similar.classifier = classifier
            self.similar.install(commands: commands)
            self.onMenuChange?()
        }
        combine.install(commands: commands, extensions: extensions)
        ColorSettingsSheet.showProfiles = { [weak self] document in self?.showProfiles(document) }
        for (id, kind) in [("swatches", LibraryCatalog.Kind.swatch), ("styles", .style), ("library", .symbol)] {
            if let descriptor = panels.descriptor(for: PanelID(id)) { panels.replace(teamLibraries.adding(kind, to: descriptor)) }
        }
        profileScan.start { documents?.documents ?? [] }
    }

    /// A document window opened: the canvas handles, the named views, the master notices and the
    /// team libraries follow it.
    func attach(_ window: DocumentWindowController) {
        let polygons = PolygonShapeHandles()
        polygons.activeTool = { [weak window] in window?.toolManager.activeToolID }
        let rectangles = RectangleRadiusHandles()
        rectangles.activeTool = { [weak window] in window?.toolManager.activeToolID }
        window.toolManager.handleLayers += [ClipContentsHandle(), polygons, rectangles, ImageResolutionHandles()]
        shapeNotices[ObjectIdentifier(window)] = ShapeConversionNotice(window: window)
        views.attach(window)
        let key = ObjectIdentifier(window)
        notices[key] = MasterNotices(window: window)
        let teamLibraries = teamLibraries
        window.documentHandle.observe { [weak window] change in
            if let state = window?.documentHandle.state { teamLibraries.documentDidChange(change.change, state: state) }
        }
        let previous = window.onClose
        window.onClose = { [weak self] closed in
            previous?(closed)
            self?.detach(closed)
        }
    }

    /// The window closed.
    func detach(_ window: DocumentWindowController) {
        notices.removeValue(forKey: ObjectIdentifier(window))?.stop()
        shapeNotices.removeValue(forKey: ObjectIdentifier(window))?.stop()
    }

    /// The Color Settings sheet's btn:[Profiles…]: the sheet for `document`.
    @discardableResult
    func showProfiles(_ document: DocumentHandle) -> ProfilesModel {
        if let profiles { return profiles }
        let model = ProfilesModel(document: document) { [weak self] in
            self?.profiles?.stop()
            self?.profiles = nil
            self?.sheets.dismiss(Self.profilesSheet)
        }
        profiles = model
        sheets.present(ProfilesSheet(model: model), title: "Profiles", identifier: Self.profilesSheet)
        return model
    }
}

extension AppDelegate {
    /// Launch: the commands, handles, panels' sections and hooks; new documents' ids are UUIDv7s
    /// from `DocumentCreation` (DOC-019).
    func installDocumentGlue() {
        documentGlue.views.onMenuChange = { [weak self] in self?.rebuildMainMenu() }
        documentGlue.onMenuChange = { [weak self] in self?.rebuildMainMenu() }
        documentGlue.install(commands: commands, panels: panels, extensions: toolbars.extensions, documents: documents)
        library.makeID = { DocumentCreation.newDocumentID() }
    }

    func attachDocumentGlue(_ window: DocumentWindowController) {
        documentGlue.attach(window)
    }
}
