import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The menu items, context-menu items and panels the control reachability audit (rch) found built
/// at model level but left as "Not available yet" placeholders, wired to the commands and views
/// that already exist (rch-inventory.md; context-menus.adoc, "As built").  Each command replaces
/// the catalog's placeholder in place, so it keeps its menu position.
@MainActor
final class ReachabilityFeatures {
    typealias Window = @MainActor () -> DocumentWindowController?

    enum ID {
        static let convertToSymbol: CommandID = "modify.symbol.convertToSymbol"
    }

    static let noDocument = ViewCommands.noDocument
    static let noObject = "Select an object"
    static let noGroup = "Select a group"
    static let noClipGroup = "Select a clipping path"
    static let noConnector = "Select a connector"
    static let noPathOrConnector = "Select a path or a connector"
    static let noGuide = "Control-click a guide"
    static let noCollaboratorPage = "Nobody else is on a page"
    static let onePage = "The document has one page"
    static let notInLibrary = "The document is not in the library yet"

    let window: Window
    /// menu:Window[<panel>] and the context menus' *Object Panel*: shows and focuses a panel.
    var showPanel: @MainActor (PanelID) -> Void = { _ in }
    /// Runs another registered command (Add to Library… runs Convert to Symbol).
    var perform: @MainActor (CommandID) -> Bool = { _ in false }
    /// menu:File[Show in Library].
    var showLibrary: @MainActor () -> Void = {}
    /// The library entry of a document id (its name), nil when it has none.
    var libraryName: @MainActor (String) -> String? = { _ in nil }
    /// menu:File[Rename Document…]: renames the library entry.
    var rename: @MainActor (String, String) -> Void = { _, _ in }
    /// The guide each window's context menu was opened on (page and the coincident guides).
    private(set) var contextGuides: [ObjectIdentifier: (page: OpID, guides: [OpID])] = [:]

    init(window: @escaping Window) {
        self.window = window
    }

    // MARK: Modify

    /// The selected groups (Enter Group), nil unless every selected object is a group.
    static func groups(_ window: DocumentWindowController) -> [OpID]? {
        let nodes = window.objectEditing.selectedNodes
        let state = window.documentHandle.state
        guard !nodes.isEmpty, nodes.allSatisfy({ state.nodeKind($0) == .group }) else { return nil }
        return nodes
    }

    /// The clip group of the one selected object (Edit Contents).
    static func clipGroup(_ window: DocumentWindowController) -> OpID? {
        guard let node = EditFeatures.single(window) else { return nil }
        return EditFeatures.clipGroup(of: node, in: window.documentHandle.state)
    }

    static func connectors(_ window: DocumentWindowController) -> [OpID] {
        ConnectorCommands.selectedConnectors(window.objectEditing)
    }

    /// menu:Modify[Alter Path > Reverse Direction]: every selected path's contours reversed and
    /// every selected connector's ends swapped, one change "Reverse Direction".
    static func reverseCommand(_ window: DocumentWindowController) -> (any WTModel.Command)? {
        let paths = DistortFeatures.paths(window.objectEditing)
        let connectors = connectors(window)
        var commands: [any WTModel.Command] = paths.map { ReverseContours(node: $0) }
        if !connectors.isEmpty { commands.append(ReverseConnectors(connectors)) }
        guard !commands.isEmpty else { return nil }
        return commands.count == 1 ? commands[0] : CommandBatch("Reverse Direction", commands)
    }

    /// menu:Modify[Connector > Detach Ends]: both ends of each selected connector freed where they
    /// are now, one change "Detach Ends".
    static func detachCommand(_ window: DocumentWindowController) -> (any WTModel.Command)? {
        let state = window.documentHandle.state
        let scene = window.documentHandle.scene
        let commands: [any WTModel.Command] = connectors(window).flatMap { node -> [any WTModel.Command] in
            guard let route = Connectors.route(node, in: state, scene: scene), let first = route.points.first, let last = route.points.last else { return [] }
            return [SetConnectorEnd(node, .start, to: ConnectorEnd(point: first)), SetConnectorEnd(node, .end, to: ConnectorEnd(point: last))]
        }
        return commands.isEmpty ? nil : CommandBatch("Detach Ends", commands)
    }

    /// menu:Modify[Connector > Reroute]: each selected connector back to automatic routing (its
    /// run offsets cleared), one change "Reroute".
    static func rerouteCommand(_ window: DocumentWindowController) -> (any WTModel.Command)? {
        let commands: [any WTModel.Command] = connectors(window).map { SetConnectorRunOffsets($0, offsets: []) }
        return commands.isEmpty ? nil : CommandBatch("Reroute", commands)
    }

    // MARK: Guides

    /// The context-menu resolver's guide hook for `window`: the guide under the pointer, which the
    /// guide commands then act on.
    func attach(_ window: DocumentWindowController) {
        let key = ObjectIdentifier(window)
        window.contextResolver.guide = { [weak self, weak window] point in
            guard let window, let hit = window.furniture.guide(at: point, viewport: window.viewport, tolerance: window.toolManager.context.snapping.pickDistance()) else {
                self?.contextGuides[key] = nil
                return nil
            }
            self?.contextGuides[key] = (hit.page.id, hit.guide.ids)
            return .guide(locked: window.documentHandle.settings.guidesLocked)
        }
    }

    /// The guide `window`'s context menu is for, while that menu's target is a guide.
    func contextGuide(_ window: DocumentWindowController) -> (page: OpID, guides: [OpID])? {
        guard case .guide? = window.contextTarget else { return nil }
        return contextGuides[ObjectIdentifier(window)]
    }

    // MARK: Commands

    func commands() -> [Command] {
        modifyCommands() + objectCommands() + pageCommands() + fileCommands() + editCommands() + viewCommands()
    }

    func modifyCommands() -> [Command] {
        let window = window
        let ids = ContextMenuCatalog.ID.self
        let modify = ContextMenuCatalog.Menu.modify
        func run(_ make: @escaping @MainActor (DocumentWindowController) -> (any WTModel.Command)?) -> CommandAction {
            .perform { if let front = window(), let command = make(front) { front.objectEditing.perform(command) } }
        }
        return [
            Command(id: ids.enterGroup, title: "Enter Group", menu: MenuPath(modify, section: 0), contexts: [.group], keywords: ["group", "members", "subselect"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return Self.groups(front) != nil && front.selection.canSubselectAll ? .enabled : .disabled(Self.noGroup)
                    },
                    action: .perform { if let front = window(), Self.groups(front) != nil { front.selection.subselectAll() } }),
            Command(id: ids.reverseDirection, title: "Reverse Direction", menu: MenuPath(modify, "Alter Path", section: 3),
                    keywords: ["direction", "path", "connector", "arrowheads", "swap ends"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return Self.reverseCommand(front) == nil ? .disabled(Self.noPathOrConnector) : .enabled
                    },
                    action: run(Self.reverseCommand)),
            Command(id: ids.editContents, title: "Edit Contents", menu: MenuPath(modify, "Clipping", section: 4), contexts: [.clip],
                    keywords: ["clip", "contents", "subselect"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return Self.clipGroup(front) == nil ? .disabled(Self.noClipGroup) : .enabled
                    },
                    action: .perform {
                        guard let front = window(), let group = Self.clipGroup(front) else { return }
                        front.selection.model.set(Selection([SelectionID(group)]))
                        front.selection.subselectAll()
                    }),
            Command(id: ids.reroute, title: "Reroute", menu: MenuPath(modify, "Connector", section: 4), contexts: [.connector], keywords: ["connector", "route"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return Self.connectors(front).isEmpty ? .disabled(Self.noConnector) : .enabled
                    },
                    action: run(Self.rerouteCommand)),
            Command(id: ids.detachEnds, title: "Detach Ends", menu: MenuPath(modify, "Connector", section: 4), contexts: [.connector], keywords: ["connector", "free"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return Self.connectors(front).isEmpty ? .disabled(Self.noConnector) : .enabled
                    },
                    action: run(Self.detachCommand)),
        ]
    }

    func objectCommands() -> [Command] {
        let window = window
        let ids = ContextMenuCatalog.ID.self
        let object = ContextMenuCatalog.Menu.object
        let hasSelection: @MainActor @Sendable () -> CommandValidation = {
            guard let front = window() else { return .disabled(Self.noDocument) }
            return front.objectEditing.selectedNodes.isEmpty ? .disabled(Self.noObject) : .enabled
        }
        return [
            Command(id: ids.name, title: "Name…", menu: MenuPath(object, section: 1), contexts: ContextMenuCatalog.objectContexts, keywords: ["name", "label"],
                    validation: hasSelection, action: .perform { [weak self] in if let front = window() { self?.showNameSheet(.name, on: front) } }),
            Command(id: ids.note, title: "Note…", menu: MenuPath(object, section: 1), contexts: ContextMenuCatalog.objectContexts, keywords: ["note", "comment"],
                    validation: hasSelection, action: .perform { [weak self] in if let front = window() { self?.showNameSheet(.note, on: front) } }),
            Command(id: ids.link, title: "Link…", menu: MenuPath(object, section: 1), contexts: ContextMenuCatalog.objectContexts, keywords: ["link", "url", "navigation"],
                    validation: hasSelection, action: .perform { [weak self] in self?.showPanel("navigation") }),
            Command(id: ids.addToLibrary, title: "Add to Library…", menu: MenuPath(object, section: 1), contexts: ContextMenuCatalog.objectContexts,
                    keywords: ["symbol", "library"],
                    validation: { [weak self] in
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        guard !front.objectEditing.selectedNodes.isEmpty else { return .disabled(Self.noObject) }
                        return self?.validation(ID.convertToSymbol) ?? .enabled
                    },
                    action: .perform { [weak self] in
                        guard let self, self.perform(ID.convertToSymbol) else { return }
                        self.showPanel("library")
                    }),
            Command(id: ids.trace, title: "Trace…", menu: MenuPath(object, "Image", section: 0), contexts: [.bitmap], keywords: ["trace", "image", "vectorize"],
                    validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
                    action: .perform { window()?.toolManager.select(TraceTool.id) }),
        ]
    }

    /// The validation of another command (nil when it is not registered).
    var validate: @MainActor (CommandID) -> CommandValidation? = { _ in nil }

    func validation(_ id: CommandID) -> CommandValidation? { validate(id) }

    func pageCommands() -> [Command] {
        let window = window
        let ids = ContextMenuCatalog.ID.self
        let path = MenuPath(ContextMenuCatalog.Menu.object, "Page", section: 2)
        return [
            Command(id: ids.duplicatePage, title: "Duplicate Page", menu: path, contexts: [.page], keywords: ["page", "copy"],
                    validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
                    action: .perform {
                        guard let front = window() else { return }
                        front.objectEditing.perform(DuplicatePage(front.documentHandle.activePage.id))
                    }),
            Command(id: ids.removePage, title: "Remove Page", menu: path, contexts: [.page], keywords: ["page", "delete"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return front.documentHandle.pageList.pages.count > 1 ? .enabled : .disabled(Self.onePage)
                    },
                    action: .perform {
                        guard let front = window(), front.documentHandle.pageList.pages.count > 1 else { return }
                        front.removeSelectedPages()
                    }),
            Command(id: ids.goToPage, title: "Go to Page", menu: path, keywords: ["page", "navigate"],
                    validation: { window() == nil ? .disabled(Self.noDocument) : .enabled },
                    action: .perform {
                        guard let front = window() else { return }
                        front.window?.makeFirstResponder(front.statusBar.pageField)
                    }),
        ]
    }

    func fileCommands() -> [Command] {
        let window = window
        let ids = ContextMenuCatalog.ID.self
        let file = StandardCommands.Menu.file
        return [
            Command(id: ids.renameDocument, title: "Rename Document…", menu: MenuPath(file, section: 1), contexts: [.tab], keywords: ["rename", "title"],
                    validation: { [weak self] in
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return self?.libraryName(front.documentHandle.id) == nil ? .disabled(Self.notInLibrary) : .enabled
                    },
                    action: .perform { [weak self] in if let front = window() { self?.showRenameSheet(on: front) } }),
            Command(id: ids.showDocumentInLibrary, title: "Show in Library", menu: MenuPath(file, section: 1), contexts: [.tab], keywords: ["library", "reveal"],
                    action: .perform { [weak self] in self?.showLibrary() }),
        ]
    }

    func editCommands() -> [Command] {
        [
            Command(id: ContextMenuCatalog.ID.editWith, title: "Edit in External Editor", menu: MenuPath(StandardCommands.Menu.edit, section: 1), contexts: [.bitmap],
                    keywords: ["edit", "external", "editor", "image"],
                    validation: { ExternalEditing.shared.selectedImage() == nil ? .disabled(ExternalEditing.noImage) : .enabled },
                    action: .perform { ExternalEditing.shared.editFromPanel() }),
        ]
    }

    func viewCommands() -> [Command] {
        let window = window
        let ids = ContextMenuCatalog.ID.self
        let guides = MenuPath(StandardCommands.Menu.view, StandardCommands.Menu.guides, section: StandardCommands.Section.viewRulers, subsection: 2)
        func guideValidation(_ features: ReachabilityFeatures?) -> CommandValidation {
            guard let front = window() else { return .disabled(Self.noDocument) }
            return features?.contextGuide(front) == nil ? .disabled(Self.noGuide) : .enabled
        }
        return [
            Command(id: ids.lockGuide, title: "Lock Guide", menu: guides, contexts: [.guide], keywords: ["guides", "lock"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        return CommandValidation(isChecked: front.documentHandle.settings.guidesLocked)
                    },
                    action: .perform { window()?.toggleGuidesLocked() }),
            Command(id: ids.releaseGuide, title: "Release Guide", menu: guides, contexts: [.guide], keywords: ["guides", "release", "path"],
                    validation: { [weak self] in guideValidation(self) },
                    action: .perform { [weak self] in
                        guard let front = window(), let hit = self?.contextGuide(front) else { return }
                        front.objectEditing.perform(ReleaseGuides(on: hit.page, hit.guides, layer: front.pickingLayer))
                    }),
            Command(id: ids.deleteGuide, title: "Delete Guide", menu: guides, contexts: [.guide], keywords: ["guides", "delete"],
                    validation: { [weak self] in guideValidation(self) },
                    action: .perform { [weak self] in
                        guard let front = window(), let hit = self?.contextGuide(front) else { return }
                        front.objectEditing.perform(DeleteGuides(on: hit.page, hit.guides))
                    }),
            Command(id: ids.goToCollaboratorPage, title: "Go to <name>'s Page", menu: MenuPath(StandardCommands.Menu.view, "Collaborators", section: StandardCommands.Section.viewVisibility),
                    contexts: [.presence], keywords: ["collaborator", "page", "presence"],
                    validation: {
                        guard let front = window() else { return .disabled(Self.noDocument) }
                        guard let target = CollaborationCommands.followTarget(front), target.page != nil else { return .disabled(Self.noCollaboratorPage) }
                        return CommandValidation(title: "Go to \(target.name)'s Page")
                    },
                    action: .perform {
                        guard let front = window(), let page = CollaborationCommands.followTarget(front)?.page else { return }
                        front.documentHandle.selectPage(id: page.opID)
                        front.showCurrentPage()
                    }),
        ]
    }

    // MARK: Sheets

    /// menu:Object[Name…] and *Note…*: a sheet with the selection's shared name or note; btn:[OK]
    /// writes it to every selected object, one change.
    @discardableResult
    func showNameSheet(_ field: SetNameOrNote.Field, on window: DocumentWindowController) -> NSWindow? {
        let model = ObjectPanelModel(document: window.documentHandle, selection: window.selection.selection, textSession: window.objectEditing.textSession)
        guard let common = model.common else { return nil }
        let isName = field == .name
        let sheet = TextEntrySheetModel(title: isName ? "Name" : "Note", text: (isName ? common.name : common.note) ?? "",
                                        limit: isName ? 256 : 8192, multiline: !isName, allowsEmpty: true)
        return window.presentSheet("object-\(isName ? "name" : "note")-sheet") { close in
            TextEntrySheet(model: sheet, commit: { [weak window] text in
                if let window { Self.write(field, text, on: window) }
                close()
            }, cancel: close)
        }
    }

    /// Writes `text` as the name or note of every object selected in `window`, one change.
    @discardableResult
    static func write(_ field: SetNameOrNote.Field, _ text: String, on window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let model = ObjectPanelModel(document: window.documentHandle, selection: window.selection.selection, textSession: nil)
        return model.perform(field == .name ? model.setName(text) : model.setNote(text))
    }

    /// menu:File[Rename Document…]: the library entry's name; btn:[OK] renames it.
    @discardableResult
    func showRenameSheet(on window: DocumentWindowController) -> NSWindow? {
        let id = window.documentHandle.id
        guard let name = libraryName(id) else { return nil }
        let sheet = TextEntrySheetModel(title: "Rename Document", text: name, limit: 256, multiline: false, allowsEmpty: false)
        return window.presentSheet("rename-document-sheet") { close in
            TextEntrySheet(model: sheet, commit: { [weak self] text in
                self?.rename(id, text)
                close()
            }, cancel: close)
        }
    }

    // MARK: Extensions and panels

    /// *Reverse Direction* and *File Info…* in the Extensions menu and the Extension Operations
    /// toolbar, on the commands above and menu:File[Document Info…].
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        let window = window
        var result: [ExtensionDescriptor] = []
        if var reverse = existing.descriptor(for: "reverseDirection") {
            reverse.validate = {
                guard let front = window() else { return .disabled(Self.noDocument) }
                return Self.reverseCommand(front) == nil ? .disabled(Self.noPathOrConnector) : .enabled
            }
            reverse.run = { _ in
                if let front = window(), let command = Self.reverseCommand(front) { front.objectEditing.perform(command) }
                return nil
            }
            result.append(reverse)
        }
        if var info = existing.descriptor(for: "fileInfo") {
            info.validate = { [weak self] in self?.validation(DocumentInfoFeatures.id) ?? .disabled(Self.noDocument) }
            info.run = { [weak self] _ in
                _ = self?.perform(DocumentInfoFeatures.id)
                return nil
            }
            result.append(info)
        }
        return result
    }

    /// The Select panel (panels.adoc, "The panels"): the Find & Replace panel's body on its own
    /// state, opened on the *Select* tab.
    static func selectPanel(selection: ActiveSelection?) -> PanelDescriptor {
        let state = FindReplaceState()
        state.select(.select)
        return PanelDescriptor(id: "select", title: "Select", icon: "checklist", defaultGroup: PanelCatalog.Group.findSelect, menuOrder: 81, helpSlug: "selecting") {
            FindReplacePanelBody(selection: selection, state: state)
        }
    }
}

/// The Tools panel's Swap, None and Default with objects selected (toolbars.adoc, "Colors
/// section"; applying-color.adoc): they change the selection's fill and stroke, one change each,
/// as a pick in a well's palette does; with nothing selected they change the current colours.
extension ToolWellColoring {
    static let mixedColors = "The selected objects' colors differ"

    var hasSelection: Bool { !workspace.selectedNodes.isEmpty }

    /// The selection's shared colour in `well`, nil when the objects differ.
    func selectionRef(_ well: ActiveWell) -> Wiretuner_Doc_V1_ColorRef? {
        swatches.well(well.target)?.ref
    }

    /// Writes `fill` and `stroke` on every selected object, one change labelled `label`.
    @discardableResult
    func apply(fill: Wiretuner_Doc_V1_ColorRef, stroke: Wiretuner_Doc_V1_ColorRef, label: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = workspace.selectedNodes
        guard !nodes.isEmpty else { return nil }
        return workspace.perform(CommandBatch(label, [ApplyColor(nodes, target: .fill, color: fill), ApplyColor(nodes, target: .stroke, color: stroke)]))
    }

    static func reference(choice: DocumentDefaults.ColorChoice) -> Wiretuner_Doc_V1_ColorRef {
        switch choice {
        case .noColor: ColorResolver.none
        case .color(let ref): ref
        }
    }
}

extension ReachabilityFeatures {
    /// Swap, None and Default: the current colours with nothing selected (as before), the
    /// selection's colours otherwise.
    static func wellCommands(palette: ToolPaletteModel) -> [Command] {
        let ids = ToolPanelCommands.ID.self
        func selected() -> ToolWellColoring? {
            guard !palette.canEditWells, let coloring = palette.coloring, coloring.hasSelection else { return nil }
            return coloring
        }
        let available: @MainActor @Sendable () -> CommandValidation = {
            palette.canEditWells || selected() != nil ? .enabled : .disabled(noDocument)
        }
        return [
            Command(id: ids.swap, title: "Swap Stroke and Fill", key: KeyEquivalent("x", .shift), keywords: ["colors", "wells"],
                    validation: {
                        if palette.canEditWells { return .enabled }
                        guard let coloring = selected() else { return .disabled(noDocument) }
                        return coloring.selectionRef(.fill) == nil || coloring.selectionRef(.stroke) == nil ? .disabled(ToolWellColoring.mixedColors) : .enabled
                    },
                    action: .perform {
                        guard let coloring = selected() else { return palette.swapWells() }
                        guard let fill = coloring.selectionRef(.fill), let stroke = coloring.selectionRef(.stroke) else { return }
                        coloring.apply(fill: stroke, stroke: fill, label: "Swap Stroke and Fill")
                    }),
            Command(id: ids.none, title: "None", key: KeyEquivalent("/"), keywords: ["colors", "no color"], validation: available,
                    action: .perform {
                        guard let coloring = selected() else { return palette.setActiveWellToNone() }
                        _ = coloring.apply(ColorResolver.none, name: "", to: palette.activeWell)
                    }),
            Command(id: ids.restoreDefault, title: "Default Colors", key: KeyEquivalent("d", .shift), keywords: ["colors", "black", "white"],
                    validation: {
                        if palette.canEditWells { return .enabled }
                        return selected() != nil && palette.documentChoices != nil ? .enabled : .disabled(noDocument)
                    },
                    action: .perform {
                        guard let coloring = selected() else { return palette.restoreDefaultWells() }
                        guard let choices = palette.documentChoices else { return }
                        coloring.apply(fill: ToolWellColoring.reference(choice: choices.fill), stroke: ToolWellColoring.reference(choice: choices.stroke), label: "Default Colors")
                    }),
        ]
    }
}

/// The Object panel's symbol instance section (object-panel.adoc, "Properties by kind": "The
/// symbol's name and a *Release Instance* button"): the symbol each selected instance shows, and
/// btn:[Release Instance], one change.
struct InstanceSectionView: View {
    let instances: [OpID]
    let model: ObjectPanelModel

    /// The symbols' names, "Mixed" when the instances show different symbols.
    static func symbolName(_ instances: [OpID], in state: EngineState) -> String {
        let names = Set(instances.compactMap { Symbols.symbol(of: $0, in: state) }.map { state.displayName(of: $0) })
        return names.count == 1 ? names.first! : TextSectionView.mixed
    }

    static func releasing(_ instances: [OpID], _ model: ObjectPanelModel) -> () -> Void {
        { model.perform(ReleaseInstances(instances)) }
    }

    var body: some View {
        Form {
            LabeledContent("Symbol", value: Self.symbolName(instances, in: model.document.state)).accessibilityIdentifier("object.instance.symbol")
            Button("Release Instance", action: Self.releasing(instances, model)).accessibilityIdentifier("object.instance.release")
        }
        .padding(.horizontal)
    }

    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "instance", order: 79, kinds: [.instance]) { model in
            let state = model.document.state
            let instances = model.selection.ids.map(\.opID).filter { state.nodeKind($0) == .instance }
            return instances.isEmpty ? nil : AnyView(InstanceSectionView(instances: instances, model: model))
        })
    }
}

/// A one-field sheet (Name…, Note…, Rename Document…): the text, btn:[OK] and btn:[Cancel].
@MainActor
@Observable
final class TextEntrySheetModel {
    let title: String
    var text: String
    let limit: Int
    let multiline: Bool
    let allowsEmpty: Bool

    init(title: String, text: String, limit: Int, multiline: Bool, allowsEmpty: Bool) {
        self.title = title
        self.text = String(text.prefix(limit))
        self.limit = limit
        self.multiline = multiline
        self.allowsEmpty = allowsEmpty
    }

    /// The text to write: trimmed of surrounding blank lines for a name, kept to the limit; nil
    /// while an empty entry is refused.
    var value: String? {
        let clipped = String(text.prefix(limit))
        let trimmed = multiline ? clipped : clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty && !allowsEmpty ? nil : trimmed
    }
}

struct TextEntrySheet: View {
    @Bindable var model: TextEntrySheetModel
    let commit: @MainActor (String) -> Void
    let cancel: @MainActor () -> Void

    static func committing(_ model: TextEntrySheetModel, _ commit: @escaping @MainActor (String) -> Void) -> () -> Void {
        { if let value = model.value { commit(value) } }
    }

    var body: some View {
        let identifier = "entry-sheet.\(model.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            if model.multiline {
                TextField(model.title, text: $model.text, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("\(identifier).field")
            } else {
                TextField(model.title, text: $model.text).accessibilityIdentifier("\(identifier).field")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.committing(model, commit)).keyboardShortcut(.defaultAction)
                    .disabled(model.value == nil).accessibilityIdentifier("\(identifier).ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

extension AppDelegate {
    /// What the reachability audit wired (rch): the commands, the Text menu's alignment and
    /// leading, the Object panel's Leading row, the Select panel and the extension entries.
    /// Installed before the panel catalog so the Select panel replaces its placeholder.
    func installReachability() {
        let documents = documents!
        let window: @MainActor () -> DocumentWindowController? = { documents.activeWindowController }
        let features = ReachabilityFeatures.instance(for: self, window: window)
        let layout = layout
        let commands = commands
        let library = library
        features.showPanel = { layout.showPanel($0) }
        features.perform = { [weak self] id in self?.menuTarget?.perform(id) ?? commands.perform(id) }
        features.validate = { commands.validate($0) }
        features.showLibrary = { [weak self] in _ = self?.showLibrary() }
        features.libraryName = { library.cache.documents[$0]?.name }
        features.rename = { id, name in Task { await library.rename(id, to: name) } }
        for command in features.commands() + AlignLeadingCommands.commands(window: window) + ReachabilityFeatures.wellCommands(palette: toolPalette) {
            commands.replace(command)
        }
        for descriptor in features.extensionDescriptors(existing: toolbars.extensions) { toolbars.extensions.replace(descriptor) }
        AlignLeadingCommands.register(into: .standard)
        InstanceSectionView.register(into: .standard)
        panels.registerIfAbsent(ReachabilityFeatures.selectPanel(selection: activeSelection))
    }

    /// Each window's guide hook for the context menu.
    func attachReachability(_ window: DocumentWindowController) {
        ReachabilityFeatures.instance(for: self)?.attach(window)
    }
}

extension ReachabilityFeatures {
    /// The key of each app delegate's instance (tests build several delegates).
    nonisolated(unsafe) private static var key: UInt8 = 0

    static func instance(for delegate: AppDelegate) -> ReachabilityFeatures? {
        objc_getAssociatedObject(delegate, &key) as? ReachabilityFeatures
    }

    static func instance(for delegate: AppDelegate, window: @escaping Window) -> ReachabilityFeatures {
        if let existing = instance(for: delegate) { return existing }
        let features = ReachabilityFeatures(window: window)
        objc_setAssociatedObject(delegate, &key, features, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return features
    }
}
