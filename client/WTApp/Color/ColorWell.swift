import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// What a colour control shows and offers (applying-color.adoc, "The Object panel's color
/// controls"; COLOR-011): the chip (a colour, *None*'s red diagonal or the mixed question mark),
/// the caption, the value field -- an unnamed colour's components in its own space, a named
/// colour's name read-only -- and the pop-up menu: *None*, every swatch (tints indented), *Add to
/// Swatches…* for an unnamed colour, *Detach* for a named one, and *Restore "<name>"* when the
/// colour's swatch has been removed.
struct ColorWellModel {
    enum Chip: Equatable {
        case color(RenderColor)
        case none
        case mixed
    }

    struct Item: Identifiable, Hashable {
        enum Kind: Hashable {
            case none
            case swatch(OpID)
            case addToSwatches
            case detach
            case restore(OpID)
        }

        let kind: Kind
        let title: String
        var depth = 0
        var id: Kind { kind }
    }

    /// The reference, or nil when the targets differ.
    let ref: Wiretuner_Doc_V1_ColorRef?
    let list: SwatchList
    /// The document the control edits (a drag carries it).
    let documentID: String

    init(ref: Wiretuner_Doc_V1_ColorRef?, list: SwatchList, documentID: String = "") {
        self.ref = ref
        self.list = list
        self.documentID = documentID
    }

    init(ref: Wiretuner_Doc_V1_ColorRef?, state: EngineState, documentID: String = "") {
        self.init(ref: ref, list: SwatchList(state), documentID: documentID)
    }

    var isNone: Bool {
        if case .none? = ref?.ref { return true }
        return false
    }

    /// The colour shown; nil for *None* or mixed.
    var resolved: RenderColor? { ref.flatMap(list.resolver.color) }

    var chip: Chip {
        guard ref != nil else { return .mixed }
        return resolved.map(Chip.color) ?? .none
    }

    /// The live swatch a named colour (or a named tint) refers to.
    var swatch: Swatch? {
        guard let ref, case .swatch? = ref.ref, let id = ColorResolver.swatch(of: ref) else { return nil }
        return list[id]
    }

    /// The removed swatch a dangling reference names, with its stored name.
    var removedSwatch: (id: OpID, name: String)? {
        guard let ref, list.resolver.isDangling(ref), let id = ColorResolver.swatch(of: ref) else { return nil }
        let name = list.resolver.props(id)?.common.name ?? ""
        return (id, name.isEmpty ? "Color" : name)
    }

    var caption: String {
        guard ref != nil else { return "Mixed" }
        if isNone { return "None" }
        return swatch?.name ?? ""
    }

    /// Whether the value field edits the colour (an unnamed colour); a named colour's field is
    /// read-only.
    var isValueEditable: Bool { ref != nil && swatch == nil && !isNone }

    /// The value field's text.
    var valueText: String {
        if let swatch { return swatch.name }
        return isValueEditable ? resolved.map(ColorText.field) ?? "" : ""
    }

    var menu: [Item] {
        var items = [Item(kind: .none, title: "None")]
        items += list.swatches.map { Item(kind: .swatch($0.id), title: $0.name, depth: $0.depth) }
        if isValueEditable { items.append(Item(kind: .addToSwatches, title: "Add to Swatches…")) }
        if swatch != nil { items.append(Item(kind: .detach, title: "Detach")) }
        if let removed = removedSwatch { items.append(Item(kind: .restore(removed.id), title: "Restore \"\(removed.name)\"")) }
        return items
    }

    /// The reference choosing `item` writes; nil for the items that do something else.
    func reference(for item: Item.Kind) -> Wiretuner_Doc_V1_ColorRef? {
        switch item {
        case .none: return ColorResolver.none
        case .swatch(let id): return list.resolver.reference(to: id)
        case .detach: return resolved.map(ColorResolver.inline)
        case .addToSwatches, .restore: return nil
        }
    }

    /// The value field's entry as an unnamed colour (any form the Mixer's field accepts).
    static func parse(_ text: String) -> Wiretuner_Doc_V1_ColorRef? {
        ColorText.parse(text).map(ColorResolver.inline)
    }

    /// What dragging the chip carries; nil for mixed.
    var dragPayload: ColorRefPasteboard? {
        ref.map { ColorRefPasteboard(ref: $0, list: list, document: documentID) }
    }
}

/// What a colour control does with a choice: `commit` writes the reference to the targets;
/// `document` performs *Restore* and *Add to Swatches…*.
@MainActor
struct ColorWellActions {
    var document: DocumentHandle?
    var defaultSpace: RenderColor.Space = .displayP3
    let commit: (Wiretuner_Doc_V1_ColorRef) -> Void

    /// Runs `item` for the control showing `model`.  *Add to Swatches…* adds the colour under its
    /// default name, then points the targets at the new swatch.
    @discardableResult
    func run(_ item: ColorWellModel.Item.Kind, model: ColorWellModel) -> Task<Void, Never>? {
        if let ref = model.reference(for: item) {
            commit(ref)
            return nil
        }
        guard let document else { return nil }
        switch item {
        case .restore(let id):
            let task = document.perform(RestoreSwatches([id]))
            return Task { _ = await task.value }
        default:
            guard let color = model.resolved else { return nil }
            let adding = document.perform(AddSwatch(color))
            return Task { @MainActor in
                if let change = await adding.value {
                    commit(SwatchList(document.state).resolver.reference(to: ColorWellActions.created(by: change)))
                }
            }
        }
    }

    /// The first node `change` created.
    static func created(by change: Wiretuner_Doc_V1_Change) -> OpID {
        OpID(counter: change.startCounter, replica: change.replica)
    }

    /// A colour dropped on the control, read from the drag pasteboard: the reference in this
    /// document (a swatch from another document is imported first, `ColorDrop`).  False when
    /// the drag carries no colour.
    @discardableResult
    func drop(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: defaultSpace) else { return false }
        guard let document, ColorDrop.needsImport(payload, into: document.id) else {
            commit(payload.reference(in: document?.state ?? EngineState(), document: document?.id ?? ""))
            return true
        }
        Task { @MainActor in commit(await ColorDrop.reference(for: payload, in: document)) }
        return true
    }
}

/// Drops of colours from another document (exporting-colors.adoc, "Cross-document drags";
/// COLOR-019): a swatch arrives with its tints as a library and is created in the destination
/// (fresh node ids, the clash rule of `ImportLibraryColors`), then referenced.
@MainActor
enum ColorDrop {
    /// The `library` origin recorded on swatches dragged in from document `id`.
    static func origin(_ id: String) -> String { "document:\(id)" }

    /// Whether a drop of `payload` in document `id` creates swatches first: a swatch dragged
    /// from another document.
    static func needsImport(_ payload: ColorRefPasteboard, into id: String) -> Bool {
        payload.document != id && payload.library?.colors.isEmpty == false
    }

    /// The reference a drop of `payload` writes in `document`.
    static func reference(for payload: ColorRefPasteboard, in document: DocumentHandle) async -> Wiretuner_Doc_V1_ColorRef {
        if needsImport(payload, into: document.id), let library = payload.library, let key = library.colors.first?.key {
            let origin = origin(payload.document)
            _ = await document.perform(ImportLibraryColors(library, origin: origin, group: library.colors[0].group)).value
            let list = SwatchList(document.state)
            if let swatch = list.swatches.first(where: { $0.library == origin && $0.libraryKey == key }) {
                return list.resolver.reference(to: swatch.id)
            }
        }
        return payload.reference(in: document.state, document: document.id)
    }
}

/// A colour chip: the colour, *None* (white with a red diagonal) or mixed (a question mark).
struct ColorChipView: View {
    let chip: ColorWellModel.Chip
    var size = CGSize(width: 22, height: 16)

    static func swiftUIColor(_ color: RenderColor) -> SwiftUI.Color {
        SwiftUI.Color(cgColor: color.cgColor)
    }

    var body: some View {
        ZStack {
            switch chip {
            case .color(let color):
                Rectangle().fill(Self.swiftUIColor(color))
            case .none:
                Rectangle().fill(SwiftUI.Color.white)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(SwiftUI.Color.red, lineWidth: 1.5)
            case .mixed:
                Rectangle().fill(SwiftUI.Color.gray.opacity(0.2))
                Text("?").font(.caption.bold())
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(Rectangle().stroke(SwiftUI.Color.secondary.opacity(0.6), lineWidth: 1))
    }
}

/// Which view the pop-up palette shows (applying-color.adoc, "The color wells"); remembered
/// across relaunch.
enum PaletteKind: String, CaseIterable, Identifiable {
    case swatches, cubes
    var id: String { rawValue }
    var title: String { self == .swatches ? "Swatches" : "Color Cubes" }

    static let defaultsKey = "wt.colors.paletteView"
}

/// The 216 web-safe colours of the *Color Cubes* view (sRGB by definition).
enum ColorCubes {
    static let colors: [RenderColor] = (0..<216).map { index in
        let steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
        return RenderColor(red: steps[index / 36], green: steps[(index / 6) % 6], blue: steps[index % 6])
    }
}

/// The pop-up palette: *None* and the document's swatches (tints included), or the colour
/// cubes and a hex field.  A pick writes the colour at once.
struct ColorPaletteView: View {
    let model: ColorWellModel
    let choose: (Wiretuner_Doc_V1_ColorRef) -> Void
    @AppStorage(PaletteKind.defaultsKey) private var kind = PaletteKind.swatches.rawValue
    @State private var hex = ""

    static let columns = Array(repeating: GridItem(.fixed(18), spacing: 3), count: 12)

    /// The action of a chip.
    static func choosing(_ ref: Wiretuner_Doc_V1_ColorRef, _ choose: @escaping (Wiretuner_Doc_V1_ColorRef) -> Void) -> () -> Void {
        { choose(ref) }
    }

    /// The hex field's commit: an sRGB colour, nothing for text that is not a colour.
    static func submitting(_ text: Binding<String>, _ choose: @escaping (Wiretuner_Doc_V1_ColorRef) -> Void) -> () -> Void {
        {
            if let color = ColorText.parse(text.wrappedValue.hasPrefix("#") ? text.wrappedValue : "#" + text.wrappedValue) {
                choose(ColorResolver.inline(color))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("View", selection: $kind) {
                ForEach(PaletteKind.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("color-palette.view")
            LazyVGrid(columns: Self.columns, spacing: 3) {
                if kind == PaletteKind.cubes.rawValue {
                    ForEach(Array(ColorCubes.colors.enumerated()), id: \.offset) { index, color in
                        Button(action: Self.choosing(ColorResolver.inline(color), choose)) { ColorChipView(chip: .color(color), size: CGSize(width: 18, height: 18)) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("color-palette.cube.\(index)")
                    }
                } else {
                    Button(action: Self.choosing(ColorResolver.none, choose)) { ColorChipView(chip: .none, size: CGSize(width: 18, height: 18)) }
                        .buttonStyle(.plain)
                        .help("None")
                        .accessibilityIdentifier("color-palette.none")
                    ForEach(model.list.swatches) { swatch in
                        Button(action: Self.choosing(model.list.resolver.reference(to: swatch.id), choose)) {
                            ColorChipView(chip: .color(swatch.color), size: CGSize(width: 18, height: 18))
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityIdentifier("color-palette.swatch.\(swatch.name)")
                    }
                }
            }
            if kind == PaletteKind.cubes.rawValue {
                TextField("Hex", text: $hex, prompt: Text("#RRGGBB"))
                    .onSubmit(Self.submitting($hex, choose))
                    .accessibilityIdentifier("color-palette.hex")
            }
        }
        .padding(10)
        .frame(width: 270)
    }
}

/// The per-control state: whether the palette is open.
@MainActor
@Observable
final class ColorWellState {
    var showsPalette = false

    func togglePalette() {
        showsPalette.toggle()
    }
}

/// The colour control of the Object panel's editors and the panels (COLOR-011): the chip (click
/// for the palette, drag it out, drop a colour on it), the pop-up menu and the value field.
struct ColorWellView: View {
    let title: String
    let model: ColorWellModel
    let actions: ColorWellActions
    let identifier: String
    @State private var state = ColorWellState()
    @State private var text = ""

    /// A pop-up item's action.
    static func running(_ item: ColorWellModel.Item.Kind, _ model: ColorWellModel, _ actions: ColorWellActions) -> () -> Void {
        { actions.run(item, model: model) }
    }

    /// The palette's pick: writes the colour and closes the palette.
    static func picking(_ actions: ColorWellActions, _ state: ColorWellState) -> (Wiretuner_Doc_V1_ColorRef) -> Void {
        { ref in
            actions.commit(ref)
            state.showsPalette = false
        }
    }

    /// The value field's commit: an entry that is a colour writes it; anything else is ignored.
    static func submitting(_ text: Binding<String>, _ actions: ColorWellActions) -> () -> Void {
        { ColorWellModel.parse(text.wrappedValue).map(actions.commit) }
    }

    /// The chip's drag.
    static func dragging(_ model: ColorWellModel) -> () -> NSItemProvider {
        { model.dragPayload.map(ColorDrag.itemProvider) ?? NSItemProvider() }
    }

    /// A drop on the chip.
    static func dropping(_ actions: ColorWellActions, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in actions.drop(from: pasteboard) }
    }

    /// The field's text follows the colour when it changes (not while the user types).
    static func syncing(_ text: Binding<String>, _ model: ColorWellModel) -> () -> Void {
        { text.wrappedValue = model.valueText }
    }

    /// The pop-up palette the chip opens.
    func palette() -> ColorPaletteView {
        ColorPaletteView(model: model, choose: Self.picking(actions, state))
    }

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Text(title)
            Button(action: state.togglePalette) { ColorChipView(chip: model.chip) }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(model.caption)
                .popover(isPresented: $state.showsPalette, content: palette)
                .onDrag(Self.dragging(model))
                .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(actions))
            Menu {
                ForEach(model.menu) { item in
                    Button(String(repeating: "   ", count: item.depth) + item.title, action: Self.running(item.kind, model, actions))
                }
            } label: {
                Text(model.caption.isEmpty ? "Color" : model.caption)
            }
            .fixedSize()
            .accessibilityIdentifier("\(identifier).menu")
            TextField("Value", text: $text)
                .disabled(!model.isValueEditable)
                .onSubmit(Self.submitting($text, actions))
                .onAppear(perform: Self.syncing($text, model))
                .onChange(of: model.valueText, Self.syncing($text, model))
                .frame(minWidth: 90)
                .accessibilityIdentifier("\(identifier).value")
        }
    }
}
