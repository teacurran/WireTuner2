import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The *Press new shortcut* field: records the next key press, modifiers included, instead of
/// letting it reach a menu.
@MainActor
final class KeyCaptureView: NSView {
    static let prompt = "Click, then press keys"

    var onCapture: @MainActor (KeyEquivalent) -> Void = { _ in }
    let label = NSTextField(labelWithString: KeyCaptureView.prompt)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel("Press new shortcut")
        setAccessibilityIdentifier("shortcuts.capture")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyCaptureView is built in code")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Records `event` as a shortcut; returns whether it was one.
    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard let key = KeyEquivalentResolver.keyEquivalent(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", modifierFlags: event.modifierFlags
        ) else { return false }
        show(key)
        onCapture(key)
        return true
    }

    func show(_ key: KeyEquivalent?) {
        label.stringValue = key?.displayString ?? Self.prompt
    }

    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    /// Command-key combinations arrive here before any menu sees them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        return capture(event)
    }
}

struct KeyCaptureField: NSViewRepresentable {
    let key: KeyEquivalent?
    let onCapture: @MainActor (KeyEquivalent) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onCapture = onCapture
        view.show(key)
    }
}

/// The window's content: set pop-up with btn:[+] and btn:[⋯], the searchable Commands list,
/// and the detail form.
struct KeyboardShortcutsView: View {
    @Bindable var model: KeyboardShortcutsModel

    /// Every button runs its action through this one closure.
    func act(_ action: KeyboardShortcutsModel.Action) -> () -> Void {
        { model.handle(action) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField("Search commands", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("shortcuts.search")
            List(selection: model.selection) {
                ForEach(model.categories) { category in
                    Section(isExpanded: model.expansion(for: category.id)) {
                        ForEach(category.rows) { row in
                            HStack {
                                Text(row.title)
                                Spacer()
                                Text(row.shortcut).foregroundStyle(.secondary)
                            }
                            .tag(row.id)
                            .accessibilityIdentifier("shortcuts.command.\(row.id.rawValue)")
                        }
                    } header: {
                        Text(category.id)
                    }
                }
            }
            .frame(minHeight: 240)
            .accessibilityIdentifier("shortcuts.commands")
            detail
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 560)
        .sheet(isPresented: $model.showingCardPreview) { ShortcutCardPreview(model: model, act: act) }
    }

    private var header: some View {
        HStack {
            Picker("Shortcut set", selection: $model.activeSetID) {
                ForEach(model.summaries, id: \.id) { summary in
                    Text(summary.name).tag(summary.id)
                }
            }
            .accessibilityIdentifier("shortcuts.set")
            Button("+", action: act(.newSet)).accessibilityIdentifier("shortcuts.newSet")
            Menu("⋯") {
                Button("Rename…", action: act(.rename)).disabled(!model.isEditable)
                Button("Duplicate…", action: act(.duplicate))
                Button("Delete", action: act(.delete)).disabled(!model.isEditable)
                Divider()
                Button("Export Set…", action: act(.exportSet))
                Button("Import Set…", action: act(.importSet))
                Button("Export as Text…", action: act(.exportText))
            }
            .fixedSize()
            .accessibilityIdentifier("shortcuts.more")
            Spacer()
            Button("Print…", action: act(.showCard)).accessibilityIdentifier("shortcuts.print")
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.commandDescription).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Current shortcuts").font(.caption)
                    Picker("Current shortcuts", selection: $model.selectedKey) {
                        ForEach(model.currentShortcuts, id: \.self) { key in
                            Text(key.displayString).tag(Optional(key))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("shortcuts.current")
                    Button("Remove", action: act(.remove)).disabled(model.selectedKey == nil)
                        .accessibilityIdentifier("shortcuts.remove")
                }
                Spacer()
                VStack(alignment: .leading) {
                    Text("Press new shortcut").font(.caption)
                    KeyCaptureField(key: model.capturedKey, onCapture: model.capture).frame(width: 180, height: 24)
                    if let text = model.refusal ?? model.conflictText {
                        Text(text).font(.caption).foregroundStyle(model.refusal == nil ? Color.secondary : Color.red)
                            .accessibilityIdentifier("shortcuts.conflict")
                    }
                    Toggle("Go to conflict on assign", isOn: $model.goToConflictOnAssign)
                    HStack {
                        Button("Assign", action: act(.assign)).disabled(!model.canAssign)
                            .accessibilityIdentifier("shortcuts.assign")
                        Button("Revert", action: act(.revert)).accessibilityIdentifier("shortcuts.revert")
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("shortcuts.message")
            }
        }
    }
}

/// The print preview sheet: the card, *Include commands without shortcuts*, btn:[Print] and
/// btn:[Save as PDF].
struct ShortcutCardPreview: View {
    @Bindable var model: KeyboardShortcutsModel
    let act: (KeyboardShortcutsModel.Action) -> () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShortcutCardScrollView(card: model.cardView()).frame(width: 640, height: 480)
            Toggle("Include commands without shortcuts", isOn: $model.includeUnboundOnCard)
            HStack {
                Button("Cancel", action: act(.closeCard))
                Spacer()
                Button("Save as PDF…", action: act(.saveCardPDF))
                Button("Print…", action: act(.printCard)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

struct ShortcutCardScrollView: NSViewRepresentable {
    let card: ShortcutCardView

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = card
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.documentView = card
    }
}

/// menu:Edit[Keyboard Shortcuts…]: one window per application.
@MainActor
final class KeyboardShortcutsWindowController: NSWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("keyboard-shortcuts-window")

    let model: KeyboardShortcutsModel

    init(model: KeyboardShortcutsModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.identifier = Self.identifier
        window.setAccessibilityIdentifier(Self.identifier.rawValue)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: KeyboardShortcutsView(model: model))
        super.init(window: window)
        window.center()
        model.confirm = { [weak window] message in Self.confirm(message, in: window) }
        model.askName = { title, suggested in Self.askName(title: title, suggested: suggested) }
        model.chooseSaveURL = { name in Self.chooseSaveURL(suggestedName: name) }
        model.chooseOpenURL = { Self.chooseOpenURL() }
        model.runPrint = { operation in operation.run() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyboardShortcutsWindowController is built in code")
    }

    func show() {
        model.beginSession()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Something run modally: an alert or a save or open panel.
    enum Modal {
        case alert(NSAlert)
        case panel(NSSavePanel)
    }

    /// Runs an alert or a panel modally; tests replace it.
    static var runModal: @MainActor (Modal) -> NSApplication.ModalResponse = { modal in
        switch modal {
        case let .alert(alert): alert.runModal()
        case let .panel(panel): panel.runModal()
        }
    }

    static func confirm(_ message: String, in window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Make a Copy")
        alert.addButton(withTitle: "Cancel")
        return runModal(.alert(alert)) == .alertFirstButtonReturn
    }

    static func askName(title: String, suggested: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return runModal(.alert(alert)) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func chooseSaveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return runModal(.panel(panel)) == .OK ? panel.url : nil
    }

    static func chooseOpenURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ShortcutSet.fileExtension) ?? .json, .json]
        return runModal(.panel(panel)) == .OK ? panel.url : nil
    }
}

/// The registry side: menu:Edit[Keyboard Shortcuts…] opens the window.
enum KeyboardShortcutsCommands {
    @MainActor
    static func command(show: @escaping @MainActor @Sendable () -> Void) -> Command {
        Command(
            id: StandardCommands.ID.keyboardShortcuts, title: "Keyboard Shortcuts…",
            menu: MenuPath(StandardCommands.Menu.edit, section: 2), keywords: ["keys", "bindings", "shortcut set"],
            action: .perform(show)
        )
    }

    @MainActor
    static func install(into registry: CommandRegistry, show: @escaping @MainActor @Sendable () -> Void) {
        registry.replace(command(show: show))
    }
}
