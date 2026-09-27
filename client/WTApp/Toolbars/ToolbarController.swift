import Foundation
import Observation

/// What a toolbar drag carries: the command and where it came from — a toolbar, or the
/// Customize Toolbars window's list (`source == nil`).  On the pasteboard as a string,
/// `wt.toolbar:<source or ->:<command>`.
struct ToolbarDragPayload: Equatable, Sendable {
    static let prefix = "wt.toolbar"

    var command: CommandID
    var source: ToolbarID?

    var string: String { "\(Self.prefix):\(source?.rawValue ?? "-"):\(command.rawValue)" }

    /// What a SwiftUI drag source hands AppKit: the string on the pasteboard.
    func itemProvider() -> NSItemProvider {
        NSItemProvider(object: string as NSString)
    }

    init(command: CommandID, source: ToolbarID?) {
        self.command = command
        self.source = source
    }

    init?(string: String) {
        let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == Self.prefix, !parts[2].isEmpty else { return nil }
        guard parts[1] == "-" || ToolbarID(rawValue: parts[1]) != nil else { return nil }
        command = CommandID(parts[2])
        source = ToolbarID(rawValue: parts[1])
    }
}

/// The Info toolbar's readout: the key window's `ToolManager.info`.
@MainActor
@Observable
final class InfoToolbarModel {
    var info = ToolInfo()
    /// The key window's document: positions read from its active page's zero point in its units
    /// (rulers.adoc, "Coordinates in the Info bar"); nil shows pasteboard points.
    @ObservationIgnored weak var document: DocumentHandle?

    init() {}
}

/// The dockable toolbars and the Tools panel's extra buttons (BASIC-011, BASIC-029): which
/// buttons each shows, whether it is shown (through the panel layout, where it is a one-panel
/// group), menu:View[Toolbars], the customization edits and their persistence.  AppKit-free,
/// so every rule is tested without a window; `ToolbarView` renders it.
@MainActor
final class ToolbarController {
    struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    let commands: CommandRegistry
    let layout: PanelLayoutController
    let extensions: ExtensionRegistry
    let tools: ToolRegistry
    let store: ToolbarStore?
    let info = InfoToolbarModel()

    /// Runs a button's command as its menu item would; returns whether it ran.
    var perform: @MainActor (CommandID) -> Bool = { _ in false }
    /// The commands drawn as their own control rather than a button, with the control's maker.
    var controls: [CommandID: @MainActor () -> any ToolbarControl] = [:] {
        didSet { notify() }
    }
    /// A button clicked while customizing selects its command in the Customize window.
    var onSelectCommand: (@MainActor (CommandID) -> Void)?

    private(set) var contents: ToolbarContents
    /// *Show tooltips* (Panels preferences).
    var showsTooltips = true {
        didSet { if showsTooltips != oldValue { notify() } }
    }
    /// While the Customize Toolbars window is open buttons drag freely and clicks select.
    private(set) var isCustomizing = false
    /// The command selected in the Customize window: its buttons are highlighted.
    var highlighted: CommandID? {
        didSet { if highlighted != oldValue { notify() } }
    }
    private var observers: [UUID: @MainActor () -> Void] = [:]
    private(set) var lastSaveError: (any Error)?

    init(commands: CommandRegistry, layout: PanelLayoutController, extensions: ExtensionRegistry, tools: ToolRegistry, store: ToolbarStore? = nil) {
        self.commands = commands
        self.layout = layout
        self.extensions = extensions
        self.tools = tools
        self.store = store
        contents = store?.load() ?? ToolbarContents()
    }

    // MARK: Observation

    /// Calls `handler` after the buttons, the tooltips setting or the highlight change.
    @discardableResult
    func observe(_ handler: @escaping @MainActor () -> Void) -> ObservationToken {
        let token = ObservationToken(id: UUID())
        observers[token.id] = handler
        return token
    }

    func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
    }

    /// Tells every toolbar to redraw (the disabled extensions changed, a command registered).
    func notify() {
        for observer in observers.values { observer() }
    }

    // MARK: Buttons

    func defaultItems(_ toolbar: ToolbarID) -> [CommandID] {
        ToolbarCatalog.defaultItems(toolbar, extensions: extensions)
    }

    /// The buttons `toolbar` shows: its items, minus turned-off extensions and unknown commands.
    func items(_ toolbar: ToolbarID) -> [CommandID] {
        let hidden = extensions.hiddenCommands
        return contents.items(toolbar, defaults: defaultItems(toolbar)).filter { !hidden.contains($0) && commands.contains($0) }
    }

    /// The toolbars showing `command` (the Customize window highlights them).
    func toolbars(showing command: CommandID) -> [ToolbarID] {
        ToolbarID.allCases.filter { items($0).contains(command) }
    }

    func title(of command: CommandID) -> String {
        commands.command(command)?.title ?? command.rawValue
    }

    /// The button's SF Symbol: the tool's, the extension's, the catalog's; nil draws the title.
    func symbol(for command: CommandID) -> String? {
        if let symbol = ToolbarCatalog.symbols[command] { return symbol }
        if let descriptor = extensions.descriptor(forCommand: command) { return descriptor.symbolName }
        return tools.descriptors.first { $0.commandID == command }?.symbolName
    }

    /// "Union", "Pen (P)": the tooltip, or nil while *Show tooltips* is off.
    func tooltip(for command: CommandID) -> String? {
        guard showsTooltips else { return nil }
        let title = extensions.descriptor(forCommand: command)?.shortTitle ?? title(of: command)
        let key = commands.command(command)?.defaultKey
        return key.map { "\(title) (\($0.displayString))" } ?? title
    }

    func validation(of command: CommandID) -> CommandValidation {
        commands.validate(command) ?? .disabled("Unknown command")
    }

    /// A click on a button: selects its command while customizing, else runs it.  A tool
    /// extension used from the toolbar ends Repeat's run (tools are not repeated).
    @discardableResult
    func press(_ command: CommandID) -> Bool {
        if isCustomizing {
            highlighted = command
            onSelectCommand?(command)
            return false
        }
        if case .tool? = extensions.descriptor(forCommand: command)?.kind { extensions.noteToolUsed() }
        return perform(command)
    }

    /// A kbd:[Cmd]-click (a press with Command held that did not become a drag): an extension
    /// operation runs with its previous settings, skipping its sheet (FX-030); anything else is an
    /// ordinary press.
    @discardableResult
    func commandPress(_ command: CommandID) -> Bool {
        guard !isCustomizing, let descriptor = extensions.descriptor(forCommand: command), descriptor.isOperation else { return press(command) }
        return extensions.performWithPreviousSettings(descriptor.id)
    }

    // MARK: Showing and hiding

    func isVisible(_ toolbar: ToolbarID) -> Bool { layout.isVisible(toolbar.panelID) }

    func show(_ toolbar: ToolbarID) {
        layout.showPanel(toolbar.panelID)
    }

    /// Takes the toolbar out of the layout; it stays closed until shown again.
    func hide(_ toolbar: ToolbarID) {
        let panel = toolbar.panelID
        layout.update { layout in
            layout.removePanel(panel)
            layout.closedPanels.insert(panel)
        }
    }

    /// menu:Window[Toolbars > <name>].
    func toggle(_ toolbar: ToolbarID) {
        if isVisible(toolbar) { hide(toolbar) } else { show(toolbar) }
    }

    /// Whether menu:View[Toolbars] hid the toolbars (its check mark is off then).
    var areHiddenByViewMenu: Bool { !contents.hiddenByViewMenu.isEmpty }

    /// menu:View[Toolbars]: hides every visible toolbar, or brings back the set it hid.
    func toggleAll() {
        if areHiddenByViewMenu {
            let hidden = contents.hiddenByViewMenu
            change { $0.hiddenByViewMenu = [] }
            for toolbar in hidden { show(toolbar) }
        } else {
            let visible = ToolbarID.allCases.filter(isVisible)
            guard !visible.isEmpty else { return }
            for toolbar in visible { hide(toolbar) }
            change { $0.hiddenByViewMenu = visible }
        }
    }

    // MARK: Customizing

    func setCustomizing(_ customizing: Bool) {
        guard customizing != isCustomizing else { return }
        isCustomizing = customizing
        if !customizing { highlighted = nil }
        notify()
    }

    /// Whether a drag may start on a button: never on a disabled one, and only while
    /// customizing or with Command held.
    func canDrag(_ command: CommandID, modifiers: KeyModifiers) -> Bool {
        validation(of: command).isEnabled && (isCustomizing || modifiers.contains(.command))
    }

    func add(_ command: CommandID, to toolbar: ToolbarID, at index: Int? = nil) {
        change { $0.insert(command, into: toolbar, at: index, defaults: defaultItems(toolbar)) }
    }

    func remove(_ command: CommandID, from toolbar: ToolbarID) {
        change { $0.remove(command, from: toolbar, defaults: defaultItems(toolbar)) }
    }

    /// Moves a button to `index` of `target`, within one toolbar or between two.
    func move(_ command: CommandID, from source: ToolbarID, to target: ToolbarID, at index: Int?) {
        change { contents in
            if source != target { contents.remove(command, from: source, defaults: defaultItems(source)) }
            contents.insert(command, into: target, at: index, defaults: defaultItems(target))
        }
    }

    /// A drop on `target` at `index`: from the Customize window it adds the command; from a
    /// toolbar with Option (Cmd+Option-drag) it puts a copy there; otherwise it moves the
    /// button.  Returns whether the drop was taken.
    @discardableResult
    func drop(_ payload: ToolbarDragPayload, on target: ToolbarID, at index: Int?, modifiers: KeyModifiers) -> Bool {
        guard commands.contains(payload.command) else { return false }
        if let source = payload.source, !modifiers.contains(.option) {
            move(payload.command, from: source, to: target, at: index)
        } else {
            add(payload.command, to: target, at: index)
        }
        return true
    }

    /// A button drag ended; `accepted` is false when it was dropped where nothing took it —
    /// dragged off its toolbar, which removes the button.
    func dragEnded(_ payload: ToolbarDragPayload, accepted: Bool) {
        guard !accepted, let source = payload.source else { return }
        remove(payload.command, from: source)
    }

    /// menu:Window[Toolbars > Reset Toolbars]: every toolbar's factory buttons.
    func reset() {
        change { $0.items = [:] }
    }

    private func change(_ edit: (inout ToolbarContents) -> Void) {
        var next = contents
        edit(&next)
        guard next != contents else { return }
        contents = next
        save()
        notify()
    }

    private func save() {
        guard let store else { return }
        do {
            try store.save(contents)
            lastSaveError = nil
        } catch {
            lastSaveError = error
        }
    }

    // MARK: Info

    /// The key window's tool manager feeds the Info toolbar; nil clears it.
    func attach(infoSource manager: ToolManager?) {
        info.info = manager?.info ?? ToolInfo()
        info.document = manager?.context.document
        manager?.onInfoChange = { [weak self] info in self?.info.info = info }
    }
}
