import AppKit

/// Which Tools panel section a tool sits in (toolbars.adoc, "The Tools panel").
enum ToolSection: String, Sendable {
    case tools
    case view
}

/// Everything the app needs to know about a tool (toolbars.adoc, "Client").  BASIC-008 adds
/// flyout groups and option sheets and registers every tool.
struct ToolDescriptor: Identifiable, Sendable {
    let id: ToolID
    var title: String
    /// SF Symbol for the Tools panel.
    var symbolName: String
    /// Default shortcut (the first key of the page's list; BASIC-008 binds the digits too).
    var shortcut: KeyEquivalent?
    var section: ToolSection
    var helpSlug: String
    var make: @MainActor @Sendable () -> any Tool

    init(
        id: ToolID, title: String, symbolName: String, shortcut: KeyEquivalent? = nil, section: ToolSection = .tools,
        helpSlug: String, make: @escaping @MainActor @Sendable () -> any Tool
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.section = section
        self.helpSlug = helpSlug
        self.make = make
    }

    /// `tool.<id>`: the command a tool's shortcut runs, and its accessibility identifier.
    var commandID: CommandID { ToolRegistry.commandID(for: id) }
}

/// The tools the application has.  Registering a descriptor gives the tool a Tools panel
/// button and a `tool.<id>` command bound to its shortcut (no menu item: shortcuts are
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

    /// A new instance of `id`; an unknown id gets an `UnimplementedTool`.
    func makeTool(_ id: ToolID) -> any Tool {
        descriptor(for: id)?.make() ?? UnimplementedTool(id: id, title: id.rawValue)
    }

    /// One command per tool.  `activate` selects the tool in the key window; `activeTool`
    /// reports the key window's tool for the check mark (nil without a document window).
    func commands(activate: @escaping @MainActor @Sendable (ToolID) -> Void, activeTool: @escaping @MainActor @Sendable () -> ToolID?) -> [Command] {
        descriptors.map { descriptor in
            let id = descriptor.id
            return Command(
                id: descriptor.commandID, title: descriptor.title, key: descriptor.shortcut,
                keywords: ["tool", descriptor.section.rawValue],
                validation: {
                    guard let active = activeTool() else { return .disabled("No document is open") }
                    return .checked(active == id)
                },
                action: .perform { activate(id) }
            )
        }
    }

    /// The tools APP-003 delivers or stubs.  BASIC-008 registers the rest.
    static func builtIn() -> [ToolDescriptor] {
        [
            ToolDescriptor(id: .pointer, title: "Pointer", symbolName: "cursorarrow", shortcut: KeyEquivalent("v"), helpSlug: "selecting") {
                UnimplementedTool(id: .pointer, title: "Pointer", cursor: .arrow)
            },
            ToolDescriptor(id: .rectangle, title: "Rectangle", symbolName: "rectangle", shortcut: KeyEquivalent("r"), helpSlug: "rectangles-ellipses-lines") {
                RectangleSketchTool()
            },
            ToolDescriptor(id: .zoom, title: "Zoom", symbolName: "plus.magnifyingglass", shortcut: KeyEquivalent("z"), section: .view, helpSlug: "document-view") {
                ZoomTool()
            },
            ToolDescriptor(id: .hand, title: "Hand", symbolName: "hand.raised", shortcut: KeyEquivalent("h"), section: .view, helpSlug: "document-view") {
                PanTool()
            },
        ]
    }

    func registerBuiltIn() {
        for descriptor in Self.builtIn() where !contains(descriptor.id) { replace(descriptor) }
    }
}
