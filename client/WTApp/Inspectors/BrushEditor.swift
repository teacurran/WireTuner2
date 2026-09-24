import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// One brush variation as the Edit Brush sheet edits it (stroke-attributes.adoc, "The Edit Brush
/// sheet"): *Spacing*, *Angle*, *Offset* or *Scaling* with its modes and range.
enum BrushVariationKind: String, CaseIterable, Identifiable {
    case spacing = "Spacing"
    case angle = "Angle"
    case offset = "Offset"
    case scaling = "Scaling"

    var id: String { rawValue }

    /// The *Fixed* value's range.
    var range: ClosedRange<Double> {
        switch self {
        case .spacing, .scaling: 1...200
        case .angle: 0...359
        case .offset: -200...200
        }
    }

    /// The modes offered: *Flare* only for Spray offsets and Paint scaling.
    func modes(paint: Bool) -> [(Wiretuner_Doc_V1_VariationMode, String)] {
        var modes: [(Wiretuner_Doc_V1_VariationMode, String)] = [(.fixed, "Fixed"), (.random, "Random"), (.variable, "Variable")]
        if (self == .offset && !paint) || (self == .scaling && paint) { modes.append((.flare, "Flare")) }
        return modes
    }
}

/// The Edit Brush sheet's draft (ATTR-009): the name, the symbols in stacking order, the mode and
/// count, the switches and the four variations, with a live preview of the brush on a sample path.
/// It edits a brush in use (btn:[OK] then asks *Change* or *Create*) or makes one from the
/// selection (*Create Brush…*, with *Copy* or *Convert*).
@MainActor
@Observable
final class BrushEditorModel {
    /// What the sheet makes.
    enum Purpose: Equatable {
        /// Editing brush `id`; *Create* applies the copy to `strokes`.
        case edit(OpID, strokes: [BrushStrokeRow])
        /// A new brush from the selected objects.
        case create([OpID])
    }

    /// What btn:[OK] leads to.
    enum Outcome {
        case perform(any WTModel.Command)
        /// The brush is in use: *Change* every stroke or *Create* a copy for the selected ones.
        case askChangeOrCreate
    }

    let document: DocumentHandle
    let purpose: Purpose
    var name: String
    var props: Wiretuner_Doc_V1_BrushProps
    var symbols: [OpID]
    /// *Copy* or *Convert* (Create Brush only).
    var source = BrushSymbolSource.copy
    /// The symbol selected in the list.
    var selectedSymbol: OpID?

    init(document: DocumentHandle, purpose: Purpose) {
        self.document = document
        self.purpose = purpose
        switch purpose {
        case .edit(let brush, _):
            let entry = Brushes.list(document.state).first { $0.id == brush }
            name = entry?.name ?? ""
            props = entry?.props ?? BrushDefinition.defaultProps
            symbols = entry?.symbols ?? []
        case .create:
            name = "Brush"
            props = BrushDefinition.defaultProps
            symbols = []
        }
        props.symbols = []
    }

    var isCreating: Bool { if case .create = purpose { true } else { false } }
    var definition: BrushDefinition {
        var props = props
        props.common.name = name
        return BrushDefinition(props: props, symbols: symbols)
    }

    // MARK: Symbols

    /// Every live symbol of the document with its name (btn:[+] adds one).
    var symbolChoices: [(id: OpID, name: String)] {
        let state = document.state
        return Symbols.symbols(in: state).map { ($0, Self.name(of: $0, in: state)) }
    }

    static func name(of symbol: OpID, in state: EngineState) -> String {
        let name = state.props(symbol).symbol.common.name
        return name.isEmpty ? "Symbol" : name
    }

    func addSymbol(_ symbol: OpID) {
        symbols.append(symbol)
        selectedSymbol = symbol
    }

    /// btn:[-]: the selected symbol leaves the list.
    func removeSymbol() {
        guard let selectedSymbol, let index = symbols.firstIndex(of: selectedSymbol) else { return }
        symbols.remove(at: index)
        self.selectedSymbol = symbols.indices.contains(index) ? symbols[index] : symbols.last
    }

    /// The arrows: the selected symbol one place up (toward the top of the stack) or down.
    func moveSymbol(up: Bool) {
        guard let selectedSymbol, let index = symbols.firstIndex(of: selectedSymbol) else { return }
        let target = up ? index + 1 : index - 1
        guard symbols.indices.contains(target) else { return }
        symbols.swapAt(index, target)
    }

    func moveSymbolUp() { moveSymbol(up: true) }
    func moveSymbolDown() { moveSymbol(up: false) }

    // MARK: Settings

    /// Paint (true) or Spray; switching drops a Flare the new mode does not offer.
    var paint: Bool {
        get { props.mode == .paint }
        set { setPaint(newValue) }
    }

    /// A variation's mode pop-up.
    func modeBinding(_ kind: BrushVariationKind) -> Binding<Wiretuner_Doc_V1_VariationMode> {
        Binding(get: { self.variation(kind).mode == .unspecified ? .fixed : self.variation(kind).mode }, set: { self.setMode(kind, $0) })
    }

    /// A variation's *Fixed* slider.
    func valueBinding(_ kind: BrushVariationKind) -> Binding<Double> {
        Binding(get: { self.variation(kind).value }, set: { self.setValue(kind, $0) })
    }

    /// A variation's *Min* (`min`) or *Max* field.
    func rangeSetter(_ kind: BrushVariationKind, min: Bool) -> (Double) -> Void {
        { value in min ? self.setRange(kind, min: value) : self.setRange(kind, max: value) }
    }

    func variation(_ kind: BrushVariationKind) -> Wiretuner_Doc_V1_BrushVariation {
        switch kind {
        case .spacing: props.spacing
        case .angle: props.angle
        case .offset: props.offset
        case .scaling: props.scaling
        }
    }

    func setVariation(_ kind: BrushVariationKind, _ change: (inout Wiretuner_Doc_V1_BrushVariation) -> Void) {
        var variation = variation(kind)
        change(&variation)
        switch kind {
        case .spacing: props.spacing = variation
        case .angle: props.angle = variation
        case .offset: props.offset = variation
        case .scaling: props.scaling = variation
        }
    }

    /// The mode pop-up; a mode the brush's kind does not offer falls back to *Fixed*.
    func setMode(_ kind: BrushVariationKind, _ mode: Wiretuner_Doc_V1_VariationMode) {
        let offered = kind.modes(paint: paint).contains { $0.0 == mode }
        setVariation(kind) { $0.mode = offered ? mode : .fixed }
    }

    /// The *Fixed* value, clamped to its range.
    func setValue(_ kind: BrushVariationKind, _ value: Double) {
        setVariation(kind) { $0.value = min(max(value, kind.range.lowerBound), kind.range.upperBound) }
    }

    func setRange(_ kind: BrushVariationKind, min low: Double? = nil, max high: Double? = nil) {
        setVariation(kind) { variation in
            if let low { variation.min = low }
            if let high { variation.max = high }
        }
    }

    func setPaint(_ paint: Bool) {
        props.mode = paint ? .paint : .spray
        for kind in BrushVariationKind.allCases where variation(kind).mode == .flare { setMode(kind, .flare) }
    }

    /// *Count*, 1 ... 500.
    func setCount(_ count: Double) {
        props.count = UInt32(min(max(count.rounded(), 1), 500))
    }

    // MARK: OK

    /// The objects whose strokes use the edited brush.
    var users: [OpID] {
        guard case .edit(let brush, _) = purpose else { return [] }
        return BrushStrokes.users(of: brush, in: document.state)
    }

    /// btn:[OK]: the command, or the question to ask first when the brush is in use.
    func ok() -> Outcome {
        switch purpose {
        case .create(let nodes):
            return .perform(CreateBrush(nodes, source: source, name: name, definition: BrushDefinition(props: props, symbols: symbols)))
        case .edit(let brush, _):
            return users.isEmpty ? .perform(EditBrush(brush, definition: definition)) : .askChangeOrCreate
        }
    }

    /// The prompt's answer: *Change* rewrites the brush; *Create* makes a copy for the selected
    /// strokes.
    func resolve(change: Bool) -> (any WTModel.Command)? {
        guard case .edit(let brush, let strokes) = purpose else { return nil }
        return EditBrush(brush, definition: definition, choice: change ? .change : .create(strokes: strokes))
    }

    // MARK: Preview

    static let previewSize = Size(width: 240, height: 72)

    /// The brush on a sample path, as the draft would draw it: the edit (or the creation from the
    /// selection) made on a copy of the document, the brush copied into a small document of its
    /// own with a stroked path, and that drawn.  Nil when the draft cannot draw (no symbol).
    var preview: CGImage? {
        var scratch = DocumentCore(state: document.state, replica: 0x7E57)
        let recording = DocumentCore.Recording(limit: 1, now: Date(timeIntervalSince1970: 0))
        let before = Set(Brushes.list(document.state).map(\.id))
        let brush: OpID
        switch purpose {
        case .edit(let id, _):
            guard (try? scratch.perform(EditBrush(id, definition: definition), recording: recording)) != nil else { return nil }
            brush = id
        case .create(let nodes):
            let command = CreateBrush(nodes, source: .copy, name: name, definition: BrushDefinition(props: props, symbols: symbols))
            guard (try? scratch.perform(command, recording: recording)) != nil,
                  let created = Brushes.list(scratch.state).first(where: { !before.contains($0.id) }) else { return nil }
            brush = created.id
        }
        return Self.sample(brush, from: scratch.state)
    }

    /// Brush `brush` of `state` drawn along a gentle curve.
    static func sample(_ brush: OpID, from state: EngineState) -> CGImage? {
        guard let small = try? BrushFile.document([brush], from: state), let copy = Brushes.list(small).first else { return nil }
        var core = DocumentCore(state: small, replica: 0x7E58)
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        var stroke = Appearances.standard.strokes[0]
        stroke.settings.kind = .brush
        stroke.settings.brush.brush.id = copy.id.proto
        stroke.settings.brush.widthPercent = 100
        stroke.settings.brush.seed = 1
        appearance.strokes = [stroke]
        let size = previewSize
        let points = [Point(x: 20, y: size.height * 0.7), Point(x: size.width / 2, y: size.height * 0.3), Point(x: size.width - 20, y: size.height * 0.7)]
        let path = CreatePath(contours: [NewContour(points: points.map { VectorPoint(anchor: $0) })], appearance: appearance)
        guard (try? core.perform(path, recording: DocumentCore.Recording(limit: 1, now: Date(timeIntervalSince1970: 0)))) != nil else { return nil }
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("brush-preview"))
        let list = builder.rebuild(core.state).displayList
        return CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: Viewport(size: size), scale: 2)
    }
}

/// Reading which strokes use a brush.
enum BrushStrokes {
    /// The live objects holding a Brush stroke that references `brush`.
    static func users(of brush: OpID, in state: EngineState) -> [OpID] {
        state.store.nodes.sorted().filter { node in
            state.isLive(node) && AppearanceEditing.entries(node, in: state).contains { $0.row.list == .strokes && references($0, brush) }
        }
    }

    static func references(_ entry: AttributeEntry, _ brush: OpID) -> Bool {
        let settings = entry.stroke.settings
        return settings.kind == .brush && settings.brush.brush.hasID && OpID(settings.brush.brush.id) == brush
    }

    /// The brush the stroke rows share, nil when none or they differ.
    static func brush(of entries: [AttributeEntry]) -> OpID? {
        let ids = entries.map { entry -> OpID? in
            let brush = entry.stroke.settings.brush.brush
            return entry.stroke.settings.kind == .brush && brush.hasID ? OpID(brush.id) : nil
        }
        return shared(ids) ?? nil
    }
}

/// Brush files (stroke-attributes.adoc, "Import…", "Export…"): a brush file is a WireTuner
/// package holding the brushes and their symbols.
@MainActor
struct BrushFiles {
    var runOpenPanel: @MainActor (NSOpenPanel, NSWindow?) async -> [URL] = ModalUI.urls
    var runSavePanel: @MainActor (NSSavePanel, NSWindow?) async -> URL? = ModalUI.url
    var showAlert: @MainActor (String, String, NSWindow?) -> Void = ModalUI.alert

    /// The document a brush file holds.
    static func read(_ url: URL) throws -> EngineState {
        try DocumentPackage.state(of: DocumentPackage.reader.open(contentsOf: url))
    }

    /// Writes `brushes` of `state` as a brush file at `url`.
    static func write(_ brushes: [OpID], from state: EngineState, to url: URL) throws {
        let file = try BrushFile.document(brushes, from: state)
        let info = DocumentPackage.Info(documentID: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent)
        let contents = DocumentPackage.contents(of: file, info: info, page: Rect(x: 0, y: 0, width: 612, height: 792)) { _ in nil }
        _ = try PackageWriter().write(contents, to: url)
    }

    /// *Import…*: asks for a brush file and answers its document, nil when cancelled or unreadable
    /// (after an alert).
    func chooseFile() async -> EngineState? {
        let panel = NSOpenPanel()
        panel.title = "Import Brushes"
        panel.allowedContentTypes = [PackageController.contentType]
        guard let url = await runOpenPanel(panel, nil).first else { return nil }
        do {
            return try Self.read(url)
        } catch {
            showAlert("“\(url.lastPathComponent)” is not a brush file.", String(describing: error), nil)
            return nil
        }
    }

    /// *Export…*: asks where to save `brushes`; whether a file was written.
    @discardableResult
    func export(_ brushes: [OpID], from state: EngineState) async -> Bool {
        guard !brushes.isEmpty else { return false }
        let panel = NSSavePanel()
        panel.title = "Export Brushes"
        panel.nameFieldStringValue = "Brushes.\(PackageController.fileExtension)"
        panel.allowedContentTypes = [PackageController.contentType]
        guard let url = await runSavePanel(panel, nil) else { return false }
        do {
            try Self.write(brushes, from: state, to: url)
            return true
        } catch {
            showAlert("The brushes could not be exported.", String(describing: error), nil)
            return false
        }
    }
}

/// The Edit Brush sheet.
struct BrushEditorSheet: View {
    @Bindable var model: BrushEditorModel
    /// Closes the sheet having performed `command` (nil: cancelled).
    let finish: @MainActor ((any WTModel.Command)?) -> Void
    @State private var asking = false

    /// btn:[OK].
    static func confirm(_ model: BrushEditorModel, ask: @MainActor () -> Void, finish: @MainActor ((any WTModel.Command)?) -> Void) {
        switch model.ok() {
        case .perform(let command): finish(command)
        case .askChangeOrCreate: ask()
        }
    }

    private func confirm() { Self.confirm(model, ask: { asking = true }, finish: finish) }

    // The controls' actions, as closures the tests can call.

    static func cancelling(_ finish: @escaping @MainActor ((any WTModel.Command)?) -> Void) -> () -> Void {
        { finish(nil) }
    }

    /// The in-use prompt's *Change* (`change`) or *Create*.
    static func resolving(_ model: BrushEditorModel, change: Bool, finish: @escaping @MainActor ((any WTModel.Command)?) -> Void) -> () -> Void {
        { finish(model.resolve(change: change)) }
    }

    static func adding(_ symbol: OpID, model: BrushEditorModel) -> () -> Void {
        { model.addSymbol(symbol) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isCreating ? "Create Brush" : "Edit Brush").font(.headline)
            if model.isCreating {
                Picker("Symbol", selection: $model.source) {
                    Text("Copy").tag(BrushSymbolSource.copy)
                    Text("Convert").tag(BrushSymbolSource.convert)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("brush.source")
            }
            TextField("Brush name", text: $model.name).accessibilityIdentifier("brush.name")
            symbolList
            Picker("Mode", selection: $model.paint) {
                Text("Spray").tag(false)
                Text("Paint").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("brush.mode")
            if model.paint {
                CommitField(title: "Count", value: Double(max(model.props.count, 1)), identifier: "brush.count", commit: model.setCount)
            }
            Toggle("Orient on path", isOn: $model.props.orientOnPath).accessibilityIdentifier("brush.orient")
            Toggle("Fold corners", isOn: $model.props.foldCorners).accessibilityIdentifier("brush.fold")
            ForEach(BrushVariationKind.allCases) { kind in variation(kind) }
            AttributePreviewImage(image: model.preview, size: BrushEditorModel.previewSize, identifier: "brush.preview")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(finish)).keyboardShortcut(.cancelAction)
                Button("OK", action: confirm).keyboardShortcut(.defaultAction).accessibilityIdentifier("brush.ok")
                    .disabled(!model.isCreating && model.symbols.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog("This brush is in use.", isPresented: $asking) {
            Button("Change", action: Self.resolving(model, change: true, finish: finish))
            Button("Create", action: Self.resolving(model, change: false, finish: finish))
        } message: {
            Text("Change every stroke that uses it, or create a new brush for the selected strokes only.")
        }
    }

    private var symbolList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Include symbols").font(.caption)
            List(model.symbols.reversed(), id: \.self, selection: $model.selectedSymbol) { symbol in
                Text(BrushEditorModel.name(of: symbol, in: model.document.state))
            }
            .frame(height: 70)
            .accessibilityIdentifier("brush.symbols")
            HStack {
                Menu("+") {
                    ForEach(model.symbolChoices, id: \.id) { choice in
                        Button(choice.name, action: Self.adding(choice.id, model: model))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("brush.symbols.add")
                Button("-", action: model.removeSymbol).accessibilityIdentifier("brush.symbols.remove")
                Button("↑", action: model.moveSymbolUp).accessibilityIdentifier("brush.symbols.up")
                Button("↓", action: model.moveSymbolDown).accessibilityIdentifier("brush.symbols.down")
            }
        }
    }

    private func variation(_ kind: BrushVariationKind) -> some View {
        let current = model.variation(kind)
        return HStack {
            Picker(kind.rawValue, selection: model.modeBinding(kind)) {
                ForEach(kind.modes(paint: model.paint), id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("brush.\(kind.rawValue.lowercased()).mode")
            if current.mode == .fixed || current.mode == .unspecified {
                Slider(value: model.valueBinding(kind), in: kind.range)
                    .accessibilityIdentifier("brush.\(kind.rawValue.lowercased()).value")
            } else {
                CommitField(title: "Min", value: current.min, identifier: "brush.\(kind.rawValue.lowercased()).min", commit: model.rangeSetter(kind, min: true))
                CommitField(title: "Max", value: current.max, identifier: "brush.\(kind.rawValue.lowercased()).max", commit: model.rangeSetter(kind, min: false))
            }
        }
    }
}

/// The brushes of a brush file or of the document, picked for *Import…* or *Export…*.
struct BrushPickerSheet: View {
    let title: String
    let brushes: [BrushEntry]
    let finish: @MainActor ([OpID]) -> Void
    @State private var picked: Set<OpID> = []

    static func name(_ brush: BrushEntry) -> String { brush.name.isEmpty ? "Brush" : brush.name }

    static func cancelling(_ finish: @escaping @MainActor ([OpID]) -> Void) -> () -> Void {
        { finish([]) }
    }

    /// The default button: the picked brushes, in list order.
    static func choosing(_ picked: Set<OpID>, from brushes: [BrushEntry], finish: @escaping @MainActor ([OpID]) -> Void) -> () -> Void {
        { finish(brushes.map(\.id).filter(picked.contains)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            List(brushes, id: \.id, selection: $picked) { Text(Self.name($0)) }
                .frame(height: 160)
                .accessibilityIdentifier("brush.picker")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(finish)).keyboardShortcut(.cancelAction)
                Button(title, action: Self.choosing(picked, from: brushes, finish: finish)).keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
