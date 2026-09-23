import Foundation

/// The customizable toolbars (toolbars.adoc): the five dockable ones and the Tools panel.  The
/// Main toolbar is an `NSToolbar` customized with the standard sheet instead.
enum ToolbarID: String, CaseIterable, Codable, Sendable, Identifiable {
    case text
    case info
    case envelope
    case extensionTools
    case extensionOperations
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .info: "Info"
        case .envelope: "Envelope"
        case .extensionTools: "Extension Tools"
        case .extensionOperations: "Extension Operations"
        case .tools: "Tools"
        }
    }

    /// The toolbars menu:Window[Toolbars] lists (the Tools panel is menu:Window[Tools]).
    static let dockable: [ToolbarID] = [.text, .info, .envelope, .extensionTools, .extensionOperations]

    /// The panel that hosts the toolbar in the panel framework.
    var panelID: PanelID {
        self == .tools ? ToolsPanel.id : PanelID("toolbar.\(rawValue)")
    }

    /// The default group the toolbar's panel forms (one toolbar per group).
    var defaultGroup: String { "toolbar.\(rawValue)" }

    /// `toolbar.<name>.<command>` (TEST-002).
    func accessibilityIdentifier(for command: CommandID) -> String {
        "toolbar.\(rawValue).\(command.rawValue)"
    }
}

/// The commands the Text and Envelope toolbars carry before the type and envelope epics
/// register them (disabled placeholders with no menu item), and the SF Symbols of every
/// toolbar command that is neither a tool nor an extension.
enum ToolbarCatalog {
    static let textItems: [(id: CommandID, title: String, symbol: String)] = [
        ("text.fontFamily", "Font Family", "textformat"),
        ("text.fontStyle", "Font Style", "bold.italic.underline"),
        ("text.fontSize", "Font Size", "textformat.size"),
        ("text.leading", "Leading", "text.line.first.and.arrowtriangle.forward"),
        ("text.align.left", "Align Left", "text.alignleft"),
        ("text.align.center", "Align Center", "text.aligncenter"),
        ("text.align.right", "Align Right", "text.alignright"),
        ("text.align.justified", "Justify", "text.justify"),
        ("text.attachToPath", "Attach to Path", "point.topleft.down.to.point.bottomright.curvepath"),
        ("text.flowInsidePath", "Flow Inside Path", "square.text.square"),
        ("text.runAround", "Run Around Selection", "text.word.spacing"),
        ("text.convertToPaths", "Convert to Paths", "character.cursor.ibeam"),
        ("text.editor", "Text Editor", "doc.plaintext"),
        ("text.spelling", "Spelling", "textformat.abc.dottedunderline"),
    ]

    static let envelopeItems: [(id: CommandID, title: String, symbol: String)] = [
        ("envelope.create", "Create Envelope", "square.dashed"),
        ("envelope.showMap", "Show Map", "map"),
        ("envelope.copyAsPath", "Copy as Path", "doc.on.doc"),
        ("envelope.release", "Release Envelope", "arrow.up.bin"),
        ("envelope.remove", "Remove Envelope", "trash"),
        ("envelope.presets", "Envelope Presets", "list.bullet"),
    ]

    static var placeholders: [Command] {
        (textItems + envelopeItems).map { item in
            Command.placeholder(id: item.id, title: item.title, keywords: ["toolbar", item.id.rawValue.hasPrefix("text") ? "text" : "envelope"])
        }
    }

    static let symbols: [CommandID: String] = Dictionary(uniqueKeysWithValues: (textItems + envelopeItems).map { ($0.id, $0.symbol) })

    /// A toolbar's factory buttons.
    @MainActor
    static func defaultItems(_ toolbar: ToolbarID, extensions: ExtensionRegistry) -> [CommandID] {
        switch toolbar {
        case .text: textItems.map(\.id)
        case .envelope: envelopeItems.map(\.id)
        case .extensionTools: extensions.defaultItems(for: .tools)
        case .extensionOperations: extensions.defaultItems(for: .operations)
        case .info, .tools: []
        }
    }
}
