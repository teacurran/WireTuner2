import AppKit
import SwiftUI

/// The palette window: a borderless-looking panel that can become key without activating
/// anything else; kbd:[Esc] closes it.
@MainActor
final class PalettePanel: NSPanel {
    var onCancel: @MainActor () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}

extension PaletteKey {
    /// The palette key a SwiftUI key press means; nil for any other key.
    init?(_ key: SwiftUI.KeyEquivalent) {
        switch key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .return: self = .run
        case .escape: self = .dismiss
        default: return nil
        }
    }
}

/// The palette's content: the search field and the ranked list.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    @FocusState private var searchFocused: Bool

    static let keys: Set<SwiftUI.KeyEquivalent> = [.upArrow, .downArrow, .return, .escape]

    /// Every navigation key goes through here.
    func press(_ key: SwiftUI.KeyEquivalent) -> KeyPress.Result {
        guard let paletteKey = PaletteKey(key) else { return .ignored }
        model.handle(paletteKey)
        return .handled
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands, tools and panels", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onKeyPress(keys: Self.keys) { press($0.key) }
                .accessibilityIdentifier("palette.search")
            Divider()
            ScrollViewReader { proxy in
                List(Array(model.results.enumerated()), id: \.element.id) { index, result in
                    PaletteRow(item: result.item, isSelected: index == model.selection)
                        .id(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.run(at: index) }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("palette.results")
                .onChange(of: model.selection) { if let id = model.selectedResult?.id { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 560, height: 380)
        .onAppear { searchFocused = true }
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbolName ?? "command").frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut.displayString).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(item.isEnabled ? 1 : 0.45)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("palette.item.\(item.id)")
    }
}

/// Shows and hides the palette over the key document window (one panel per application,
/// positioned at the top third of whichever window is key).  Running an item closes the panel
/// and gives the window its focus back first, so a responder-chain command reaches the window
/// exactly as from the menu.
@MainActor
final class CommandPaletteController {
    static let identifier = NSUserInterfaceItemIdentifier("command-palette")

    let model: CommandPaletteModel
    let panel: PalettePanel
    private(set) weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    init(model: CommandPaletteModel) {
        self.model = model
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.identifier = Self.identifier
        panel.setAccessibilityIdentifier(Self.identifier.rawValue)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = NSHostingController(rootView: CommandPaletteView(model: model))
        panel.onCancel = { [weak self] in self?.close() }
        model.onDismiss = { [weak self] in self?.close() }
        model.onRun = { [weak self] in self?.close() }
    }

    var isShown: Bool { panel.isVisible }

    /// Where the panel goes over `frame`: centred, its top a third of the way down.
    static func frame(over frame: NSRect, size: NSSize) -> NSRect {
        NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 3 - size.height / 2, width: size.width, height: size.height)
    }

    /// menu:Help[Command Palette…] (kbd:[Cmd+/]): opens over `window`, or closes when open.
    func toggle(over window: NSWindow?) {
        if isShown { close() } else { show(over: window) }
    }

    func show(over window: NSWindow?) {
        previousWindow = window
        previousResponder = window?.firstResponder
        model.reset()
        if let window {
            panel.setFrame(Self.frame(over: window.frame, size: panel.frame.size), display: false)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel; focus returns to the window and responder it came from.
    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let previousWindow {
            previousWindow.makeKey()
            if let previousResponder { previousWindow.makeFirstResponder(previousResponder) }
        }
    }
}

/// The registry side of the palette.
enum CommandPaletteCommands {
    @MainActor
    static func command(toggle: @escaping @MainActor @Sendable () -> Void) -> Command {
        Command(
            id: StandardCommands.ID.commandPalette, title: "Command Palette…", key: KeyEquivalent("/", .command),
            menu: MenuPath(StandardCommands.Menu.help, section: 1), keywords: ["search", "run", "find command"],
            action: .perform(toggle)
        )
    }

    /// Replaces the placeholder and registers the command and panel sources (and the pages of
    /// the front document).
    @MainActor
    static func install(
        into registry: CommandRegistry, panels: PanelRegistry, controller: CommandPaletteController,
        shortcuts: @escaping @MainActor () -> ShortcutSet, perform: @escaping @MainActor @Sendable (CommandID) -> Void,
        showPanel: @escaping @MainActor @Sendable (PanelID) -> Void, document: @escaping @MainActor () -> DocumentHandle?,
        goToPage: @escaping @MainActor @Sendable (Int) -> Void, keyWindow: @escaping @MainActor @Sendable () -> NSWindow?
    ) {
        registry.replace(command { controller.toggle(over: keyWindow()) })
        controller.model.register(CommandPaletteSource(registry: registry, shortcuts: shortcuts, perform: perform), id: "commands")
        controller.model.register(PanelPaletteSource(panels: panels, show: showPanel), id: "panels")
        controller.model.register(PagePaletteSource(document: document, goToPage: goToPage), id: "pages")
    }
}
