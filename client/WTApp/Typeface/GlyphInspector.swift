import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

// The Object panel of a typeface window (glyph-grid.adoc, "Opening, renaming and removing glyphs" and "Acting on
// several glyphs"; glyph-editing.adoc, "Side bearings and advance width", "Components", "Anchors"; FONT-010,
// FONT-011, FONT-012, FONT-013 rests): with the grid showing, the *Glyph* section edits the selected glyphs --
// Name and Unicode for one glyph; Kind, Width, LSB, RSB, Mark color, Export and Note for all of them, a value they
// do not share shown mixed; on a glyph tab with no object selected it edits the tab's glyph, with the *Component*
// or *Anchor* section of the component or anchor last pressed on the canvas.  Every control writes one change.

/// The state the panel follows besides the document: the grids' selections and the canvases' picked parts.
@MainActor
@Observable
final class GlyphPanelState {
    private(set) var revision = 0

    func touch() { revision &+= 1 }
}

/// What the glyph sections show and the commands their controls perform, computed on every read.
@MainActor
struct GlyphPanelModel {
    struct ComponentValue: Equatable {
        let id: OpID
        let glyph: OpID
        let source: OpID?
        let sourceName: String
        let status: GlyphComponent.Status
        /// Font units, y up.
        let x: Double
        let y: Double
        /// Percent.
        let scale: Double
        /// Degrees, counter-clockwise as seen (font y up).
        let rotation: Double
    }

    struct AnchorValue: Equatable {
        let id: OpID
        let glyph: OpID
        let name: String
        let x: Double
        let y: Double
        let role: GlyphAnchorRole
        let isDuplicate: Bool
    }

    let document: DocumentHandle
    let glyphs: [Glyph]
    let metrics: [GlyphMetrics]
    let index: GlyphIndex
    let component: ComponentValue?
    let anchor: AnchorValue?
    var open: @MainActor (OpID) -> Void = { _ in }

    init(document: DocumentHandle, glyphs ids: [OpID], picked: GlyphCanvasHandles.Target? = nil) {
        self.document = document
        let state = document.state
        let index = GlyphIndex(state)
        self.index = index
        glyphs = ids.compactMap { index[$0] }
        metrics = glyphs.compactMap { GlyphOutlines.metrics(of: $0.id, in: state) }
        let single = glyphs.count == 1 ? glyphs[0] : nil
        switch picked {
        case .component(let id)?:
            component = single.flatMap { glyph in glyph.components.first { $0.id == id }.map { Self.value(of: $0, in: glyph, index: index) } }
            anchor = nil
        case .anchor(let id)?:
            anchor = single.flatMap { glyph in
                glyph.anchors.first { $0.id == id }.map {
                    AnchorValue(id: $0.id, glyph: glyph.id, name: $0.name, x: $0.position.x, y: -$0.position.y, role: $0.role, isDuplicate: $0.isDuplicate)
                }
            }
            component = nil
        default:
            component = nil
            anchor = nil
        }
    }

    static func value(of component: GlyphComponent, in glyph: Glyph, index: GlyphIndex) -> ComponentValue {
        let t = component.transform
        return ComponentValue(id: component.id, glyph: glyph.id, source: component.source,
                              sourceName: component.source.flatMap { index[$0]?.name } ?? "—", status: component.status,
                              x: t.tx, y: -t.ty, scale: (hypot(t.a, t.b) * 100 * 1_000).rounded() / 1_000,
                              rotation: Self.rounded(-atan2(t.b, t.a) * 180 / .pi))
    }

    static func rounded(_ value: Double) -> Double {
        let result = (value * 1_000).rounded() / 1_000
        return result == 0 ? 0 : result
    }

    var single: Glyph? { glyphs.count == 1 ? glyphs[0] : nil }
    var ids: [OpID] { glyphs.map(\.id) }

    /// "A", or "3 glyphs".
    var title: String { single?.name ?? "\(glyphs.count) glyphs" }

    /// The value every glyph shares, nil when they differ (or there are none).
    static func shared<Value: Equatable>(_ values: [Value]) -> Value? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var kind: GlyphKind? { Self.shared(glyphs.map(\.kind)) }
    var markColor: Int? { Self.shared(glyphs.map(\.markColor)) }
    var export: MixedState { MixedState(glyphs.map { !$0.skipExport }) }
    var note: String? { Self.shared(glyphs.map(\.note)) }
    var width: Double? { Self.shared(metrics.map(\.advanceWidth)) }
    /// A glyph without an outline has no bearings to edit.
    var hasOutline: Bool { !metrics.isEmpty && metrics.allSatisfy { $0.bounds != nil } }
    var left: Double? { hasOutline ? Self.shared(metrics.map(\.leftSideBearing)) : nil }
    var right: Double? { hasOutline ? Self.shared(metrics.map(\.rightSideBearing)) : nil }

    /// The Unicode list of one glyph: "U+00E9 é".
    var codepoints: [(value: UInt32, label: String)] {
        (single?.codepoints ?? []).map { ($0, "\(GlyphGridItem.label(of: $0).codepoint) \(GlyphGridItem.label(of: $0).character)") }
    }

    // MARK: Checks

    static let nameTaken = "Another glyph has that name: "
    static let invalidName = "A name uses letters, digits, periods and underscores and does not start with a digit"
    static let unknownCharacter = "Type a character, a codepoint (U+00E9) or a Unicode name"
    static let codepointTaken = "Another glyph encodes it: "

    /// Why `name` cannot be the single glyph's, nil when it can.
    func problem(renaming name: String) -> String? {
        guard let single else { return nil }
        guard GlyphNaming.isValid(name) else { return Self.invalidName }
        if index.isNameTaken(name, except: single.id), let other = index.glyph(named: name) { return Self.nameTaken + other.name }
        return nil
    }

    /// The codepoint typed as a character, `U+00E9` / `00E9`, or a Unicode character name.
    static func codepoint(from text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.count == 1 { return trimmed.unicodeScalars.first!.value }
        var hex = trimmed.uppercased()
        if hex.hasPrefix("U+") { hex.removeFirst(2) }
        if hex.count >= 4, let value = UInt32(hex, radix: 16), value <= 0x10FFFF { return value }
        let named = "\\N{\(trimmed.uppercased())}".applyingTransform(.toUnicodeName, reverse: true)
        guard let named, named.unicodeScalars.count == 1 else { return nil }
        return named.unicodeScalars.first!.value
    }

    /// Why `text` cannot be added to the single glyph's codepoints, nil when it can.
    func problem(adding text: String) -> String? {
        guard let single else { return nil }
        guard let value = Self.codepoint(from: text) else { return Self.unknownCharacter }
        if let holder = index.holder(of: value, except: single.id) { return Self.codepointTaken + holder.name }
        return nil
    }

    // MARK: Commands (one change each)

    func rename(_ name: String) -> (any WTModel.Command)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let single, trimmed != single.name, problem(renaming: trimmed) == nil else { return nil }
        return RenameGlyph(single.id, to: trimmed)
    }

    func addCodepoint(_ text: String) -> (any WTModel.Command)? {
        guard let single, problem(adding: text) == nil, let value = Self.codepoint(from: text), !single.codepoints.contains(value) else { return nil }
        return SetGlyphCodepoints(single.id, add: [value])
    }

    func removeCodepoint(_ value: UInt32) -> (any WTModel.Command)? {
        single.map { SetGlyphCodepoints($0.id, remove: [value]) }
    }

    func setKind(_ kind: GlyphKind) -> (any WTModel.Command)? { glyphs.isEmpty ? nil : SetGlyphAttributes(ids, kind: kind) }
    func setMarkColor(_ color: Int) -> (any WTModel.Command)? { glyphs.isEmpty ? nil : SetGlyphAttributes(ids, markColor: color) }
    func setExport(_ export: Bool) -> (any WTModel.Command)? { glyphs.isEmpty ? nil : SetGlyphAttributes(ids, export: export) }
    func setNote(_ note: String) -> (any WTModel.Command)? { glyphs.isEmpty ? nil : SetGlyphAttributes(ids, note: note) }

    func setWidth(_ width: Double) -> (any WTModel.Command)? {
        glyphs.isEmpty || width < 0 ? nil : AdjustGlyphMetrics(ids, .width, .set(width))
    }

    /// Typing an LSB moves the artwork.
    func setLeft(_ value: Double) -> (any WTModel.Command)? { hasOutline ? AdjustGlyphMetrics(ids, .left, .set(value)) : nil }

    /// Typing an RSB changes the width.
    func setRight(_ value: Double) -> (any WTModel.Command)? { hasOutline ? AdjustGlyphMetrics(ids, .right, .set(value)) : nil }

    /// The picked component placed at font-unit (`x`, `y`), scaled `scale` percent and rotated `rotation`
    /// degrees (each nil: as it is).
    func placeComponent(x: Double? = nil, y: Double? = nil, scale: Double? = nil, rotation: Double? = nil) -> (any WTModel.Command)? {
        guard let component else { return nil }
        let factor = (scale ?? component.scale) / 100
        guard factor.isFinite, factor > 0 else { return nil }
        let angle = -(rotation ?? component.rotation) * .pi / 180
        var transform = WTGeometry.AffineTransform.scale(factor).concatenating(.rotation(radians: angle))
        transform.tx = x ?? component.x
        transform.ty = -(y ?? component.y)
        return SetComponentTransform(component.id, of: component.glyph, to: transform)
    }

    func decomposeComponent() -> (any WTModel.Command)? {
        component.map { DecomposeComponents($0.glyph, components: [$0.id]) }
    }

    func renameAnchor(_ name: String) -> (any WTModel.Command)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let anchor, trimmed != anchor.name, !trimmed.isEmpty else { return nil }
        return EditAnchor(anchor.id, of: anchor.glyph, .rename(trimmed))
    }

    /// The anchor at font-unit (`x`, `y`) (each nil: as it is).
    func moveAnchor(x: Double? = nil, y: Double? = nil) -> (any WTModel.Command)? {
        guard let anchor else { return nil }
        return EditAnchor(anchor.id, of: anchor.glyph, .move(Point(x: x ?? anchor.x, y: -(y ?? anchor.y))))
    }

    func setAnchorRole(_ role: GlyphAnchorRole) -> (any WTModel.Command)? {
        guard let anchor, anchor.role != role else { return nil }
        return EditAnchor(anchor.id, of: anchor.glyph, .role(role))
    }

    func removeAnchor() -> (any WTModel.Command)? {
        anchor.map { EditAnchor($0.id, of: $0.glyph, .remove) }
    }

    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { document.perform($0) }
    }
}

// MARK: Views

/// The typeface Object panel: the Glyph section, then the Component or Anchor section.
struct GlyphPanelView: View {
    let model: GlyphPanelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.glyphs.isEmpty {
                    Text("No glyph selected").foregroundStyle(.secondary).padding(.horizontal).accessibilityIdentifier("glyph.none")
                } else {
                    Text(model.title).font(.headline).padding(.horizontal).accessibilityIdentifier("glyph.title")
                    GlyphSectionView(model: model)
                }
                if let component = model.component {
                    Divider()
                    ComponentSectionView(model: model, component: component)
                }
                if let anchor = model.anchor {
                    Divider()
                    AnchorSectionView(model: model, anchor: anchor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("object.glyph")
    }
}

/// The Glyph section.
struct GlyphSectionView: View {
    let model: GlyphPanelModel
    @State private var problem: String?
    @State private var newCodepoint = ""

    static let kinds: [(GlyphKind, String)] = GlyphKind.allCases.map { ($0, TypefaceFeatures.title(of: $0)) }

    /// A binding over one of the section's pickers: reads the shared value, writes one change.
    static func binding<Value>(_ value: Value?, _ write: @escaping (Value) -> (any WTModel.Command)?, _ model: GlyphPanelModel) -> Binding<Value?> {
        Binding(get: { value }, set: { if let new = $0 { model.perform(write(new)) } })
    }

    /// The Name field: renames (one change) and answers the problem to show, if any.
    static func commitName(_ name: String, _ model: GlyphPanelModel) -> String? {
        let problem = model.problem(renaming: name.trimmingCharacters(in: .whitespaces))
        model.perform(model.rename(name))
        return problem
    }

    /// btn:[+] of the Unicode list: adds the codepoint (one change) and answers the problem to show, if any.
    static func commitCodepoint(_ text: String, _ model: GlyphPanelModel) -> String? {
        let problem = model.problem(adding: text)
        model.perform(model.addCodepoint(text))
        return problem
    }

    var body: some View {
        Form {
            if let single = model.single {
                CommitTextField(title: "Name", value: single.name, identifier: "glyph.name") { problem = Self.commitName($0, model) }
                LabeledContent("Unicode") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.codepoints, id: \.value) { entry in
                            HStack {
                                Text(entry.label).font(.caption.monospacedDigit())
                                Button("−") { model.perform(model.removeCodepoint(entry.value)) }.buttonStyle(.borderless)
                                    .accessibilityIdentifier("glyph.unicode.remove")
                            }
                        }
                        HStack {
                            TextField("Character or U+", text: $newCodepoint).accessibilityIdentifier("glyph.unicode.field")
                            Button("+") {
                                problem = Self.commitCodepoint(newCodepoint, model)
                                if problem == nil { newCodepoint = "" }
                            }
                            .accessibilityIdentifier("glyph.unicode.add")
                        }
                    }
                }
            }
            Picker("Kind", selection: Self.binding(model.kind, model.setKind, model)) {
                ForEach(Self.kinds, id: \.0) { kind, title in Text(title).tag(Optional(kind)) }
            }
            .accessibilityIdentifier("glyph.kind")
            CommitField(title: "Width", value: model.width, identifier: "glyph.width") { model.perform(model.setWidth($0)) }
            CommitField(title: "LSB", value: model.left, identifier: "glyph.lsb") { model.perform(model.setLeft($0)) }.disabled(!model.hasOutline)
            CommitField(title: "RSB", value: model.right, identifier: "glyph.rsb") { model.perform(model.setRight($0)) }.disabled(!model.hasOutline)
            Picker("Mark color", selection: Self.binding(model.markColor, model.setMarkColor, model)) {
                ForEach(Array(TypefaceFeatures.markColorTitles.enumerated()), id: \.offset) { color, title in Text(title).tag(Optional(color)) }
            }
            .accessibilityIdentifier("glyph.markColor")
            Toggle("Export", isOn: Binding(get: { model.export.isOn }, set: { model.perform(model.setExport($0)) }))
                .accessibilityIdentifier("glyph.export").accessibilityValue(PathSectionView.accessibilityValue(model.export))
            CommitTextField(title: "Note", value: model.note, identifier: "glyph.note") { model.perform(model.setNote($0)) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("glyph.problem") }
        }
        .padding(.horizontal)
    }
}

/// The Component section: the source (click to open it), position, scale, rotation, Decompose.
struct ComponentSectionView: View {
    let model: GlyphPanelModel
    let component: GlyphPanelModel.ComponentValue

    var body: some View {
        Form {
            Text("Component").font(.subheadline)
            LabeledContent("Source") {
                Button(component.status == .resolved ? component.sourceName : "\(component.sourceName) (\(GlyphPartsModel.label(of: component.status)))") {
                    Self.openSource(component, model)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("component.source")
            }
            CommitField(title: "X", value: component.x, identifier: "component.x") { model.perform(model.placeComponent(x: $0)) }
            CommitField(title: "Y", value: component.y, identifier: "component.y") { model.perform(model.placeComponent(y: $0)) }
            CommitField(title: "Scale %", value: component.scale, identifier: "component.scale") { model.perform(model.placeComponent(scale: $0)) }
            CommitField(title: "Rotation", value: component.rotation, identifier: "component.rotation") { model.perform(model.placeComponent(rotation: $0)) }
            Button("Decompose") { model.perform(model.decomposeComponent()) }.accessibilityIdentifier("component.decompose")
        }
        .padding(.horizontal)
    }
}

extension ComponentSectionView {
    /// The source link: opens a resolved source.
    static func openSource(_ component: GlyphPanelModel.ComponentValue, _ model: GlyphPanelModel) {
        if let source = component.source, component.status == .resolved { model.open(source) }
    }
}

/// The Anchor section: X, Y, Name, Role, Remove.
struct AnchorSectionView: View {
    let model: GlyphPanelModel
    let anchor: GlyphPanelModel.AnchorValue

    var body: some View {
        Form {
            Text("Anchor").font(.subheadline)
            CommitField(title: "X", value: anchor.x, identifier: "anchor.x") { model.perform(model.moveAnchor(x: $0)) }
            CommitField(title: "Y", value: anchor.y, identifier: "anchor.y") { model.perform(model.moveAnchor(y: $0)) }
            CommitTextField(title: "Name", value: anchor.name, identifier: "anchor.name") { model.perform(model.renameAnchor($0)) }
            Picker("Role", selection: Binding(get: { anchor.role }, set: { model.perform(model.setAnchorRole($0)) })) {
                Text("Base").tag(GlyphAnchorRole.base)
                Text("Mark").tag(GlyphAnchorRole.mark)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("anchor.role")
            if anchor.isDuplicate { Text("Another anchor has this name").font(.caption).foregroundStyle(.red) }
            Button("Remove Anchor") { model.perform(model.removeAnchor()) }.accessibilityIdentifier("anchor.remove")
        }
        .padding(.horizontal)
    }
}

// MARK: Registration, sheets and shortcuts

extension TypefaceFeatures {
    enum PanelID {
        static let addComponent: CommandID = "glyph.addComponent"
        static let addAnchor: CommandID = "glyph.addAnchor"
        static let addAnchorHere: CommandID = "glyph.addAnchorHere"
    }

    /// The Object panel's glyph sections for `selection`, nil when the usual sections apply (not a typeface, or
    /// objects selected on a glyph tab).
    func glyphPanel(for selection: ActiveSelection?) -> GlyphPanelModel? {
        guard let selection, let document = selection.document else { return nil }
        _ = glyphPanelState.revision
        _ = document.model?.revision
        guard let mode = modes.values.first(where: { $0.controller.documentHandle === document }) else { return nil }
        if let glyph = document.glyphCanvasNode {
            guard selection.model?.isEmpty ?? true else { return nil }
            var model = GlyphPanelModel(document: document, glyphs: [glyph], picked: mode.glyphHandles?.picked)
            model.open = { [weak self, weak mode] glyph in if let mode { self?.openGlyph(glyph, from: mode.controller) } }
            return model
        }
        guard DocumentKind.layout(document.state) == .typeface, mode.view == .glyphs, let grid = mode.grid else { return nil }
        return GlyphPanelModel(document: document, glyphs: grid.model.selection)
    }

    /// The panel's glyph sections take the Object panel's place in typeface windows.
    func registerGlyphPanel(in registry: InspectorRegistry = .standard) {
        registry.registerReplacement(id: "glyph") { [weak self] selection in
            self?.glyphPanel(for: selection).map { AnyView(GlyphPanelView(model: $0)) }
        }
    }

    func glyphPanelCommands() -> [Command] {
        let window = self.window
        let glyphMenu = Menu.glyph
        let needsGlyphCanvas: @MainActor @Sendable () -> CommandValidation = {
            window()?.documentHandle.glyphCanvasNode == nil ? .disabled(Self.noGlyphCanvas) : .enabled
        }
        return [
            Command(id: PanelID.addComponent, title: "Add Component…", menu: MenuPath(glyphMenu, section: 1), keywords: ["component", "reference", "accent"],
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in presentAddComponent() }),
            Command(id: PanelID.addAnchor, title: "Add Anchor…", menu: MenuPath(glyphMenu, section: 1), keywords: ["anchor", "mark", "accent"],
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in presentAddAnchor() }),
            Command(id: PanelID.addAnchorHere, title: "Add Anchor Here", contexts: [.pasteboard, .page], keywords: ["anchor"],
                    validation: needsGlyphCanvas, action: .perform { [unowned self] in presentAddAnchor(at: window()?.contextPoint) }),
        ]
    }

    /// menu:Glyph[Add Component…] on a glyph tab.
    @discardableResult
    func presentAddComponent() -> NSWindow? {
        guard let controller = window(), let glyph = controller.documentHandle.glyphCanvasNode else { return nil }
        let model = AddComponentModel(document: controller.documentHandle, glyph: glyph, perform: controller.typefacePerform)
        return present("sheet.addComponent", on: controller.window) { close in AddComponentSheet(model: model, close: close) }
    }

    /// menu:Glyph[Add Anchor…], or *Add Anchor Here* at `point` (pasteboard space) on a glyph tab.
    @discardableResult
    func presentAddAnchor(at point: Point? = nil) -> NSWindow? {
        guard let controller = window(), let glyph = controller.documentHandle.glyphCanvasNode else { return nil }
        let model = AddAnchorModel(document: controller.documentHandle, glyph: glyph, at: point.map { Point(x: $0.x.rounded(), y: $0.y.rounded()) } ?? .zero,
                                   perform: controller.typefacePerform)
        return present("sheet.addAnchor", on: controller.window) { close in AddAnchorSheet(model: model, close: close) }
    }

    /// The glyph-tab shortcuts the spec names that the default set gives other commands (glyph-editing.adoc):
    /// kbd:[Cmd+Shift+R] *Add Component…* and kbd:[Cmd+Shift+A] *Add Anchor…* -- taken on a glyph tab before the
    /// menu sees them.  Whether the key was one of them (and so handled).
    func glyphTabKey(_ characters: String, modifiers: NSEvent.ModifierFlags, in controller: DocumentWindowController) -> Bool {
        guard controller.documentHandle.glyphCanvasNode != nil, !controller.isEditingText,
              modifiers.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else { return false }
        switch characters.lowercased() {
        case "r": return presentAddComponent() != nil
        case "a": return presentAddAnchor() != nil
        default: return false
        }
    }
}

/// A view in a glyph tab's window that takes the glyph-tab shortcuts before the menu bar
/// (`TypefaceFeatures.glyphTabKey`).
final class GlyphTabKeyView: NSView {
    var handle: @MainActor (String, NSEvent.ModifierFlags) -> Bool = { _, _ in false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let characters = event.charactersIgnoringModifiers, handle(characters, event.modifierFlags) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// menu:Glyph[Add Component…] (glyph-editing.adoc, "Components"): a glyph's name or character; the sheet shows
/// what it found.  btn:[Add] places it by anchors when a base/mark pair matches, else at the origin.
@MainActor
@Observable
final class AddComponentModel {
    @ObservationIgnored let document: DocumentHandle
    let glyph: OpID
    @ObservationIgnored let perform: TypefacePerform
    var text = ""
    private(set) var problem: String?

    init(document: DocumentHandle, glyph: OpID, perform: @escaping TypefacePerform) {
        self.document = document
        self.glyph = glyph
        self.perform = perform
    }

    static let loop = "A glyph cannot contain itself"

    /// The glyph `text` names: by name, else by the character it types.
    var found: Glyph? {
        let index = GlyphIndex(document.state)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let byName = index.glyph(named: trimmed) { return byName }
        return GlyphPanelModel.codepoint(from: trimmed).flatMap { index.glyph(for: $0) }
    }

    /// What the sheet shows under the field.
    var summary: String {
        guard let found else { return text.isEmpty ? "" : GlyphPartsModel.unknownGlyph }
        return found.codepoints.first.map { "\(found.name)  \(GlyphGridItem.label(of: $0).codepoint)" } ?? found.name
    }

    /// btn:[Add]; false (with `problem`) when nothing is found or it would loop.
    func add() -> Bool {
        guard let found else {
            problem = GlyphPartsModel.unknownGlyph
            return false
        }
        guard found.id != glyph else {
            problem = Self.loop
            return false
        }
        problem = nil
        return perform(AddComponent(found.id, to: glyph)) != nil
    }
}

struct AddComponentSheet: View {
    @Bindable var model: AddComponentModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Component").font(.headline)
            TextField("Glyph name or character", text: $model.text).accessibilityIdentifier("addComponent.name")
            Text(model.summary).font(.caption).foregroundStyle(.secondary)
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: SheetButtons.closing(model.add, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("addComponent.add")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// menu:Glyph[Add Anchor…] and *Add Anchor Here* (glyph-editing.adoc, "Anchors"): a name, the role (from the
/// underscore convention unless chosen) and the position in font units.
@MainActor
@Observable
final class AddAnchorModel {
    enum Role: Hashable, CaseIterable {
        case automatic, base, mark

        var title: String {
            switch self {
            case .automatic: "From name"
            case .base: "Base"
            case .mark: "Mark"
            }
        }
    }

    @ObservationIgnored let document: DocumentHandle
    let glyph: OpID
    @ObservationIgnored let perform: TypefacePerform
    var name = "top"
    var role: Role = .automatic
    var x: String
    /// Font y (up).
    var y: String
    private(set) var problem: String?

    /// `position` is glyph-canvas space (y down).
    init(document: DocumentHandle, glyph: OpID, at position: Point, perform: @escaping TypefacePerform) {
        self.document = document
        self.glyph = glyph
        self.perform = perform
        x = FontUnits.format(position.x)
        y = FontUnits.format(position.y == 0 ? 0 : -position.y)
    }

    /// btn:[Add]; false (with `problem`) for a bad name or position.
    func add() -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 63, trimmed.range(of: "^[A-Za-z0-9._]+$", options: .regularExpression) != nil,
              let x = FontUnits.parse(x), let y = FontUnits.parse(y) else {
            problem = GlyphPartsModel.invalidAnchor
            return false
        }
        problem = nil
        let explicit: GlyphAnchorRole? = switch role {
        case .automatic: nil
        case .base: .base
        case .mark: .mark
        }
        return perform(AddAnchor(trimmed, at: Point(x: x, y: -y), to: glyph, role: explicit)) != nil
    }
}

struct AddAnchorSheet: View {
    @Bindable var model: AddAnchorModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Anchor").font(.headline)
            TextField("Name", text: $model.name).accessibilityIdentifier("addAnchor.name")
            Picker("Role", selection: $model.role) {
                ForEach(AddAnchorModel.Role.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                TextField("X", text: $model.x).accessibilityIdentifier("addAnchor.x")
                TextField("Y", text: $model.y).accessibilityIdentifier("addAnchor.y")
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: SheetButtons.closing(model.add, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("addAnchor.add")
            }
        }
        .padding()
        .frame(width: 320)
    }
}
