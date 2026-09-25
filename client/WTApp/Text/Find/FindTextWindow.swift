import AppKit
import SwiftUI
import WTModel

/// The Find and Replace Text window's body: *Find* and *Replace with* with their *Special*
/// pop-ups, the options and the four buttons.
struct FindTextView: View {
    @Bindable var model: FindTextModel
    let window: @MainActor () -> DocumentWindowController?

    static func special(_ model: FindTextModel, replacement: Bool) -> some View {
        Menu("Special") {
            ForEach(FindTextModel.specials, id: \.title) { item in
                Button(item.title, action: inserting(item.character, model, replacement: replacement))
            }
        }
        .fixedSize()
        .accessibilityIdentifier(replacement ? "findText.replaceSpecial" : "findText.findSpecial")
    }

    static func inserting(_ character: String, _ model: FindTextModel, replacement: Bool) -> () -> Void {
        { model.insertSpecial(character, intoReplacement: replacement) }
    }

    static func replaceAll(_ model: FindTextModel, _ window: DocumentWindowController) { model.replaceAll(in: window) }
    static func replace(_ model: FindTextModel, _ window: DocumentWindowController) { model.replace(in: window) }
    static func replaceAndFind(_ model: FindTextModel, _ window: DocumentWindowController) { model.replaceAndFind(in: window) }
    static func findNext(_ model: FindTextModel, _ window: DocumentWindowController) { model.findNext(in: window) }

    static func acting(_ action: @escaping @MainActor (FindTextModel, DocumentWindowController) -> Void, _ model: FindTextModel,
                       _ window: @escaping @MainActor () -> DocumentWindowController?) -> () -> Void {
        { if let front = window() { action(model, front) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Find", text: $model.find).accessibilityIdentifier("findText.find")
                Self.special(model, replacement: false)
            }
            HStack {
                TextField("Replace with", text: $model.replacement).accessibilityIdentifier("findText.replace")
                Self.special(model, replacement: true)
            }
            HStack {
                Toggle("Whole word", isOn: $model.wholeWord).accessibilityIdentifier("findText.wholeWord")
                Toggle("Match case", isOn: $model.matchCase).accessibilityIdentifier("findText.matchCase")
                Picker("Search in", selection: $model.scope) {
                    ForEach(FindTextModel.Scope.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .accessibilityIdentifier("findText.scope")
            }
            .toggleStyle(.checkbox)
            HStack {
                Text(model.message ?? "").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("findText.message")
                Spacer()
                Button("Replace All", action: Self.acting(Self.replaceAll, model, window)).accessibilityIdentifier("findText.replaceAll")
                Button("Replace", action: Self.acting(Self.replace, model, window)).accessibilityIdentifier("findText.replaceOne")
                Button("Replace & Find", action: Self.acting(Self.replaceAndFind, model, window)).accessibilityIdentifier("findText.replaceFind")
                Button("Find Next", action: Self.acting(Self.findNext, model, window)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("findText.findNext")
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

/// menu:Edit[Find and Replace > Text…] (kbd:[Cmd+F]): one floating window for the app, acting on
/// the front document window.
@MainActor
final class FindTextFeatures {
    static let shared = FindTextFeatures()
    static let findTextID: CommandID = "edit.findReplace.text"
    static let menu = "Find and Replace"

    let model = FindTextModel()
    private(set) var panel: NSPanel?

    /// Shows the window (made on first use).
    @discardableResult
    func show(window: @escaping @MainActor () -> DocumentWindowController?, ordersFront: Bool = true) -> NSPanel {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 180), styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: true)
            panel.title = "Find and Replace Text"
            panel.identifier = NSUserInterfaceItemIdentifier("find-text")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.contentViewController = NSHostingController(rootView: FindTextView(model: model, window: window))
            return panel
        }()
        self.panel = panel
        if ordersFront { panel.makeKeyAndOrderFront(nil) }
        return panel
    }

    func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        [Command(id: Self.findTextID, title: "Text…", key: KeyEquivalent("f", .command), menu: MenuPath(StandardCommands.Menu.edit, Self.menu, section: 5),
                 keywords: ["find", "replace", "search"], validation: { window() == nil ? .disabled(BlendMenu.noDocument) : .enabled },
                 action: .perform { [weak self] in self?.show(window: window) })]
    }
}
