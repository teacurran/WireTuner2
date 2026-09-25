import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTText

/// The Envelope toolbar's presets and the one it creates envelopes with (path-effects.adoc,
/// "Envelopes"): the user's presets are one preferences string each (`EnvelopePreset.encoded`),
/// synced with the account preferences so they follow the user to another Mac; an empty list reads
/// as the default set.  The chosen preset is this Mac's.
enum EnvelopePreferences {
    static let presets = PreferenceKey<[String]>("tools.envelope.presets", "Envelope presets", category: .object, default: [], control: .list,
                                                 help: "path-effects")
    static let chosen = PreferenceKey<String>("tools.envelope.preset", "Envelope preset", category: .object, scope: .local, default: EnvelopePreset.rectangle.name,
                                              control: .text(placeholder: EnvelopePreset.rectangle.name), help: "path-effects")
}

/// A menu item that runs a closure (the Envelope toolbar's preset pop-up).
@MainActor
final class ActionMenuItem: NSMenuItem {
    let run: @MainActor () -> Void

    init(title: String, checked: Bool = false, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ActionMenuItem is built in code")
    }

    @objc func choose(_ sender: Any?) {
        run()
    }
}

/// menu:Modify[Envelope] and the Envelope toolbar (path-effects.adoc, "Envelopes"; FX-039's
/// client-ui half): Create (the chosen preset around the selection), Paste as Envelope (the copied
/// path's outline), Show Map, Copy as Path, Release, Remove, Save as Preset… and Delete Preset,
/// and the toolbar's preset pop-up.  Every command that writes is one change with its model label.
@MainActor
final class EnvelopeFeatures {
    typealias Target = ObjectMenuCommands.Target

    enum ID {
        static let create: CommandID = "envelope.create"
        static let pasteAsEnvelope: CommandID = "envelope.pasteAsEnvelope"
        static let savePreset: CommandID = "envelope.savePreset"
        static let deletePreset: CommandID = "envelope.deletePreset"
        static let presets: CommandID = "envelope.presets"
    }

    static let sheet = "envelope-preset-sheet"
    static let noEnvelope = "Select an envelope"
    static let noPath = "Copy a closed path of four or more points first"
    static let submenu = "Envelope"

    let target: Target
    let store: PreferenceStore
    let sheets: SheetPresenter
    /// Shows the preset pop-up (at the pointer in the app); replaceable in tests.
    var presentMenu: @MainActor (NSMenu) -> Void = { menu in menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    init(target: @escaping Target, store: PreferenceStore, sheets: SheetPresenter = SheetPresenter()) {
        self.target = target
        self.store = store
        self.sheets = sheets
    }

    // MARK: Presets

    /// The pop-up's presets: the user's, or the default set.
    var presets: [EnvelopePreset] { EnvelopePreset.decode(store[EnvelopePreferences.presets]) }

    /// The preset Create uses: the one chosen in the pop-up, else the first.
    var chosenPreset: EnvelopePreset {
        let presets = presets
        return presets.first { $0.name == store[EnvelopePreferences.chosen] } ?? presets[0]
    }

    func choose(_ name: String) {
        store.set(name, for: EnvelopePreferences.chosen)
    }

    /// Adds `preset` to the user's list (replacing one of the same name) and chooses it; the
    /// defaults are kept when the list was still the default set.
    func save(_ preset: EnvelopePreset) {
        var list = presets.filter { $0.name != preset.name }
        list.append(preset)
        store.set(list.map(\.encoded), for: EnvelopePreferences.presets)
        choose(preset.name)
    }

    /// menu:Modify[Envelope > Delete Preset]: the preset chosen in the pop-up leaves the list (the
    /// defaults come back when none is left).
    func deleteChosen() {
        let chosen = chosenPreset.name
        store.set(presets.filter { $0.name != chosen }.map(\.encoded), for: EnvelopePreferences.presets)
        choose(presets[0].name)
    }

    /// The pop-up: one item per preset, the chosen one checked.
    func presetMenu() -> NSMenu {
        let menu = NSMenu(title: "Envelope Presets")
        let chosen = chosenPreset.name
        for preset in presets {
            let name = preset.name
            menu.addItem(ActionMenuItem(title: name, checked: name == chosen) { [weak self] in self?.choose(name) })
        }
        return menu
    }

    // MARK: Reading the selection

    /// The selected, live envelopes.
    static func envelopes(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { state.nodeKind($0) == .envelope && state.isLive($0) }
    }

    /// The copied path Paste as Envelope takes: the clipboard's first path with a usable outline.
    static func copiedPath(_ editing: ObjectEditing) -> Wiretuner_Doc_V1_PathProps? {
        guard let payload = editing.pasteboard.read().flatMap({ ClipboardPayload(decoding: $0) }) else { return nil }
        return payload.nodes.lazy.compactMap { tree -> Wiretuner_Doc_V1_PathProps? in
            guard case .path(let path)? = tree.props.kind, PasteAsEnvelope.outline(path) != nil else { return nil }
            return path
        }.first
    }

    /// The document's text layout, so Release bakes text as glyph outlines.
    static func textLayout(_ editing: ObjectEditing) -> TextSceneLayout {
        TextSceneLayout(engine: editing.document.textEngine)
    }

    // MARK: Commands

    func createCommand(_ editing: ObjectEditing) -> (any WTModel.Command)? {
        guard editing.hasSelection else { return nil }
        return CreateEnvelope(editing.selectedNodes, preset: chosenPreset, bounds: editing.selection.selectedBounds, layer: editing.activeLayer)
    }

    static func pasteCommand(_ editing: ObjectEditing) -> (any WTModel.Command)? {
        guard editing.hasSelection, let path = copiedPath(editing) else { return nil }
        return PasteAsEnvelope(editing.selectedNodes, path: path, bounds: editing.selection.selectedBounds, layer: editing.activeLayer)
    }

    /// menu:Modify[Envelope > Copy as Path]: the first selected envelope's outline on the
    /// clipboard as a path.
    @discardableResult
    static func copyAsPath(_ editing: ObjectEditing) -> Bool {
        let state = editing.document.state
        guard let envelope = envelopes(editing).first, let props = EnvelopeReading.asPath(envelope, in: state) else { return false }
        let payload = ClipboardPayload(nodes: [NodeTree(props: props)], sourceDocument: editing.document.id)
        editing.pasteboard.write(payload.encoded())
        return true
    }

    /// Whether every selected envelope shows its map (the item's check mark).
    static func showsMap(_ editing: ObjectEditing) -> Bool {
        let state = editing.document.state
        let selected = envelopes(editing)
        return !selected.isEmpty && selected.allSatisfy { state.props($0).envelope.showMap }
    }

    func commands() -> [Command] {
        let target = target
        let modify = ContextMenuCatalog.Menu.modify
        let ids = ContextMenuCatalog.ID.self
        let submenu = Self.submenu
        func path(_ subsection: Int) -> MenuPath { MenuPath(modify, submenu, section: 4, subsection: subsection) }
        func run(_ body: @escaping @MainActor (ObjectEditing) -> Void) -> CommandAction {
            .perform { if let editing = target() { body(editing) } }
        }
        let envelopeSelected = BlendMenu.validation(target) { Self.envelopes($0).isEmpty ? Self.noEnvelope : nil }
        let selected = BlendMenu.validation(target) { $0.hasSelection ? nil : ObjectMenuCommands.noSelection }
        return [
            Command(id: ID.create, title: "Create", menu: path(0), keywords: ["envelope", "warp", "distort"],
                    validation: selected, action: run { editing in
                        if let command = self.createCommand(editing) { _ = BlendMenu.performSelecting(command, editing) }
                    }),
            Command(id: ID.pasteAsEnvelope, title: "Paste as Envelope", menu: path(0), keywords: ["envelope", "warp"],
                    validation: BlendMenu.validation(target) { editing in
                        guard editing.hasSelection else { return ObjectMenuCommands.noSelection }
                        return Self.copiedPath(editing) == nil ? Self.noPath : nil
                    },
                    action: run { editing in if let command = Self.pasteCommand(editing) { _ = BlendMenu.performSelecting(command, editing) } }),
            Command(id: ids.envelopeShowMap, title: "Show Map", menu: path(1), keywords: ["envelope", "mesh"],
                    validation: {
                        guard let editing = target() else { return .disabled(BlendMenu.noDocument) }
                        guard !Self.envelopes(editing).isEmpty else { return .disabled(Self.noEnvelope) }
                        return .checked(Self.showsMap(editing))
                    },
                    action: run { editing in
                        let selected = Self.envelopes(editing)
                        if !selected.isEmpty { editing.perform(ToggleEnvelopeMap(selected, in: editing.document.state)) }
                    }),
            Command(id: ids.envelopeCopyAsPath, title: "Copy as Path", menu: path(1), keywords: ["envelope", "outline"],
                    validation: envelopeSelected, action: run { Self.copyAsPath($0) }),
            Command(id: ids.envelopeRelease, title: "Release", menu: path(1), keywords: ["envelope", "bake", "expand"],
                    validation: envelopeSelected, action: run { editing in
                        let selected = Self.envelopes(editing)
                        if !selected.isEmpty { _ = BlendMenu.performSelecting(ReleaseEnvelope(selected, textLayout: Self.textLayout(editing)), editing) }
                    }),
            Command(id: ids.envelopeRemove, title: "Remove", menu: path(1), keywords: ["envelope", "unwarp"],
                    validation: envelopeSelected, action: run { editing in
                        let selected = Self.envelopes(editing)
                        if !selected.isEmpty { editing.perform(RemoveEnvelope(selected)) }
                    }),
            Command(id: ID.savePreset, title: "Save as Preset…", menu: path(2), keywords: ["envelope", "preset"],
                    validation: envelopeSelected, action: run { editing in self.showSavePreset(editing) }),
            Command(id: ID.deletePreset, title: "Delete Preset", menu: path(2), keywords: ["envelope", "preset"],
                    validation: { .enabled.titled("Delete Preset “\(self.chosenPreset.name)”") },
                    action: .perform { self.deleteChosen() }),
            Command(id: ID.presets, title: "Envelope Presets", keywords: ["envelope", "preset", "toolbar"],
                    action: .perform { self.presentMenu(self.presetMenu()) }),
        ]
    }

    // MARK: Save as Preset

    /// menu:Modify[Envelope > Save as Preset…]: a name for the first selected envelope's shape.
    func showSavePreset(_ editing: ObjectEditing) {
        guard let envelope = Self.envelopes(editing).first else { return }
        let document = editing.document
        sheets.present(EnvelopePresetSheet(name: "Preset \(presets.count + 1)") { [weak self] name in
            if let name, let preset = EnvelopePreset(name: name, envelope: envelope, in: document.state) { self?.save(preset) }
            self?.sheets.dismiss(Self.sheet)
        }, title: "Save Envelope Preset", identifier: Self.sheet)
    }

    func install(commands registry: CommandRegistry) {
        for command in commands() { registry.replace(command) }
        InspectorRegistry.standard.register(EnvelopeSection.section)
    }
}

extension CommandValidation {
    /// The same validation with the item's title replaced.
    func titled(_ title: String) -> CommandValidation {
        var copy = self
        copy.title = title
        return copy
    }
}

/// menu:Modify[Envelope > Save as Preset…]: the preset's name.
struct EnvelopePresetSheet: View {
    let name: String
    let finish: @MainActor (String?) -> Void
    @State private var typed: String?

    static func cancelling(_ finish: @escaping @MainActor (String?) -> Void) -> () -> Void { { finish(nil) } }

    /// btn:[OK]: the typed name, trimmed; nothing is saved without one.
    static func confirming(_ typed: String?, name: String, finish: @escaping @MainActor (String?) -> Void) -> () -> Void {
        {
            let trimmed = (typed ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(trimmed.isEmpty ? nil : trimmed)
        }
    }

    static func text(_ typed: Binding<String?>, name: String) -> Binding<String> {
        Binding(get: { typed.wrappedValue ?? name }, set: { typed.wrappedValue = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Envelope Preset").font(.headline)
            TextField("Name", text: Self.text($typed, name: name)).accessibilityIdentifier("envelope.preset.name")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(finish)).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.confirming(typed, name: name, finish: finish)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("envelope.preset.ok")
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

/// The Object panel's envelope line: "Envelope", "Empty envelope", and "Envelope needs four points"
/// when the outline has too few points to warp (path-effects.adoc, "Read-time normalizations").
enum EnvelopeSection {
    static let section = InspectorSection(id: "envelope", order: 12, kinds: [.envelope]) { panel in
        let state = panel.document.state
        let nodes = panel.objects.map(\.id)
        guard let first = nodes.first else { return nil }
        return AnyView(EnvelopeSectionView(title: EnvelopeReading.title(first, in: state),
                                           needsPoints: nodes.contains { EnvelopeReading.needsPoints($0, in: state) }))
    }
}

struct EnvelopeSectionView: View {
    let title: String
    let needsPoints: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).accessibilityIdentifier("object.envelope.title")
            if needsPoints {
                Text(EnvelopeReading.needsPointsMessage).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("object.envelope.needsPoints")
            }
        }
        .padding(.horizontal)
    }
}
