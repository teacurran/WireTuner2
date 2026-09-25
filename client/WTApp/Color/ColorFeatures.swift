import AppKit
import SwiftUI
import WTModel
import WTProto
import WTSync

/// Everything the colour epics add to the app, installed by `AppDelegate` in one call: the
/// Swatches, Color Mixer and Tints panels (they replace the catalog's placeholders), menu:File
/// [Color Settings…], [Make Team Color Library…] and [Publish Library Version], the Extensions
/// menu's *Name All Colors*, *Sort Color List by Name* and *Delete > Unused Named Colors*, and the
/// sheets behind them.
@MainActor
final class ColorFeatures {
    enum ID {
        static let colorSettings: CommandID = "file.colorSettings"
        static let makeTeamLibrary: CommandID = "file.makeTeamColorLibrary"
        static let publishLibraryVersion: CommandID = "file.publishLibraryVersion"
    }

    static let noDocument = "No document is open"
    static let signedOut = "Sign in to share colors with a team"

    let workspace: ColorWorkspace
    let swatchesPanel: SwatchesPanelModel
    let mixer: ColorMixerModel
    let tints: TintsModel
    let teamLibraries: TeamLibrariesModel
    /// The bundled libraries, *My Libraries*, *Import…*, *Export…* and *Import RGB Color Table…*.
    let libraries: ColorLibraryMenu
    /// The open documents (*Import from Document…*).
    var openDocuments: @MainActor () -> [DocumentHandle] = { [] }
    /// The Options menu's *Color Control…* (COLOR-017's sheet), once installed.
    var colorControl: (@MainActor () -> PanelMenuItem)?

    init(selection: ActiveSelection, preferences: PreferenceStore? = nil, defaults: UserDefaults? = nil, libraryClient: ColorLibraryClient? = nil,
         teams: @escaping @MainActor () -> [TeamLibrariesModel.Team] = { [] }) {
        workspace = ColorWorkspace(selection: selection, preferences: preferences)
        swatchesPanel = SwatchesPanelModel(workspace: workspace)
        mixer = ColorMixerModel(workspace: workspace, defaults: defaults)
        tints = TintsModel(workspace: workspace)
        teamLibraries = TeamLibrariesModel(workspace: workspace, client: libraryClient, teams: teams)
        libraries = ColorLibraryMenu(workspace: workspace)
        let tints = tints
        swatchesPanel.loadTint = { tints.load($0) }
    }

    // MARK: Installing

    /// Registers the panels (before `PanelCatalog.register`, whose placeholders they replace),
    /// the commands and the Extensions menu operations.
    func install(commands: CommandRegistry, panels: PanelRegistry, extensions: ExtensionRegistry,
                 documents: @escaping @MainActor () -> [DocumentHandle]) {
        openDocuments = documents
        for descriptor in panelDescriptors() { panels.registerIfAbsent(descriptor) }
        for command in self.commands() { commands.replace(command) }
        for descriptor in extensionDescriptors(existing: extensions) { extensions.replace(descriptor) }
    }

    // MARK: Panels

    func panelDescriptors() -> [PanelDescriptor] {
        let swatches = swatchesPanel
        let mixer = mixer
        let tints = tints
        return [
            PanelDescriptor(id: "swatches", title: "Swatches", icon: "square.grid.3x3.fill", defaultGroup: PanelCatalog.Group.assets, menuOrder: 30,
                            helpSlug: "swatches", optionsMenu: { [weak self] in self?.swatchesMenu() ?? [] }) {
                SwatchesPanelBody(model: swatches)
            },
            PanelDescriptor(id: "colorMixer", title: "Color Mixer", icon: "paintpalette", defaultGroup: PanelCatalog.Group.mixer, menuOrder: 40,
                            helpSlug: "color-mixer") {
                ColorMixerBody(model: mixer)
            },
            PanelDescriptor(id: "tints", title: "Tints", icon: "circle.lefthalf.filled", defaultGroup: PanelCatalog.Group.mixer, menuOrder: 41,
                            helpSlug: "tints") {
                TintsPanelBody(model: tints)
            },
        ]
    }

    /// The Swatches panel's Options menu with the sheets this feature owns.
    func swatchesMenu() -> [PanelMenuItem] {
        let hasDocument = workspace.swatches != nil
        return swatchesPanel.optionsMenu(extras: [replaceMenuItem()] + libraries.menuItems() + [
            PanelMenuItem(title: "Import from Document…", isEnabled: hasDocument) { [weak self] in self?.showImportFromDocument() },
            PanelMenuItem(title: teamLibraries.hasUpdates ? "Team Libraries… •" : "Team Libraries…", isEnabled: hasDocument && teamLibraries.client != nil) { [weak self] in
                self?.showTeamLibraries()
            },
            PanelMenuItem(title: "Restore Deleted Colors…", isEnabled: hasDocument) { [weak self] in self?.showRestoreDeleted() },
        ] + (colorControl.map { [$0()] } ?? []))
    }

    // MARK: Commands

    func commands() -> [Command] {
        let file = StandardCommands.Menu.file
        let needsDocument: @MainActor @Sendable () -> CommandValidation = { [weak self] in self?.workspace.swatches == nil ? .disabled(Self.noDocument) : .enabled }
        return [
            Command(id: ID.colorSettings, title: "Color Settings…", menu: MenuPath(file, section: 5), keywords: ["profile", "icc", "cmyk", "proof", "color management"],
                    validation: needsDocument, action: .perform { [weak self] in self?.showColorSettings() }),
            Command(id: ID.makeTeamLibrary, title: "Make Team Color Library…", menu: MenuPath(file, section: 5), keywords: ["swatches", "team", "library", "publish"],
                    validation: { [weak self] in self?.teamLibraryValidation() ?? .disabled(Self.noDocument) },
                    action: .perform { [weak self] in self?.showMakeTeamLibrary() }),
            Command(id: ID.publishLibraryVersion, title: "Publish Library Version", menu: MenuPath(file, section: 5), keywords: ["team", "library"],
                    validation: { [weak self] in self?.teamLibraryValidation() ?? .disabled(Self.noDocument) },
                    action: .perform { [weak self] in self?.publishVersion() }),
        ]
    }

    /// Team library commands need a document, a client and a connection.
    func teamLibraryValidation() -> CommandValidation {
        guard workspace.swatches != nil else { return .disabled(Self.noDocument) }
        guard teamLibraries.client != nil else { return .disabled(Self.signedOut) }
        return teamLibraries.isOffline ? .disabled(TeamLibrariesModel.offlineReason) : .enabled
    }

    /// The Extensions menu's colour operations, replacing their stubs.
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        let operations: [(String, @MainActor () -> Void)] = [
            ("nameAllColors", { [weak self] in self?.nameAllColors() }),
            ("sortColorListByName", { [weak self] in self?.sortColors() }),
            ("deleteUnusedNamedColors", { [weak self] in self?.showDeleteUnused() }),
            ("importRGBColorTable", { [weak self] in self?.libraries.beginImportColorTable() }),
        ]
        return operations.compactMap { id, run in
            guard var descriptor = existing.descriptor(for: id) else { return nil }
            descriptor.validate = { [weak self] in self?.workspace.swatches == nil ? .disabled(Self.noDocument) : .enabled }
            descriptor.run = { _ in
                run()
                return nil
            }
            return descriptor
        }
    }

    // MARK: Actions

    /// menu:Extensions[Colors > Name All Colors].
    @discardableResult
    func nameAllColors() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.perform(NameAllColors(index: workspace.swatches?.index))
    }

    /// menu:Extensions[Colors > Sort Color List by Name].
    @discardableResult
    func sortColors() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.perform(SortSwatches())
    }

    func showDeleteUnused() {
        workspace.present(DeleteUnusedSheet(model: DeleteUnusedModel(workspace: workspace)), title: "Delete Unused Named Colors", identifier: DeleteUnusedModel.sheet)
    }

    func showRestoreDeleted() {
        workspace.present(RestoreDeletedSheet(model: RestoreDeletedModel(workspace: workspace)), title: "Restore Deleted Colors", identifier: RestoreDeletedModel.sheet)
    }

    func showImportFromDocument() {
        let model = ImportFromDocumentModel(workspace: workspace, documents: openDocuments())
        workspace.present(ImportFromDocumentSheet(model: model), title: "Import from Document", identifier: ImportFromDocumentModel.sheet)
    }

    func showColorSettings() {
        let model = ColorSettingsModel(workspace: workspace)
        model.loadFile = ProfileBlobGlue.shared?.loader(for: workspace.document)
        workspace.present(ColorSettingsSheet(model: model), title: "Color Settings", identifier: ColorSettingsModel.sheet)
    }

    /// *Team Libraries…*: the sheet, refreshed from the server (or the cache offline).
    @discardableResult
    func showTeamLibraries() -> Task<Void, Never> {
        let teamLibraries = teamLibraries
        workspace.present(TeamLibrariesSheet(model: teamLibraries), title: "Team Libraries", identifier: TeamLibrariesModel.sheet)
        return Task { await teamLibraries.refresh() }
    }

    func showMakeTeamLibrary() {
        workspace.present(MakeTeamLibrarySheet(model: teamLibraries), title: "Make Team Color Library", identifier: MakeTeamLibrarySheet.identifier)
    }

    @discardableResult
    func publishVersion() -> Task<Bool, Never> {
        let teamLibraries = teamLibraries
        return Task { await teamLibraries.publishVersion() }
    }
}

/// menu:File[Make Team Color Library…]: which team the front document's colours go to.
struct MakeTeamLibrarySheet: View {
    let model: TeamLibrariesModel
    @State private var team = ""

    static let identifier = "make-team-library-sheet"

    static func publishing(_ team: Binding<String>, _ model: TeamLibrariesModel) -> () -> Void {
        {
            let chosen = team.wrappedValue.isEmpty ? model.teams().first?.id ?? "" : team.wrappedValue
            Task {
                if await model.publish(to: chosen) { model.workspace.dismiss(identifier) }
            }
        }
    }

    static func cancelling(_ model: TeamLibrariesModel) -> () -> Void {
        { model.workspace.dismiss(identifier) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make Team Color Library").font(.headline)
            Text("Everyone in the team can add this document's colors from Team Libraries.").font(.callout)
            Picker("Team", selection: $team) {
                ForEach(model.teams()) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("make-library.team")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(model)).keyboardShortcut(.cancelAction)
                Button("Publish", action: Self.publishing($team, model)).keyboardShortcut(.defaultAction).disabled(model.teams().isEmpty)
                    .accessibilityIdentifier("make-library.publish")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
