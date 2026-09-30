import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto

/// The Edit and Modify menu glue for OBJ-014, OBJ-015, OBJ-017, OBJ-024 and OBJ-027 (copying.adoc,
/// clipping-paths.adoc, combining-paths.adoc, grouping.adoc): Copy Attributes and Paste Attributes
/// under their own pasteboard type, Copy Special and Paste Special, the interchange formats on every
/// Copy and the richest format on Paste, Paste Contents and Cut Contents, Join and the composite
/// Split, and *Group Transforms as Unit*.
@MainActor
final class EditFeatures {
    enum ID {
        static let copyAttributes: CommandID = "edit.special.copyAttributes"
        static let pasteAttributes: CommandID = "edit.special.pasteAttributes"
        static let copySpecial: CommandID = "edit.special.copySpecial"
        static let pasteSpecial: CommandID = "edit.special.pasteSpecial"
        static let pasteContents: CommandID = "edit.pasteContents"
        static let cutContents: CommandID = "edit.cutContents"
    }

    static let noDocument = "No document is open"
    static let attributesType = NSPasteboard.PasteboardType(AttributePayload.pasteboardType)
    static let copySpecialSheet = "copy-special-sheet"
    static let pasteSpecialSheet = "paste-special-sheet"

    let preferences: PreferenceStore
    var window: @MainActor () -> DocumentWindowController? = { nil }
    /// The blobs a copy's scene reads.
    var blobs = BlobPlacement()
    /// Where pasted foreign formats go (the import path's blob store); replaceable in tests.
    var storeBlobs: @MainActor (ImportedScene, DocumentHandle) async throws -> Void = { _, _ in }
    /// Presents a sheet on a window (replaceable in tests).
    var presentSheet: @MainActor (NSWindow, NSWindow?) -> Void = { sheet, parent in
        if let parent { parent.beginSheet(sheet) } else { sheet.makeKeyAndOrderFront(nil) }
    }
    private(set) var sheets: [String: NSWindow] = [:]

    init(preferences: PreferenceStore) {
        self.preferences = preferences
    }

    var settings: ClipboardSettings { ClipboardPreferences.settings(preferences) }

    // MARK: Windows

    /// The window's pasteboard becomes a `FormatsPasteboard` over the same `NSPasteboard`, so each
    /// Copy offers the interchange formats.
    func attach(_ window: DocumentWindowController) {
        SmartGuideLink.shared.register(window.documentHandle.id) { [weak window] start in window?.smartGuideEngine(start: start) }
        guard !(window.objectEditing.pasteboard is FormatsPasteboard) else { return }
        guard let system = window.objectEditing.pasteboard as? SystemObjectPasteboard else { return }
        let formats = FormatsPasteboard(system.pasteboard)
        formats.makeWriter = { [unowned self, weak window] payload in
            window.map { ClipboardWriter.copy(of: $0.objectEditing.selectedNodes, in: $0, payload: payload, settings: settings, blobs: blobs) }
        }
        window.objectEditing.pasteboard = formats
    }

    /// The window's `NSPasteboard`.
    static func pasteboard(of window: DocumentWindowController) -> NSPasteboard {
        (window.objectEditing.pasteboard as? FormatsPasteboard)?.pasteboard ?? (window.objectEditing.pasteboard as? SystemObjectPasteboard)?.pasteboard ?? .general
    }

    // MARK: Attributes

    /// menu:Edit[Special > Copy Attributes]: the first selected object's look.
    @discardableResult
    func copyAttributes() -> Bool {
        guard let window = window(), let node = window.objectEditing.selectedNodes.first,
              let payload = AttributePayload(copying: node, from: window.documentHandle.state) else { return false }
        let pasteboard = Self.pasteboard(of: window)
        pasteboard.clearContents()
        pasteboard.setData(Data(payload.clipboard(sourceDocument: window.documentHandle.id).encoded()), forType: Self.attributesType)
        return true
    }

    /// The attributes on the window's pasteboard.
    func copiedAttributes(_ window: DocumentWindowController) -> AttributePayload? {
        Self.pasteboard(of: window).data(forType: Self.attributesType)
            .flatMap { ClipboardPayload(decoding: Array($0)) }.flatMap(AttributePayload.init)
    }

    /// menu:Edit[Special > Paste Attributes]: every selected object's stack replaced.
    @discardableResult
    func pasteAttributes() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window(), window.objectEditing.hasSelection, let payload = copiedAttributes(window) else { return nil }
        let nodes = window.objectEditing.selectedNodes
        return window.objectEditing.perform(PasteAttributes(payload, to: nodes, in: window.documentHandle.state))
    }

    // MARK: Clip groups

    /// The clip group `node` belongs to as a target: itself, or the group it is the clip path of.
    static func clipGroup(of node: OpID, in state: EngineState) -> OpID? {
        if ClipGroups.isClipGroup(node, in: state) { return node }
        if let parent = Objects.parent(of: node, in: state), ClipGroups.clipPath(of: parent, in: state) == node { return parent }
        return nil
    }

    /// The one selected object Paste Contents and Cut Contents act on.
    static func single(_ window: DocumentWindowController) -> OpID? {
        let nodes = window.objectEditing.selectedNodes
        return nodes.count == 1 ? nodes[0] : nil
    }

    func canPasteContents(_ window: DocumentWindowController) -> Bool {
        guard let node = Self.single(window), window.objectEditing.canPaste else { return false }
        return PasteContents.accepts(node, in: window.documentHandle.state)
    }

    /// menu:Edit[Paste Contents] (kbd:[Cmd+Shift+V]).
    @discardableResult
    func pasteContents() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window(), canPasteContents(window), let node = Self.single(window),
              let payload = window.objectEditing.pasteboard.read().flatMap({ ClipboardPayload(decoding: $0) }) else { return nil }
        return window.objectEditing.perform(PasteContents(payload, into: node))
    }

    func canCutContents(_ window: DocumentWindowController) -> Bool {
        guard let node = Self.single(window) else { return false }
        return Self.clipGroup(of: node, in: window.documentHandle.state) != nil
    }

    /// menu:Edit[Cut Contents] (kbd:[Cmd+Shift+X]): the contents go to the clipboard and the path
    /// becomes an ordinary path again.
    @discardableResult
    func cutContents() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window(), let node = Self.single(window), let group = Self.clipGroup(of: node, in: window.documentHandle.state),
              let payload = CutContents.payload(of: group, in: window.documentHandle.state, document: window.documentHandle.id) else { return nil }
        window.objectEditing.pasteboard.write(payload.encoded())
        return window.objectEditing.perform(CutContents(group))
    }

    // MARK: Join and Split

    /// The selection's joinable inputs.
    static func joinable(_ window: DocumentWindowController) -> [OpID] {
        JoinObjects.inputs(window.objectEditing.selectedNodes, in: window.documentHandle.state)
    }

    /// menu:Modify[Join] (kbd:[Cmd+J]): with *Join non-touching paths*, ends within the *Snap
    /// distance* join.
    @discardableResult
    func join() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window() else { return nil }
        let nodes = Self.joinable(window)
        guard nodes.count >= 2 else { return nil }
        let reach = preferences[PreferenceCatalog.Object.joinNonTouching]
            ? Double(preferences[PreferenceCatalog.General.snapDistance]) / max(window.canvas.viewport.zoom, 1e-9) : nil
        return window.objectEditing.perform(JoinObjects(nodes, snapDistance: reach))
    }

    /// The selected composite paths Split takes apart.
    static func composites(_ window: DocumentWindowController) -> [OpID] {
        let state = window.documentHandle.state
        return window.objectEditing.selectedNodes.filter { SplitObjects.splits($0, in: state) }
    }

    /// menu:Modify[Split] (kbd:[Cmd+Shift+J]) over the Split it wraps: selected points split
    /// there (the wrapped Split's), otherwise composite paths come apart.
    func split(previous: Command?) -> Command {
        let fallback = previous?.validation ?? { .disabled(PathEditingFeatures.noPoints) }
        let previousAction = previous?.action
        return Command(id: ContextMenuCatalog.ID.split, title: "Split", key: KeyEquivalent("j", [.command, .shift]),
                       menu: MenuPath(ContextMenuCatalog.Menu.modify, section: 3), contexts: ContextMenuCatalog.objectContexts,
                       keywords: ["cut", "points", "blend", "path", "composite"],
                       validation: { [weak self] in
                           let wrapped = fallback()
                           guard !wrapped.isEnabled, let window = self?.window(), !Self.composites(window).isEmpty else { return wrapped }
                           return .enabled
                       },
                       action: .perform { [weak self] in
                           if fallback().isEnabled {
                               if case .perform(let run)? = previousAction { run() }
                           } else if let window = self?.window() {
                               let composites = Self.composites(window)
                               if !composites.isEmpty { window.objectEditing.perform(SplitObjects(composites)) }
                           }
                       })
    }

    // MARK: Transform as unit

    /// The selected groups.
    static func groups(_ window: DocumentWindowController) -> [OpID] {
        let state = window.documentHandle.state
        return window.objectEditing.selectedNodes.filter { state.nodeKind($0) == .group }
    }

    /// menu:Modify[Group Transforms as Unit]: on for every selected group unless all are on.
    @discardableResult
    func toggleTransformAsUnit() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window() else { return nil }
        let groups = Self.groups(window)
        guard !groups.isEmpty else { return nil }
        let state = window.documentHandle.state
        let allOn = groups.allSatisfy { GroupInspector.transformsAsUnit($0, in: state) }
        return window.objectEditing.perform(SetTransformAsUnit(groups, asUnit: !allOn))
    }

    // MARK: Copy Special and Paste Special

    /// menu:Edit[Special > Copy Special…] in `format`: that format alone on the pasteboard.
    @discardableResult
    func copy(as format: ClipboardFormat) -> Bool {
        guard let window = window(), window.objectEditing.hasSelection else { return false }
        let nodes = window.objectEditing.selectedNodes
        let payload = ClipboardPayload(copying: nodes, from: window.documentHandle.state, document: window.documentHandle.id).encoded()
        let writer = ClipboardWriter.copy(of: nodes, in: window, payload: payload, settings: settings.only(format), blobs: blobs)
        let formats = (window.objectEditing.pasteboard as? FormatsPasteboard) ?? FormatsPasteboard(Self.pasteboard(of: window))
        formats.write(writer)
        return true
    }

    /// The formats Paste Special offers: those on the pasteboard now.
    func pasteFormats(_ window: DocumentWindowController) -> [ClipboardFormat] {
        ClipboardReader.formats(in: Self.types(of: Self.pasteboard(of: window)))
    }

    /// The type names on `pasteboard`.
    static func types(of pasteboard: NSPasteboard) -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    /// Paste in `format`: the native payload through Paste, any other through the import path as
    /// editable artwork, a bitmap or a text block, centred in the view.
    @discardableResult
    func paste(as format: ClipboardFormat) async -> Bool {
        guard let window = window() else { return false }
        if format == .native {
            guard let task = window.objectEditing.paste() else { return false }
            await task.value
            return true
        }
        let pasteboard = Self.pasteboard(of: window)
        let types = Self.types(of: pasteboard)
        guard let scene = try? ClipboardReader.read(format, types: types, data: { pasteboard.data(forType: NSPasteboard.PasteboardType($0)) }) else {
            window.statusBar.show(message: "The clipboard's \(format.displayName) could not be pasted.")
            return false
        }
        return await place(scene, on: window)
    }

    /// Whether Paste should read a foreign format itself: the richest format on the pasteboard is
    /// one the import path does not paste (SVG, rich text, plain text).
    func takesPaste(from pasteboard: NSPasteboard) -> Bool {
        guard let format = ClipboardReader.richest(in: Self.types(of: pasteboard)) else { return false }
        return [.svg, .rtf, .plainText].contains(format)
    }

    /// Paste of the richest foreign format on `window`'s pasteboard.
    @discardableResult
    func pasteRichest(on window: DocumentWindowController) async -> Bool {
        let pasteboard = Self.pasteboard(of: window)
        let types = Self.types(of: pasteboard)
        // Rich and plain text become a text block holding it (TYPE-009).
        if let format = ClipboardReader.richest(in: types), [.rtf, .plainText].contains(format) {
            return await pasteTextBlock(on: window, from: pasteboard)
        }
        guard let scene = try? ClipboardReader.readRichest(types: types, data: { pasteboard.data(forType: NSPasteboard.PasteboardType($0)) }) else { return false }
        return await place(scene, on: window)
    }

    /// Stores `scene`'s blobs and places it centred in the view, selected (one change).
    func place(_ scene: ImportedScene, on window: DocumentWindowController) async -> Bool {
        let document = window.documentHandle
        do {
            try await storeBlobs(scene, document)
        } catch {
            window.statusBar.show(message: "The pasted artwork could not be stored: \(error.localizedDescription)")
            return false
        }
        let center = window.objectEditing.visibleCenter() ?? Point(x: 0, y: 0)
        let origin = ImportController.centred(scene.bounds, in: center, offset: 0)
        let command = PlaceImportedScene(scene, placement: .at(origin), layer: window.objectEditing.activeLayer, link: nil, poster: nil)
        guard let change = await window.objectEditing.perform(command).value, let root = PlaceImportedScene.placedRoot(of: change, in: document.state) else {
            return false
        }
        window.selection.model.set(Selection([SelectionID(root)]))
        return true
    }

    @discardableResult
    func presentCopySpecial() -> FormatChoiceModel? {
        guard let window = window(), window.objectEditing.hasSelection else { return nil }
        let model = FormatChoiceModel(title: "Copy Special", formats: ClipboardFormat.richestFirst) { [weak self] format in
            self?.dismiss(Self.copySpecialSheet)
            if let format { self?.copy(as: format) }
        }
        present(FormatChoiceSheet(model: model), identifier: Self.copySpecialSheet, title: "Copy Special", on: window)
        return model
    }

    @discardableResult
    func presentPasteSpecial() -> FormatChoiceModel? {
        guard let window = window() else { return nil }
        let formats = pasteFormats(window)
        guard !formats.isEmpty else { return nil }
        let model = FormatChoiceModel(title: "Paste Special", formats: formats) { [weak self] format in
            self?.dismiss(Self.pasteSpecialSheet)
            if let format { Task { await self?.paste(as: format) } }
        }
        present(FormatChoiceSheet(model: model), identifier: Self.pasteSpecialSheet, title: "Paste Special", on: window)
        return model
    }

    func present<Content: View>(_ content: Content, identifier: String, title: String, on window: DocumentWindowController) {
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content))
        sheet.identifier = NSUserInterfaceItemIdentifier(identifier)
        sheet.title = title
        sheet.isReleasedWhenClosed = false
        sheet.animationBehavior = .none
        sheets[identifier] = sheet
        presentSheet(sheet, window.window)
    }

    func dismiss(_ identifier: String) {
        guard let sheet = sheets.removeValue(forKey: identifier) else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    // MARK: Commands

    func commands(previousSplit: Command?) -> [Command] {
        let edit = StandardCommands.Menu.edit, modify = ContextMenuCatalog.Menu.modify
        func validate(_ condition: @escaping @MainActor (DocumentWindowController) -> Bool, reason: String) -> @MainActor @Sendable () -> CommandValidation {
            { [weak self] in
                guard let window = self?.window() else { return .disabled(Self.noDocument) }
                return condition(window) ? .enabled : .disabled(reason)
            }
        }
        return [
            Command(id: ID.copyAttributes, title: "Copy Attributes", key: KeyEquivalent("c", [.command, .option]), menu: MenuPath(edit, "Special", section: 1),
                    keywords: ["style", "eyedropper", "look"],
                    validation: validate({ $0.objectEditing.hasSelection }, reason: ObjectMenuCommands.noSelection),
                    action: .perform { [weak self] in self?.copyAttributes() }),
            Command(id: ID.pasteAttributes, title: "Paste Attributes", menu: MenuPath(edit, "Special", section: 1), keywords: ["style", "look"],
                    validation: validate({ [weak self] in $0.objectEditing.hasSelection && self?.copiedAttributes($0) != nil },
                                         reason: "Copy attributes and select objects first"),
                    action: .perform { [weak self] in self?.pasteAttributes() }),
            Command(id: ID.copySpecial, title: "Copy Special…", menu: MenuPath(edit, "Special", section: 1), keywords: ["clipboard", "format", "pdf", "svg"],
                    validation: validate({ $0.objectEditing.hasSelection }, reason: ObjectMenuCommands.noSelection),
                    action: .perform { [weak self] in self?.presentCopySpecial() }),
            Command(id: ID.pasteSpecial, title: "Paste Special…", menu: MenuPath(edit, "Special", section: 1), keywords: ["clipboard", "format", "pdf", "svg"],
                    validation: validate({ [unowned self] in !pasteFormats($0).isEmpty }, reason: "The clipboard is empty"),
                    action: .perform { [weak self] in self?.presentPasteSpecial() }),
            Command(id: ID.pasteContents, title: "Paste Contents", key: KeyEquivalent("v", [.command, .shift]), menu: MenuPath(edit, section: 1),
                    contexts: [.path, .clip], keywords: ["clipping path", "mask", "paste inside"],
                    validation: validate({ [unowned self] in canPasteContents($0) }, reason: "Copy objects and select one closed path or clipping path"),
                    action: .perform { [weak self] in self?.pasteContents() }),
            Command(id: ID.cutContents, title: "Cut Contents", key: KeyEquivalent("x", [.command, .shift]), menu: MenuPath(edit, section: 1),
                    contexts: [.clip], keywords: ["clipping path", "mask", "release"],
                    validation: validate({ [unowned self] in canCutContents($0) }, reason: "Select a clipping path"),
                    action: .perform { [weak self] in self?.cutContents() }),
            Command(id: ContextMenuCatalog.ID.join, title: "Join", key: KeyEquivalent("j", .command), menu: MenuPath(modify, section: 3),
                    contexts: ContextMenuCatalog.objectContexts, keywords: ["composite", "combine", "connect"],
                    validation: validate({ Self.joinable($0).count >= 2 }, reason: "Select two or more paths"),
                    action: .perform { [weak self] in self?.join() }),
            split(previous: previousSplit),
            Command(id: ContextMenuCatalog.ID.groupTransformsAsUnit, title: "Group Transforms as Unit", menu: MenuPath(modify, section: 0),
                    contexts: [.group], keywords: ["stroke", "scale", "group"],
                    validation: { [weak self] in
                        guard let window = self?.window() else { return .disabled(Self.noDocument) }
                        let groups = Self.groups(window)
                        guard !groups.isEmpty else { return .disabled("Select a group") }
                        let state = window.documentHandle.state
                        return .checked(groups.allSatisfy { GroupInspector.transformsAsUnit($0, in: state) })
                    },
                    action: .perform { [weak self] in self?.toggleTransformAsUnit() }),
        ]
    }

    func install(commands registry: CommandRegistry, inspector: InspectorRegistry = .standard, window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
        for command in commands(previousSplit: registry.command(ContextMenuCatalog.ID.split)) { registry.replace(command) }
        inspector.register(GroupSection.section(select: subselect, rows: GroupSectionModel.Rows(
            selected: { [weak self] in self?.window()?.selection.model.contentsRow },
            select: { [weak self] group in self?.selectContentsRow(group) })))
        let preferences = preferences
        SmartGuideLink.shared.color = {
            let c = preferences[PreferenceCatalog.Colors.smartGuideColor].components
            return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
    }

    /// The *Contents* row's subselection in the front window.
    func subselect(_ nodes: [OpID]) {
        window()?.selection.model.set(Selection(nodes.map { SelectionID($0) }))
    }

    /// Selects the *Contents* row of `group` in the front window (nil deselects it); the canvas
    /// redraws the contents handle.
    func selectContentsRow(_ group: OpID?) {
        guard let window = window() else { return }
        window.selection.model.selectContentsRow(group)
        window.canvas.setNeedsOverlayDisplay()
    }
}

/// The Copy Special and Paste Special sheets' state: one format chosen from a list.
@MainActor
@Observable
final class FormatChoiceModel {
    let title: String
    let formats: [ClipboardFormat]
    var choice: ClipboardFormat
    @ObservationIgnored let finish: @MainActor (ClipboardFormat?) -> Void

    init(title: String, formats: [ClipboardFormat], finish: @escaping @MainActor (ClipboardFormat?) -> Void) {
        self.title = title
        self.formats = formats
        choice = formats.first ?? .native
        self.finish = finish
    }

    func confirm() { finish(choice) }
    func cancel() { finish(nil) }
}

struct FormatChoiceSheet: View {
    @Bindable var model: FormatChoiceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: $model.choice) {
                ForEach(model.formats, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("formatChoice.format")
            HStack {
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: model.confirm).keyboardShortcut(.defaultAction).accessibilityIdentifier("formatChoice.ok")
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

extension AppDelegate {
    /// The Edit and Modify menu items of the object commands and the clipboard formats.
    func installEditing() {
        let documents = documents!
        let imports = imports
        editMenu.blobs = imports.blobs
        editMenu.storeBlobs = { scene, document in _ = try await imports.storeBlobs(of: scene, for: document) }
        editMenu.install(commands: commands) { documents.activeWindowController }
    }
}
