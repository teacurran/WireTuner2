import AppKit

/// Which Tools panel section a tool sits in (toolbars.adoc, "The Tools panel").
enum ToolSection: String, Sendable {
    case tools
    case view
}

/// A flyout: related tools sharing one slot of the Tools panel (toolbars.adoc, "To select a
/// tool from a flyout").  The first member is the slot's default.
struct FlyoutGroup: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    static let pen: FlyoutGroup = "pen"
    static let pencil: FlyoutGroup = "pencil"
    static let rectangle: FlyoutGroup = "rectangle"
    static let ellipse: FlyoutGroup = "ellipse"
    static let freeform: FlyoutGroup = "freeform"
    static let knife: FlyoutGroup = "knife"
    static let effects: FlyoutGroup = "effects"
    static let transform: FlyoutGroup = "transform"
}

/// Everything the app needs to know about a tool (toolbars.adoc, "Client": `ToolDescriptor`).
struct ToolDescriptor: Identifiable, Sendable {
    let id: ToolID
    var title: String
    /// SF Symbol for the Tools panel.
    var symbolName: String
    /// The default shortcut set's keys, the letter first; empty is the decision "no shortcut".
    var shortcuts: [KeyEquivalent]
    var group: FlyoutGroup?
    var section: ToolSection
    /// The options sheet a double-click opens; nil for tools without options.
    var options: (@MainActor @Sendable () -> NSViewController)?
    var helpSlug: String
    var make: @MainActor @Sendable () -> any Tool

    init(
        id: ToolID, title: String, symbolName: String, shortcuts: [KeyEquivalent] = [], group: FlyoutGroup? = nil, section: ToolSection = .tools,
        options: (@MainActor @Sendable () -> NSViewController)? = nil, helpSlug: String, make: @escaping @MainActor @Sendable () -> any Tool
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.shortcuts = shortcuts
        self.group = group
        self.section = section
        self.options = options
        self.helpSlug = helpSlug
        self.make = make
    }

    /// One shortcut (APP-003's form).
    init(
        id: ToolID, title: String, symbolName: String, shortcut: KeyEquivalent?, section: ToolSection = .tools,
        helpSlug: String, make: @escaping @MainActor @Sendable () -> any Tool
    ) {
        self.init(id: id, title: title, symbolName: symbolName, shortcuts: shortcut.map { [$0] } ?? [], section: section, helpSlug: helpSlug, make: make)
    }

    /// The key the menu and tooltips show.
    var shortcut: KeyEquivalent? { shortcuts.first }

    /// `tool.<id>`: the command a tool's shortcut runs, and its accessibility identifier.
    var commandID: CommandID { ToolRegistry.commandID(for: id) }

    /// "Pen (P)", or the title alone.
    var tooltip: String { shortcut.map { "\(title) (\($0.displayString))" } ?? title }

    /// The same catalog entry running `make` (an epic delivering its tool).
    func delivering(_ make: @escaping @MainActor @Sendable () -> any Tool) -> ToolDescriptor {
        var copy = self
        copy.make = make
        return copy
    }
}

/// The tools the application has.  Registering a descriptor gives the tool a Tools panel
/// button and a `tool.<id>` command bound to its shortcuts (no menu item: shortcuts are
/// dispatched by the canvas through the registry).
@MainActor
final class ToolRegistry {
    enum Failure: Error, Equatable {
        case duplicateID(ToolID)
    }

    private(set) var descriptors: [ToolDescriptor] = []
    private var indexByID: [ToolID: Int] = [:]
    var onChange: (@MainActor () -> Void)?

    init() {}

    nonisolated static func commandID(for id: ToolID) -> CommandID { CommandID("tool.\(id.rawValue)") }

    func register(_ descriptor: ToolDescriptor) throws {
        guard indexByID[descriptor.id] == nil else { throw Failure.duplicateID(descriptor.id) }
        indexByID[descriptor.id] = descriptors.count
        descriptors.append(descriptor)
        onChange?()
    }

    /// Replaces the descriptor with the same id (an epic delivering a stubbed tool), or adds it.
    func replace(_ descriptor: ToolDescriptor) {
        if let index = indexByID[descriptor.id] {
            descriptors[index] = descriptor
        } else {
            indexByID[descriptor.id] = descriptors.count
            descriptors.append(descriptor)
        }
        onChange?()
    }

    func descriptor(for id: ToolID) -> ToolDescriptor? { indexByID[id].map { descriptors[$0] } }
    func contains(_ id: ToolID) -> Bool { indexByID[id] != nil }
    var ids: [ToolID] { descriptors.map(\.id) }

    /// The members of `group`, in registration order.
    func members(of group: FlyoutGroup) -> [ToolDescriptor] {
        descriptors.filter { $0.group == group }
    }

    /// A new instance of `id`; an unknown id gets an `UnimplementedTool`.
    func makeTool(_ id: ToolID) -> any Tool {
        descriptor(for: id)?.make() ?? UnimplementedTool(id: id, title: id.rawValue)
    }

    /// One command per tool.  `activate` handles the key press (the Tools panel model cycles
    /// flyouts); `activeTool` reports the key window's tool for the check mark (nil without a
    /// document window).
    func commands(activate: @escaping @MainActor @Sendable (ToolID) -> Void, activeTool: @escaping @MainActor @Sendable () -> ToolID?) -> [Command] {
        descriptors.map { descriptor in
            let id = descriptor.id
            return Command(
                id: descriptor.commandID, title: descriptor.title, key: descriptor.shortcuts.first,
                alternateKeys: Array(descriptor.shortcuts.dropFirst()),
                keywords: ["tool", descriptor.section.rawValue],
                validation: {
                    guard let active = activeTool() else { return .disabled("No document is open") }
                    return .checked(active == id)
                },
                action: .perform { activate(id) }
            )
        }
    }

    /// Every tool of toolbars.adoc: APP-003's delivered tools (Rectangle sketch, Zoom, Hand)
    /// and the rest as `UnimplementedTool`s.
    static func builtIn() -> [ToolDescriptor] {
        ToolCatalog.all
    }

    func registerBuiltIn() {
        for descriptor in Self.builtIn() where !contains(descriptor.id) { replace(descriptor) }
    }
}
