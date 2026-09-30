import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Document panel's own state, app-wide like the panel (document-panel.adoc; DOC-004): the
/// front window it works on, whether the pasteboard view shows the page list, and a revision the
/// body reads so a change to the pages, the active page or the settings -- local or remote -- shows
/// at once.
@MainActor
@Observable
final class DocumentPanelState {
    /// Bumped when the followed document's pages, active page or settings change.
    private(set) var revision = 0
    /// The page list instead of the pasteboard view.
    var showsList = false
    /// The front document window: its document, commands, sheets and the magnification.
    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    @ObservationIgnored private var followed: (document: DocumentHandle, token: DocumentHandle.ObservationToken)?

    init() {}

    /// Follows `document`'s structure changes (the body calls it on every render).
    func follow(_ document: DocumentHandle?) {
        guard followed?.document !== document else { return }
        if let followed { followed.document.stopObserving(followed.token) }
        followed = document.map { document in (document, document.observeStructure { [weak self] in self?.revision += 1 }) }
    }

    func touch() { revision += 1 }
}

/// What the Document panel shows for the front window and what its controls do
/// (document-panel.adoc, "Setting page options", "Printer resolution", the Options menu): read on
/// every render, each control one change through the window's object commands.  The page options
/// apply to the selected pages (the Page tool's selection, else the active page); on a child of a
/// master they are the master's and cannot be changed.
@MainActor
struct DocumentPanelModel {
    let window: DocumentWindowController

    var document: DocumentHandle { window.documentHandle }
    var pages: [Page] { document.selectedPages }
    var targets: [OpID] { pages.map(\.id) }
    var settings: DocumentSettings { document.settings }
    var units: Units { document.unitConverter }

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        window.objectEditing.perform(command)
    }

    /// Whether every selected page follows a master (its size, orientation and bleed are the
    /// master's).
    var followsMaster: Bool { pages.allSatisfy(\.isChild) }

    /// A master page's tab is in front (DOC-012): the page controls read and write the master; it
    /// follows no master and page order does not apply.
    var isMasterTab: Bool { document.pageList.isMasterCanvas }
    static let masterTabHelp = "A master page follows no master"

    // MARK: Page size

    /// The title the Page Size pop-up item custom is shown with.
    static let customTitle = "Custom"
    static let editTitle = "Edit…"

    /// The Page Size pop-up's sizes: the standard ones, the document's custom ones, then Custom.
    var presetItems: [String] { settings.presetNames + [Self.customTitle] }

    /// The selected pages' size as the pop-up shows it: their shared preset, *Custom*, or nil
    /// when they differ.
    var pageSize: String? {
        shared(pages.map { $0.geometry.preset.isEmpty ? Self.customTitle : $0.geometry.preset })
    }

    /// A size chosen in the pop-up: its width and height at each page's orientation ("Change page
    /// size"); *Custom* keeps the size and drops the preset.
    func choosePageSize(_ name: String) {
        guard !followsMaster else { return }
        if name == Self.customTitle {
            let edits = pages.filter { !$0.geometry.preset.isEmpty }.map { page -> any WTModel.Command in
                var geometry = page.ownGeometry
                geometry.preset = ""
                return SetPageGeometry([page.id], to: geometry)
            }
            if !edits.isEmpty { perform(edits.count == 1 ? edits[0] : CommandBatch("Change page size", edits)) }
            return
        }
        guard let size = settings.portraitSize(of: name) else { return }
        let orientation = shared(pages.map(\.geometry.orientation)) ?? .portrait
        perform(SetPageGeometry(targets, to: PageGeometry(preset: name, portrait: size, orientation: orientation)))
    }

    /// The selected pages' shared orientation.
    var orientation: PageGeometry.Orientation? { shared(pages.map(\.geometry.orientation)) }

    /// The portrait and landscape buttons ("Change orientation").
    func setOrientation(_ orientation: PageGeometry.Orientation) {
        guard !followsMaster, self.orientation != orientation else { return }
        perform(SetPageOrientation(targets, to: orientation))
    }

    /// The width and height of the page as shown under the pop-up ("612 × 792 pt").
    var sizeLine: String? {
        guard let page = pages.first, pages.count == 1 else { return nil }
        return "\(units.format(page.geometry.width)) × \(units.format(page.geometry.height, suffix: true))"
    }

    // MARK: Bleed and resolution

    /// The selected pages' shared bleed, points.
    var bleed: Double? { shared(pages.map(\.bleed)) }

    /// A bleed typed and committed ("Change bleed").
    func setBleed(_ points: Double) {
        guard !followsMaster, points >= 0, points <= 720, points != bleed else { return }
        perform(SetBleed(targets, to: points))
    }

    var resolution: Int { settings.printerResolution }

    /// A resolution chosen or typed ("Change printer resolution"); out of range is refused.
    func setResolution(_ dpi: Int) {
        guard dpi != resolution, (72...9600).contains(dpi) else { return }
        perform(SetPrinterResolution(dpi))
    }

    // MARK: Master page

    static let noMaster = "None"

    var masters: [MasterPage] { document.pageList.masters }

    /// The selected pages' shared master: `.some(nil)` for none, nil when they differ.
    var master: OpID?? { shared(pages.map(\.master)) }

    /// The Master Page pop-up: a master applies to the selected pages ("Apply master page"); *None*
    /// detaches them keeping their size ("Detach from master page").
    func chooseMaster(_ id: OpID?) {
        guard !isMasterTab else { return }
        if let id {
            let pending = pages.filter { $0.master != id }.map(\.id)
            guard !pending.isEmpty else { return }
            perform(ApplyMasterPage(id, to: pending))
        } else {
            let children = pages.filter(\.isChild).map(\.id)
            guard !children.isEmpty else { return }
            perform(DetachFromMaster(children))
        }
    }

    // MARK: Options menu

    /// The Options menu's page commands (document-panel.adoc, "Page commands in the Options menu").
    func optionsMenu() -> [PanelMenuItem] {
        let window = self.window
        let document = self.document
        let page = document.activePage
        let pageCount = document.pageList.pages.count
        // On a master's tab the page commands (order, duplicates, masters, release) do not apply.
        guard !isMasterTab else {
            return ["Add Pages…", "Duplicate", "Remove", "Move Page…", "New Master Page", "Convert to Master Page", "Release Child Page"]
                .map { PanelMenuItem(title: $0, isEnabled: false) {} }
        }
        // A single-page document never gets a second page (FONT-003).
        let addsPages = DocumentKind(document.state) != .singlePage
        return [
            PanelMenuItem(title: "Add Pages…", isEnabled: addsPages) { window.presentAddPagesSheet() },
            PanelMenuItem(title: "Duplicate", isEnabled: addsPages) { window.objectEditing.perform(DuplicatePage(page.id)) },
            PanelMenuItem(title: "Remove", isEnabled: pageCount > 1) { window.removeSelectedPages() },
            PanelMenuItem(title: "Move Page…", isEnabled: pageCount > 1) { window.presentMovePageSheet() },
            PanelMenuItem(title: "New Master Page") { window.objectEditing.perform(NewMasterPage(from: page.id)) },
            PanelMenuItem(title: "Convert to Master Page", isEnabled: !page.isChild) { window.objectEditing.perform(ConvertToMasterPage(page.id)) },
            PanelMenuItem(title: "Release Child Page", isEnabled: document.selectedPages.contains(where: \.isChild)) {
                window.objectEditing.perform(ReleaseChildPages(document.selectedPages.filter(\.isChild).map(\.id), in: document.state))
            },
        ]
    }
}

extension DocumentWindowController {
    /// The Options menu's *Remove*: the selected pages, after confirming when objects go with
    /// them (the Page tool's kbd:[Delete] rule).
    func removeSelectedPages() {
        PageTool().removeSelected(in: toolManager.context)
    }
}

/// The Document panel body: the Page Size row, Bleed and Printer Resolution, the Master Page row,
/// and the pasteboard view (or the page list) with its magnification buttons.
struct DocumentPanelBody: View {
    let state: DocumentPanelState

    var body: some View {
        let _ = state.revision
        let window = state.window()
        let _ = state.follow(window?.documentHandle)
        let _ = window?.documentHandle.model?.revision
        if let window {
            DocumentPanelControls(model: DocumentPanelModel(window: window), state: state)
        } else {
            Text("No document").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("document.none")
        }
    }
}

struct DocumentPanelControls: View {
    let model: DocumentPanelModel
    let state: DocumentPanelState

    static let resolutions = SetPrinterResolution.presets

    /// The resolution pop-up's items: the presets, and the document's own value when it is not one.
    static func resolutionItems(_ current: Int) -> [Int] {
        resolutions.contains(current) ? resolutions : resolutions + [current]
    }

    /// The magnification buttons' symbols.
    static let scaleSymbols = ["minus.magnifyingglass", "1.magnifyingglass", "plus.magnifyingglass"]

    // The controls' bindings and actions, as values the tests can drive.

    static func pageSize(_ model: DocumentPanelModel) -> Binding<String> {
        Binding(get: { model.pageSize ?? "" }, set: { model.choosePageSize($0) })
    }

    static func resolution(_ model: DocumentPanelModel) -> Binding<Int> {
        Binding(get: { model.resolution }, set: { model.setResolution($0) })
    }

    static func master(_ model: DocumentPanelModel) -> Binding<OpID?> {
        Binding(get: { model.master ?? nil }, set: { model.chooseMaster($0) })
    }

    static func showsList(_ state: DocumentPanelState) -> Binding<Bool> {
        Binding(get: { state.showsList }, set: { state.showsList = $0 })
    }

    static func orientation(_ model: DocumentPanelModel, _ orientation: PageGeometry.Orientation) -> () -> Void {
        { model.setOrientation(orientation) }
    }

    static func scale(_ model: DocumentPanelModel, _ scale: Int) -> () -> Void {
        { model.window.documentPanelScale = scale }
    }

    static func editSizes(_ model: DocumentPanelModel) -> () -> Void {
        { model.window.presentPageSizesSheet() }
    }

    static func typedResolution(_ model: DocumentPanelModel) -> (Double) -> Void {
        { model.setResolution(Int($0)) }
    }

    static func editMaster(_ model: DocumentPanelModel) -> () -> Void {
        { if let master = MasterTabs.editableMaster(in: model.window) { DocumentPanelModel.editMaster(model.window, master) } }
    }

    static func masterName(_ master: MasterPage) -> String {
        master.name.isEmpty ? "Master" : master.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Page Size", selection: Self.pageSize(model)) {
                    ForEach(model.presetItems, id: \.self) { Text($0).tag($0) }
                }
                .disabled(model.followsMaster)
                .accessibilityIdentifier("document.pageSize")
                Button(action: Self.orientation(model, .portrait)) { Image(systemName: "rectangle.portrait") }
                    .disabled(model.followsMaster)
                    .accessibilityIdentifier("document.portrait")
                Button(action: Self.orientation(model, .landscape)) { Image(systemName: "rectangle") }
                    .disabled(model.followsMaster)
                    .accessibilityIdentifier("document.landscape")
                Button(DocumentPanelModel.editTitle, action: Self.editSizes(model)).accessibilityIdentifier("document.editSizes")
            }
            if let line = model.sizeLine { Text(line).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("document.size") }
            MeasureField(title: "Bleed", value: model.bleed, units: model.units, identifier: "document.bleed", commit: model.setBleed)
                .disabled(model.followsMaster)
            HStack {
                Picker("Printer Resolution", selection: Self.resolution(model)) {
                    ForEach(Self.resolutionItems(model.resolution), id: \.self) { Text("\($0) dpi").tag($0) }
                }
                .accessibilityIdentifier("document.resolution")
                CommitField(title: "dpi", value: Double(model.resolution), identifier: "document.resolution.field", commit: Self.typedResolution(model))
                    .frame(width: 60)
            }
            HStack {
                Picker("Master Page", selection: Self.master(model)) {
                    Text(DocumentPanelModel.noMaster).tag(OpID?.none)
                    ForEach(model.masters) { Text(Self.masterName($0)).tag(OpID?.some($0.id)) }
                }
                .disabled(model.isMasterTab)
                .help(model.isMasterTab ? DocumentPanelModel.masterTabHelp : "")
                .accessibilityIdentifier("document.master")
                Button("Edit", action: Self.editMaster(model))
                    .disabled(MasterTabs.editableMaster(in: model.window) == nil)
                    .help(MasterTabs.editableMaster(in: model.window) == nil ? MasterTabs.noSingleMaster : "")
                    .accessibilityIdentifier("document.master.edit")
            }
            if state.showsList {
                PageListView(model: model)
            } else {
                PasteboardMiniature(window: model.window, revision: state.revision)
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("document.pasteboard")
            }
            HStack {
                ForEach(0..<3) { scale in
                    Button(action: Self.scale(model, scale)) { Image(systemName: Self.scaleSymbols[scale]) }
                        .accessibilityIdentifier("document.scale.\(scale)")
                }
                Spacer()
                Toggle(isOn: Self.showsList(state)) { Image(systemName: "list.bullet") }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("document.list")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension DocumentPanelModel {
    /// btn:[Edit] beside the *Master Page* pop-up: opens the selected pages' master in its tab
    /// (`MasterTabs`, DOC-012); the app sets it at launch.
    static var editMaster: @MainActor (DocumentWindowController, OpID) -> Void = { _, _ in }
}

/// The page list (pages.adoc, "Page order"): pages in page order with their number, name and
/// size; dragging one reorders it ("Move page N").
struct PageListView: View {
    let model: DocumentPanelModel

    var body: some View {
        let pages = model.document.pageList.pages
        List {
            ForEach(pages) { page in
                HStack {
                    Text("\(page.number)").monospacedDigit().frame(width: 24, alignment: .trailing)
                    Text(PageSelection.name(of: page.number - 1, label: page.name))
                    Spacer()
                    Text(page.geometry.preset.isEmpty ? DocumentPanelModel.customTitle : page.geometry.preset).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: Self.select(page, in: model))
                .accessibilityIdentifier("document.page.\(page.number)")
            }
            .onMove(perform: Self.mover(model))
        }
        .frame(minHeight: 160)
        // The group's frosted card shows through (D-077, revised).
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("document.pageList")
    }

    static func select(_ page: Page, in model: DocumentPanelModel) -> () -> Void {
        { model.document.selectPage(id: page.id) }
    }

    static func mover(_ model: DocumentPanelModel) -> (IndexSet, Int) -> Void {
        { from, to in move(from: from, to: to, in: model) }
    }

    /// A row dragged from `from` to before row `to`: the page takes that place in page order.
    static func move(from: IndexSet, to: Int, in model: DocumentPanelModel) {
        let pages = model.document.pageList.pages
        guard let index = from.first, pages.indices.contains(index) else { return }
        let number = to > index ? to : to + 1
        guard number != index + 1 else { return }
        model.perform(ReorderPage(pages[index].id, to: min(max(number, 1), pages.count)))
    }
}

/// The Document panel's registration (it replaces the catalog's placeholder).
enum DocumentPanel {
    static func descriptor(state: DocumentPanelState) -> PanelDescriptor {
        PanelDescriptor(id: "document", title: "Document", icon: "doc.on.doc", defaultGroup: PanelCatalog.Group.properties, menuOrder: 11,
                        helpSlug: "document-panel", optionsMenu: { state.window().map { DocumentPanelModel(window: $0).optionsMenu() } ?? [] }) {
            DocumentPanelBody(state: state)
        }
    }
}
