import AppKit
import WTCRDT
import WTModel
import WTProto

/// menu:Edit[Select > Similar] (selecting.adoc, "Select Similar"; OBJ-042's app half): *Fill*,
/// *Stroke* and *Fill and Stroke* -- and *Shape* when a shape classifier is installed (IMG-030) --
/// select every object on the active page like the one selected object (`SelectSimilar.run`),
/// with kbd:[Shift] held adding to the selection, and the status bar says how many ("3 objects
/// selected").  Disabled with no or several objects selected.  Nothing is written.
@MainActor
final class SelectSimilarCommands {
    static let submenu = "Similar"
    static let needsOne = "Select one object"

    static func id(_ attribute: SelectSimilar.Attribute) -> CommandID { CommandID("edit.select.similar.\(attribute.rawValue)") }

    let window: @MainActor () -> DocumentWindowController?
    /// The *Shape* item's classifier (IMG-030); nil leaves the item out.
    var classifier: (any ShapeClassifying)?
    /// Whether kbd:[Shift] is held as a command runs; replaceable in tests.
    var shiftDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.shift) }

    init(window: @escaping @MainActor () -> DocumentWindowController?) {
        self.window = window
    }

    /// The page the command searches: the active page, or (nil) the whole document when it has
    /// no pages.
    static func page(of document: DocumentHandle) -> OpID? {
        document.pageList.isSynthesized ? nil : document.activePage.id
    }

    /// Runs `attribute` in `window`: the new selection is set and the count shown; nil (nothing
    /// changes) when the command is disabled.
    @discardableResult
    func run(_ attribute: SelectSimilar.Attribute, in window: DocumentWindowController, adding: Bool) -> SelectSimilar.Outcome? {
        let document = window.documentHandle
        guard let outcome = SelectSimilar.run(attribute, selection: window.selection.model.ids.map(\.opID), page: Self.page(of: document),
                                              adding: adding, classifier: classifier, in: document.state) else { return nil }
        window.selection.model.set(Selection(outcome.selection.map { SelectionID($0) }))
        window.statusBar.show(message: outcome.status)
        return outcome
    }

    func commands() -> [Command] {
        let window = self.window
        let path = MenuPath(StandardCommands.Menu.edit, SelectionCommands.submenu, Self.submenu, section: 1, subsection: 2)
        return SelectSimilar.items(classifier: classifier).map { attribute in
            Command(
                id: Self.id(attribute), title: attribute.title, menu: path, keywords: ["select similar", "same", attribute.title.lowercased()],
                validation: {
                    guard let controller = window() else { return .disabled(ViewCommands.noDocument) }
                    let state = controller.documentHandle.state
                    return SelectSimilar.sample(controller.selection.model.ids.map(\.opID), in: state) == nil ? .disabled(Self.needsOne) : .enabled
                },
                action: .perform { [weak self] in
                    guard let self, let controller = window() else { return }
                    self.run(attribute, in: controller, adding: self.shiftDown())
                }
            )
        }
    }

    func install(commands registry: CommandRegistry) {
        for command in commands() { registry.replace(command) }
    }
}

/// menu:Modify[Combine] and the Path Operations toolbar's *Union*, *Divide*, *Intersect*,
/// *Punch* and *Crop* (combining-paths.adoc; OBJ-025's app half) on `CombineCommand`: each builds
/// its result from the selected paths in one change and consumes them unless this use keeps them --
/// *Path operations consume original paths* inverted by kbd:[Shift], and the item's title then
/// reads "Union (keep originals)".  Disabled with fewer than two usable paths (or an open one,
/// except for Divide).
@MainActor
final class CombineCommands {
    typealias Target = ObjectMenuCommands.Target

    static let needsClosed = "Select two or more closed paths"
    static let needsTwo = "Select two or more paths"

    static let ids: [CombineCommand.Operation: CommandID] = [
        .union: ContextMenuCatalog.ID.union, .divide: ContextMenuCatalog.ID.divide, .intersect: ContextMenuCatalog.ID.intersect,
        .punch: ContextMenuCatalog.ID.punch, .crop: ContextMenuCatalog.ID.crop,
    ]

    let target: Target
    let store: PreferenceStore
    /// Whether kbd:[Shift] is held; replaceable in tests.
    var shiftDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.shift) }

    init(target: @escaping Target, store: PreferenceStore) {
        self.target = target
        self.store = store
    }

    /// Whether this use keeps the originals.
    var keepsOriginals: Bool {
        CombineCommand.keepsOriginals(consumePreference: store[PreferenceCatalog.Object.pathOperationsConsume], shift: shiftDown())
    }

    static func nodes(_ editing: ObjectEditing) -> [OpID] {
        editing.selection.selection.ids.map(\.opID)
    }

    /// The command's state for `operation` now: enabled or why not, with this use's title.
    func validation(_ operation: CombineCommand.Operation) -> CommandValidation {
        let title = CombineCommand.title(operation, keepOriginals: keepsOriginals)
        guard let editing = target() else { return CommandValidation(isEnabled: false, reason: ViewCommands.noDocument, title: title) }
        guard CombineCommand.canPerform(operation, Self.nodes(editing), in: editing.document.state) else {
            return CommandValidation(isEnabled: false, reason: operation.needsClosedPaths ? Self.needsClosed : Self.needsTwo, title: title)
        }
        return CommandValidation(title: title)
    }

    /// Performs `operation` on the selection; nil when it cannot.
    @discardableResult
    func perform(_ operation: CombineCommand.Operation) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let editing = target() else { return nil }
        let nodes = Self.nodes(editing)
        guard CombineCommand.canPerform(operation, nodes, in: editing.document.state) else { return nil }
        let task = editing.perform(CombineCommand(operation, nodes, keepOriginals: keepsOriginals))
        let model = editing.selection.model
        Task { @MainActor in
            // The results are selected.
            if let created = await task.value?.createdRoots, !created.isEmpty { model.set(Selection(created.map { SelectionID($0) })) }
        }
        return task
    }

    func commands() -> [Command] {
        CombineCommand.Operation.allCases.map { operation in
            Command(id: Self.ids[operation]!, title: operation.title, menu: MenuPath(ContextMenuCatalog.Menu.modify, "Combine", section: 3),
                    keywords: ["combine", "boolean", "pathfinder", operation.title.lowercased()],
                    validation: { [self] in validation(operation) },
                    action: .perform { [self] in perform(operation) })
        }
    }

    /// The Path Operations toolbar's buttons for the five operations.
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        CombineCommand.Operation.allCases.compactMap { operation in
            guard var descriptor = existing.descriptor(for: operation.rawValue) else { return nil }
            descriptor.validate = { [self] in validation(operation) }
            descriptor.run = { [self] _ in
                perform(operation)
                return nil
            }
            return descriptor
        }
    }

    func install(commands registry: CommandRegistry, extensions: ExtensionRegistry) {
        for var command in commands() {
            // The context menus' placement stays the catalog's.
            command.contexts = registry.command(command.id)?.contexts ?? []
            registry.replace(command)
        }
        for descriptor in extensionDescriptors(existing: extensions) { extensions.replace(descriptor) }
    }
}
