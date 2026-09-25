import Foundation

/// The settings an operation's sheet captured ("Segments: 12"), replayed by Repeat.
typealias ExtensionParameters = [String: String]

/// Which of the two extension toolbars shows an extension.
enum ExtensionToolbar: String, Hashable, Sendable {
    case tools
    case operations
}

/// Everything the app knows about one extension (extensions.adoc, "Client":
/// `ExtensionDescriptor`).  The Extensions menu, both toolbars, the Manage Extensions sheet and
/// Repeat are generated from these.
struct ExtensionDescriptor: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A one-shot command on the selection; its menu item is `extension.<id>`.
        case operation
        /// A tool of the tool registry (`tool.<toolID>`).
        case tool(ToolID)
    }

    let id: String
    /// The menu title, with the ellipsis when the operation opens a sheet ("Simplify…").
    var title: String
    /// The Extensions submenu, and the Manage Extensions category.
    var category: String
    var kind: Kind
    var toolbars: Set<ExtensionToolbar>
    var symbolName: String
    var helpSlug: String
    /// Whether the operation can run now; nil for a stub (disabled, "coming soon").
    var validate: (@MainActor @Sendable () -> CommandValidation)?
    /// Runs the operation.  Given nil it asks for its settings (its sheet) and returns what it
    /// captured; Repeat passes the captured settings back.  Nil for a stub.
    var run: (@MainActor @Sendable (ExtensionParameters?) -> ExtensionParameters?)?

    init(
        id: String, title: String, category: String, kind: Kind = .operation, toolbars: Set<ExtensionToolbar> = [], symbolName: String,
        helpSlug: String, validate: (@MainActor @Sendable () -> CommandValidation)? = nil,
        run: (@MainActor @Sendable (ExtensionParameters?) -> ExtensionParameters?)? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.kind = kind
        self.toolbars = toolbars
        self.symbolName = symbolName
        self.helpSlug = helpSlug
        self.validate = validate
        self.run = run
    }

    /// The title without a trailing ellipsis: toolbar tooltips and "Repeat Simplify".
    var shortTitle: String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// The command the menu item and the toolbar button run.
    var commandID: CommandID {
        switch kind {
        case .operation: ExtensionRegistry.commandID(for: id)
        case let .tool(tool): ToolRegistry.commandID(for: tool)
        }
    }

    var isOperation: Bool { kind == .operation }
    var isStub: Bool { run == nil }
}

/// The last operation run, for menu:Extensions[Repeat <name>] (`ExtensionRepeatState`).
struct ExtensionRepeatState: Equatable, Sendable {
    var extensionID: String
    var parameters: ExtensionParameters?
}

/// Every extension, which of them are turned off on this Mac (`wt.extensions.disabled`), and
/// the Repeat state.  Disabled extensions stay registered, so documents that use them render
/// and edit; only the menu items and toolbar buttons go away.
@MainActor
final class ExtensionRegistry {
    nonisolated static let disabledDefaultsKey = "wt.extensions.disabled"
    nonisolated static let menuTitle = "Extensions"
    nonisolated static let otherCategory = "Other"

    nonisolated static func commandID(for id: String) -> CommandID { CommandID("extension.\(id)") }

    private(set) var descriptors: [ExtensionDescriptor] = []
    private(set) var disabled: Set<String>
    private(set) var repeatState: ExtensionRepeatState?
    /// The settings each operation's sheet captured last (kbd:[Cmd]-click replays them).
    private(set) var lastParameters: [String: ExtensionParameters] = [:]
    let defaults: UserDefaults?
    /// Called after a descriptor is replaced or the disabled set changes (menus and toolbars
    /// rebuild).
    var onChange: (@MainActor () -> Void)?

    init(descriptors: [ExtensionDescriptor] = ExtensionCatalog.all, defaults: UserDefaults? = nil) {
        self.descriptors = descriptors
        self.defaults = defaults
        disabled = Set(defaults?.stringArray(forKey: Self.disabledDefaultsKey) ?? [])
    }

    func descriptor(for id: String) -> ExtensionDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// The extension whose command is `commandID`.
    func descriptor(forCommand commandID: CommandID) -> ExtensionDescriptor? {
        descriptors.first { $0.commandID == commandID }
    }

    /// An epic delivering its operation: the descriptor with the same id is replaced.
    func replace(_ descriptor: ExtensionDescriptor) {
        guard let index = descriptors.firstIndex(where: { $0.id == descriptor.id }) else { return }
        descriptors[index] = descriptor
        onChange?()
    }

    /// Categories in menu order, each with its extensions (operations first, as registered).
    var categories: [(title: String, extensions: [ExtensionDescriptor])] {
        var order: [String] = []
        var members: [String: [ExtensionDescriptor]] = [:]
        for descriptor in descriptors {
            if members[descriptor.category] == nil { order.append(descriptor.category) }
            members[descriptor.category, default: []].append(descriptor)
        }
        return order.map { ($0, members[$0]!) }
    }

    // MARK: Enabled

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    func setEnabled(_ enabled: Bool, _ id: String) {
        setEnabled(enabled, ids: [id])
    }

    /// Turns a whole category on or off.
    func setEnabled(_ enabled: Bool, category: String) {
        setEnabled(enabled, ids: descriptors.filter { $0.category == category }.map(\.id))
    }

    /// `true`, `false`, or nil when a category is partly on.
    func categoryState(_ category: String) -> Bool? {
        let states = Set(descriptors.filter { $0.category == category }.map { isEnabled($0.id) })
        return states.count == 1 ? states.first : nil
    }

    private func setEnabled(_ enabled: Bool, ids: [String]) {
        let next = enabled ? disabled.subtracting(ids) : disabled.union(ids)
        guard next != disabled else { return }
        disabled = next
        defaults?.set(disabled.sorted(), forKey: Self.disabledDefaultsKey)
        onChange?()
    }

    /// The enabled extensions a toolbar shows by default, in catalog order.
    func defaultItems(for toolbar: ExtensionToolbar) -> [CommandID] {
        ExtensionCatalog.toolbarOrder(toolbar).compactMap(descriptor(for:)).map(\.commandID)
    }

    /// Commands of disabled extensions: their toolbar buttons hide.
    var hiddenCommands: Set<CommandID> {
        Set(descriptors.filter { !isEnabled($0.id) }.map(\.commandID))
    }

    // MARK: Running

    static let comingSoon = "is coming soon"

    func validation(ofExtension id: String) -> CommandValidation {
        descriptor(for: id).map(validation(of:)) ?? .disabled("Unknown extension")
    }

    func validation(of descriptor: ExtensionDescriptor) -> CommandValidation {
        guard isEnabled(descriptor.id) else { return .disabled("Turned off in Manage Extensions") }
        guard !descriptor.isStub else { return .disabled("\(descriptor.shortTitle) \(Self.comingSoon)") }
        return descriptor.validate?() ?? .enabled
    }

    /// Runs an operation from its menu item or button, asking for its settings, and records it
    /// for Repeat.  Returns whether it ran.
    @discardableResult
    func perform(_ id: String) -> Bool {
        guard let descriptor = descriptor(for: id), descriptor.isOperation, validation(of: descriptor).isEnabled, let run = descriptor.run else { return false }
        let parameters = run(nil)
        repeatState = ExtensionRepeatState(extensionID: id, parameters: parameters)
        if let parameters { lastParameters[id] = parameters }
        return true
    }

    /// kbd:[Cmd]-click on an operation's toolbar button (path-effects.adoc, "Embossing"; FX-030):
    /// it runs with the settings its sheet captured last -- none yet: its defaults -- without the
    /// sheet, and is recorded for Repeat.  Returns whether it ran.
    @discardableResult
    func performWithPreviousSettings(_ id: String) -> Bool {
        guard let descriptor = descriptor(for: id), descriptor.isOperation, validation(of: descriptor).isEnabled, let run = descriptor.run else { return false }
        let parameters = lastParameters[id] ?? [:]
        _ = run(parameters)
        repeatState = ExtensionRepeatState(extensionID: id, parameters: parameters)
        return true
    }

    /// menu:Extensions[Repeat <name>]: the last operation with the same settings.
    @discardableResult
    func performRepeat() -> Bool {
        guard let state = repeatState, let descriptor = descriptor(for: state.extensionID), validation(of: descriptor).isEnabled,
            let run = descriptor.run
        else { return false }
        _ = run(state.parameters ?? [:])
        return true
    }

    /// A tool was used after the last operation: tools are not repeated, so Repeat is
    /// disabled until the next operation.
    func noteToolUsed() {
        repeatState = nil
    }

    var repeatValidation: CommandValidation {
        guard let state = repeatState, let descriptor = descriptor(for: state.extensionID) else {
            return CommandValidation(isEnabled: false, reason: "No extension to repeat", title: "Repeat Extension")
        }
        let title = "Repeat \(descriptor.shortTitle)"
        let validation = validation(of: descriptor)
        return CommandValidation(isEnabled: validation.isEnabled, reason: validation.reason, title: title)
    }
}
