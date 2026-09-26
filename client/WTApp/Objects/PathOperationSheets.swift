import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// The path operations with a sheet (OBJ-026, OBJ-029, OBJ-030): menu:Modify[Combine >
/// Transparency…], menu:Modify[Alter Path > Expand Stroke…] and menu:Modify[Alter Path > Inset
/// Path…], and the Path Operations toolbar's buttons for them.  Each opens its sheet over the
/// selection; btn:[OK] writes one change and selects the results.  Expand Stroke and Inset Path
/// consume their inputs unless this use keeps them -- *Path operations consume original paths*
/// inverted by kbd:[Shift] when the item is chosen, the item then reading "Expand Stroke (keep
/// original)…"; Transparency never consumes.
@MainActor
final class PathOperationFeatures {
    typealias Target = ObjectMenuCommands.Target

    enum Sheet {
        static let transparency = "transparency-sheet"
        static let expandStroke = "expand-stroke-sheet"
        static let insetPath = "inset-path-sheet"
    }

    static let needsTwoFilled = "Select two filled closed paths"
    static let needsPath = "Select a path"
    static let needsClosed = "Select a closed path"

    static let percent = PreferenceKey<Double>("tools.transparency.percent", "Transparency", category: .object, scope: .local, default: 50,
                                               control: .stepper(range: 0...100, step: 1, unit: "%"), help: "combining-paths")
    static let insetSteps = PreferenceKey<Double>("tools.inset.steps", "Inset steps", category: .object, scope: .local, default: 1,
                                                  control: .stepper(range: 1...100, step: 1, unit: ""), help: "inset-path")
    static let insetDistance = PreferenceKey<Double>("tools.inset.distance", "Inset", category: .object, scope: .local, default: 4,
                                                     control: .stepper(range: -500...500, step: 1, unit: "pt"), help: "inset-path")

    let target: Target
    let store: PreferenceStore
    let sheets: SheetPresenter
    /// Whether kbd:[Shift] is held; replaceable in tests.
    var shiftDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.shift) }
    private(set) var transparency: TransparencyModel?
    private(set) var expandStroke: ExpandStrokeModel?
    private(set) var insetPath: InsetPathModel?

    init(target: @escaping Target, store: PreferenceStore, sheets: SheetPresenter = SheetPresenter()) {
        self.target = target
        self.store = store
        self.sheets = sheets
    }

    /// Whether this use keeps the originals.
    var keepsOriginal: Bool {
        CombineCommand.keepsOriginals(consumePreference: store[PreferenceCatalog.Object.pathOperationsConsume], shift: shiftDown())
    }

    static func nodes(_ editing: ObjectEditing) -> [OpID] {
        editing.selection.selection.ids.map(\.opID)
    }

    /// Selects what `task`'s change created.
    static func selectResults(of task: Task<Wiretuner_Doc_V1_Change?, Never>, in selection: SelectionModel) {
        Task { @MainActor in
            if let created = await task.value?.createdRoots, !created.isEmpty { selection.set(Selection(created.map { SelectionID($0) })) }
        }
    }

    /// The item's title for this use.
    func title(_ base: String) -> String {
        keepsOriginal ? "\(base) (keep original)…" : "\(base)…"
    }

    func validation(_ reason: String, title: String? = nil, _ enabled: (_ nodes: [OpID], _ state: EngineState) -> Bool) -> CommandValidation {
        guard let editing = target() else { return CommandValidation(isEnabled: false, reason: ViewCommands.noDocument, title: title) }
        guard enabled(Self.nodes(editing), editing.document.state) else { return CommandValidation(isEnabled: false, reason: reason, title: title) }
        return CommandValidation(title: title)
    }

    var transparencyValidation: CommandValidation { validation(Self.needsTwoFilled) { TransparencyCommand.canPerform($0, in: $1) } }
    var expandStrokeValidation: CommandValidation {
        validation(Self.needsPath, title: title("Expand Stroke")) { ExpandStrokeCommand.canPerform($0, in: $1) }
    }
    var insetPathValidation: CommandValidation {
        validation(Self.needsClosed, title: title("Inset Path")) { InsetPathCommand.canPerform($0, in: $1) }
    }

    // MARK: Sheets

    /// Opens the Transparency sheet over the selection; nil when it is not two filled closed paths.
    @discardableResult
    func showTransparency() -> TransparencyModel? {
        guard let editing = target(), TransparencyCommand.canPerform(Self.nodes(editing), in: editing.document.state) else { return nil }
        let model = TransparencyModel(document: editing.document, nodes: Self.nodes(editing), percent: store[Self.percent]) { [weak self] task, percent in
            guard let self else { return }
            if let percent { store.set(percent, for: Self.percent) }
            if let task { Self.selectResults(of: task, in: editing.selection.model) }
            transparency = nil
            sheets.dismiss(Sheet.transparency)
        }
        transparency = model
        sheets.present(TransparencySheet(model: model), title: "Transparency", identifier: Sheet.transparency)
        return model
    }

    /// Opens the Expand Stroke sheet over the selection, starting from its stroke.
    @discardableResult
    func showExpandStroke() -> ExpandStrokeModel? {
        guard let editing = target(), ExpandStrokeCommand.canPerform(Self.nodes(editing), in: editing.document.state) else { return nil }
        let nodes = Self.nodes(editing)
        let model = ExpandStrokeModel(document: editing.document, nodes: nodes, style: ExpandStrokeCommand.style(nodes, in: editing.document.state),
                                      keepOriginal: keepsOriginal) { [weak self] task in
            guard let self else { return }
            if let task { Self.selectResults(of: task, in: editing.selection.model) }
            expandStroke = nil
            sheets.dismiss(Sheet.expandStroke)
        }
        expandStroke = model
        sheets.present(ExpandStrokeSheet(model: model), title: "Expand Stroke", identifier: Sheet.expandStroke)
        return model
    }

    /// Opens the Inset Path sheet over the selection, with the steps and inset used before.
    @discardableResult
    func showInsetPath() -> InsetPathModel? {
        guard let editing = target(), InsetPathCommand.canPerform(Self.nodes(editing), in: editing.document.state) else { return nil }
        let model = InsetPathModel(document: editing.document, nodes: Self.nodes(editing), steps: Int(store[Self.insetSteps]),
                                   distance: store[Self.insetDistance], keepOriginal: keepsOriginal) { [weak self] task, used in
            guard let self else { return }
            if let used {
                store.set(Double(used.steps), for: Self.insetSteps)
                store.set(used.distance, for: Self.insetDistance)
            }
            if let task { Self.selectResults(of: task, in: editing.selection.model) }
            insetPath = nil
            sheets.dismiss(Sheet.insetPath)
        }
        insetPath = model
        sheets.present(InsetPathSheet(model: model), title: "Inset Path", identifier: Sheet.insetPath)
        return model
    }

    // MARK: Commands

    func commands() -> [Command] {
        let modify = ContextMenuCatalog.Menu.modify
        return [
            Command(id: ContextMenuCatalog.ID.transparency, title: "Transparency…", menu: MenuPath(modify, "Combine", section: 3),
                    keywords: ["combine", "transparency", "overlap", "mix"], validation: { [self] in transparencyValidation },
                    action: .perform { [self] in showTransparency() }),
            Command(id: ContextMenuCatalog.ID.expandStroke, title: "Expand Stroke…", menu: MenuPath(modify, "Alter Path", section: 3),
                    keywords: ["expand", "stroke", "outline"], validation: { [self] in expandStrokeValidation },
                    action: .perform { [self] in showExpandStroke() }),
            Command(id: ContextMenuCatalog.ID.insetPath, title: "Inset Path…", menu: MenuPath(modify, "Alter Path", section: 3),
                    keywords: ["inset", "offset", "outset", "contour"], validation: { [self] in insetPathValidation },
                    action: .perform { [self] in showInsetPath() }),
        ]
    }

    /// The Path Operations toolbar's *Transparency…*, *Expand Stroke…* and *Inset Path…*.
    func extensionDescriptors(existing: ExtensionRegistry) -> [ExtensionDescriptor] {
        let entries: [(String, @MainActor () -> CommandValidation, @MainActor () -> Void)] = [
            ("transparency", { [self] in transparencyValidation }, { [self] in showTransparency() }),
            ("expandStroke", { [self] in expandStrokeValidation }, { [self] in showExpandStroke() }),
            ("insetPath", { [self] in insetPathValidation }, { [self] in showInsetPath() }),
        ]
        return entries.compactMap { id, validate, show in
            guard var descriptor = existing.descriptor(for: id) else { return nil }
            descriptor.validate = validate
            descriptor.run = { _ in
                show()
                return nil
            }
            return descriptor
        }
    }

    func install(commands registry: CommandRegistry, extensions: ExtensionRegistry) {
        for var command in commands() {
            // The context menus' placement stays the catalog's.
            command.contexts = registry.command(command.id)?.contexts ?? []
            registry.replace(command)
        }
        for descriptor in extensionDescriptors(existing: extensions) { extensions.replace(descriptor) }
    }
}

// MARK: - Transparency

/// The Transparency sheet (combining-paths.adoc, "Transparency"): how much of the top colour shows
/// in the overlap, 0–100%, with the mixed colour; btn:[OK] writes `TransparencyCommand`.
@MainActor
@Observable
final class TransparencyModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let nodes: [OpID]
    var percent: Double
    @ObservationIgnored let finish: @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?, Double?) -> Void

    init(document: DocumentHandle, nodes: [OpID], percent: Double,
         finish: @escaping @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?, Double?) -> Void) {
        self.document = document
        self.nodes = nodes
        self.percent = min(max(percent, 0), 100)
        self.finish = finish
    }

    /// Whether the two paths overlap (else btn:[OK] is disabled and the sheet says so).
    var overlaps: Bool { !TransparencyCommand.overlap(nodes, in: document.state).isEmpty }

    /// The colour the overlap will take.
    var mixed: CGColor? { TransparencyCommand.mixedColor(nodes, percent: percent, in: document.state)?.cgColor }

    /// btn:[OK].
    @discardableResult
    func confirm() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard overlaps else { return nil }
        let task = document.perform(TransparencyCommand(nodes, percent: percent))
        finish(task, percent)
        return task
    }

    /// btn:[Cancel].
    func cancel() { finish(nil, nil) }
}

struct TransparencySheet: View {
    @Bindable var model: TransparencyModel

    static func text(_ model: TransparencyModel) -> Binding<String> {
        Binding(get: { String(Int(model.percent.rounded())) }, set: { if let value = Double($0) { model.percent = min(max(value, 0), 100) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transparency").font(.headline)
            HStack {
                Slider(value: $model.percent, in: 0...100) { Text("Top color") }.accessibilityIdentifier("transparency.slider")
                TextField("", text: Self.text(model)).frame(width: 44).accessibilityIdentifier("transparency.percent")
                Text("%")
                if let mixed = model.mixed {
                    RoundedRectangle(cornerRadius: 3).fill(Color(cgColor: mixed)).frame(width: 22, height: 22)
                }
            }
            if !model.overlaps {
                Text("The paths do not overlap.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("transparency.note")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("OK") { model.confirm() }.keyboardShortcut(.defaultAction).disabled(!model.overlaps).accessibilityIdentifier("transparency.ok")
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - Stroke controls

/// The cap and join names the sheets show.
enum StrokeControlTitles {
    static func title(_ cap: WTGeometry.LineCap) -> String {
        switch cap {
        case .butt: "Butt"
        case .round: "Round"
        case .square: "Square"
        }
    }

    static func title(_ join: WTGeometry.LineJoin) -> String {
        switch join {
        case .miter: "Miter"
        case .round: "Round"
        case .bevel: "Bevel"
        }
    }
}

// MARK: - Expand Stroke

/// The Expand Stroke sheet (expand-stroke.adoc): *Width* (0.1–500 pt), *Cap*, *Join* and *Miter
/// limit*, starting from the selection's stroke; btn:[OK] writes `ExpandStrokeCommand`.
@MainActor
@Observable
final class ExpandStrokeModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let nodes: [OpID]
    var width: Double
    var cap: WTGeometry.LineCap
    var join: WTGeometry.LineJoin
    var miterLimit: Double
    @ObservationIgnored let keepOriginal: Bool
    @ObservationIgnored let finish: @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?) -> Void

    init(document: DocumentHandle, nodes: [OpID], style: WTGeometry.StrokeStyle, keepOriginal: Bool,
         finish: @escaping @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?) -> Void) {
        self.document = document
        self.nodes = nodes
        width = min(max(style.width, ExpandStrokeCommand.widths.lowerBound), ExpandStrokeCommand.widths.upperBound)
        cap = style.cap
        join = style.join
        miterLimit = style.miterLimit
        self.keepOriginal = keepOriginal
        self.finish = finish
    }

    var command: ExpandStrokeCommand {
        ExpandStrokeCommand(nodes, width: width, cap: cap, join: join, miterLimit: miterLimit, keepOriginal: keepOriginal)
    }

    /// Sets the width from a field, clamped to the range.
    func setWidth(_ value: Double) {
        width = min(max(value, ExpandStrokeCommand.widths.lowerBound), ExpandStrokeCommand.widths.upperBound)
    }

    /// Sets the miter limit from a field (at least 1).
    func setMiterLimit(_ value: Double) {
        miterLimit = max(value, 1)
    }

    /// btn:[OK].
    @discardableResult
    func confirm() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        let task = document.perform(command)
        finish(task)
        return task
    }

    /// btn:[Cancel].
    func cancel() { finish(nil) }
}

struct ExpandStrokeSheet: View {
    @Bindable var model: ExpandStrokeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expand Stroke").font(.headline)
            HStack {
                Slider(value: $model.width, in: ExpandStrokeCommand.widths) { Text("Width") }.accessibilityIdentifier("expandStroke.slider")
                MeasureField(title: "", value: model.width, units: model.document.unitConverter, identifier: "expandStroke.width",
                             commit: model.setWidth).frame(width: 80)
            }
            Picker("Cap", selection: $model.cap) {
                ForEach(WTGeometry.LineCap.allCases, id: \.self) { Text(StrokeControlTitles.title($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("expandStroke.cap")
            Picker("Join", selection: $model.join) {
                ForEach(WTGeometry.LineJoin.allCases, id: \.self) { Text(StrokeControlTitles.title($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("expandStroke.join")
            InspectorField(title: "Miter limit", value: model.miterLimit, format: .number, formatID: "miter", identifier: "expandStroke.miter",
                           commit: model.setMiterLimit)
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("OK") { model.confirm() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("expandStroke.ok")
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - Inset Path

/// The Inset Path sheet (inset-path.adoc): *Steps*, *Spacing* (steps above 1), *Inset* in the
/// document's unit (negative goes outside), *Join* and *Miter limit*; when every step would
/// collapse it says so and btn:[OK] is disabled.  btn:[OK] writes `InsetPathCommand`.
@MainActor
@Observable
final class InsetPathModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let nodes: [OpID]
    var steps: Int
    var spacing: InsetSpacing = .uniform
    var distance: Double
    var join: WTGeometry.LineJoin = .miter
    var miterLimit: Double = 4
    @ObservationIgnored let keepOriginal: Bool
    @ObservationIgnored let finish: @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?, (steps: Int, distance: Double)?) -> Void

    init(document: DocumentHandle, nodes: [OpID], steps: Int, distance: Double, keepOriginal: Bool,
         finish: @escaping @MainActor (Task<Wiretuner_Doc_V1_Change?, Never>?, (steps: Int, distance: Double)?) -> Void) {
        self.document = document
        self.nodes = nodes
        self.steps = min(max(steps, InsetPathCommand.stepRange.lowerBound), InsetPathCommand.stepRange.upperBound)
        self.distance = distance
        self.keepOriginal = keepOriginal
        self.finish = finish
    }

    var command: InsetPathCommand {
        InsetPathCommand(nodes, steps: steps, spacing: spacing, distance: distance, join: join, miterLimit: miterLimit, keepOriginal: keepOriginal)
    }

    /// Whether every step of every path collapses.
    var collapses: Bool { command.collapses(in: document.state) }

    func setSteps(_ value: Double) {
        steps = min(max(Int(value.rounded()), InsetPathCommand.stepRange.lowerBound), InsetPathCommand.stepRange.upperBound)
    }

    func setDistance(_ value: Double) { distance = value }

    func setMiterLimit(_ value: Double) { miterLimit = max(value, 1) }

    static func title(_ spacing: InsetSpacing) -> String {
        switch spacing {
        case .uniform: "Uniform"
        case .farther: "Farther"
        case .nearer: "Nearer"
        }
    }

    /// btn:[OK]; nil (nothing written, the sheet stays) when every step collapses.
    @discardableResult
    func confirm() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard !collapses else { return nil }
        let task = document.perform(command)
        finish(task, (steps, distance))
        return task
    }

    /// btn:[Cancel].
    func cancel() { finish(nil, nil) }
}

struct InsetPathSheet: View {
    @Bindable var model: InsetPathModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inset Path").font(.headline)
            InspectorField(title: "Steps", value: Double(model.steps), format: .number, formatID: "steps", identifier: "insetPath.steps",
                           commit: model.setSteps)
            Picker("Spacing", selection: $model.spacing) {
                ForEach(InsetSpacing.allCases, id: \.self) { Text(InsetPathModel.title($0)).tag($0) }
            }.pickerStyle(.segmented).disabled(model.steps < 2).accessibilityIdentifier("insetPath.spacing")
            HStack {
                Slider(value: $model.distance, in: -100...100) { Text("Inset") }.accessibilityIdentifier("insetPath.slider")
                MeasureField(title: "", value: model.distance, units: model.document.unitConverter, identifier: "insetPath.distance",
                             commit: model.setDistance).frame(width: 80)
            }
            Picker("Join", selection: $model.join) {
                ForEach(WTGeometry.LineJoin.allCases, id: \.self) { Text(StrokeControlTitles.title($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("insetPath.join")
            InspectorField(title: "Miter limit", value: model.miterLimit, format: .number, formatID: "miter", identifier: "insetPath.miter",
                           commit: model.setMiterLimit)
            if model.collapses {
                Text("The inset is larger than the path: nothing would be left.").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("insetPath.note")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button("OK") { model.confirm() }.keyboardShortcut(.defaultAction).disabled(model.collapses).accessibilityIdentifier("insetPath.ok")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
