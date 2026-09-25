import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The *{product}* pane of the Print dialog as a model (printing.adoc; the PRINT-002 glue): every
/// control reads `DocumentPrintSettings` from the document on each render -- so a collaborator's
/// change shows at once -- and each commit performs one labelled `SetPrintSettings` or `SetPlate`.
/// What to print (pages or the output area, *Selected objects only*) is the job's, kept here and
/// never in the document.  The session shows each plan it makes here: the sheet count, the ink
/// list's artwork and the clipping warning beneath the preview.
@MainActor
@Observable
final class PrintPaneModel {
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    /// The objects selected when the dialog opened; nil when nothing was.
    @ObservationIgnored let selection: Set<NodeID>?
    /// *Pages* or *Output area*.
    var source: PrintSource = .pages
    /// *Selected objects only*.
    var selectedOnly = false
    /// The sheets of the current plan.
    private(set) var sheetCount = 0
    /// `PrintPlan.clippingWarning` of the current plan.
    private(set) var warning: String?
    /// The captured pages' lists of the current plan: the ink list's spot rows are the spots they use.
    @ObservationIgnored private(set) var lists: [DisplayList]?
    /// Bumped on every commit: the accessory's preview key path.
    private(set) var revision = 0
    /// Called after every commit (the preview repaginates).
    @ObservationIgnored var onChange: @MainActor () -> Void = {}

    init(document: DocumentHandle, selection: Set<NodeID>? = nil, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.selection = selection.flatMap { $0.isEmpty ? nil : $0 }
        self.perform = perform
    }

    /// The selection a job prints: the dialog's when *Selected objects only* is on.
    var effectiveSelection: Set<NodeID>? { selectedOnly ? selection : nil }

    /// Shows `plan`: its sheet count, lists and warning.
    func show(_ plan: PrintPlan) {
        sheetCount = plan.count
        warning = plan.clippingWarning
        lists = plan.request.scene.pages.map(\.displayList)
    }

    var settings: DocumentPrintSettings {
        _ = document.model?.revision
        return DocumentPrintSettings(document.state)
    }

    /// Whether the document has an output area (the *Output area* choice is disabled without one).
    var hasOutputArea: Bool { OutputArea.read(document.state) != nil }

    /// The source a job prints: the output area only while there is one.
    var effectiveSource: PrintSource { source == .outputArea && hasOutputArea ? .outputArea : .pages }

    func commit(_ setting: PrintSetting) {
        perform(SetPrintSettings(setting))
        changed()
    }

    func changed() {
        revision += 1
        onChange()
    }

    /// btn:[Center]: the offset goes back to zero.
    func center() { commit(.offset(.zero)) }

    // MARK: Plates

    /// The ink list's rows (`PrintSnapshot.inks`): the process inks and the spot inks the printed
    /// artwork uses -- never the protected Black and Registration swatches.
    var inks: [PrintInk] {
        PrintSnapshot.inks(document.state, lists: lists ?? [document.displayList])
    }

    struct PlateRow: Equatable, Identifiable {
        var ink: PrintInk
        var name: String
        var print: Bool
        var angle: Double
        /// Lines per inch; the document default when the plate has none.
        var frequency: Double
        var id: String { name }
    }

    var plates: [PlateRow] {
        let settings = settings
        let state = document.state
        let fallback = Self.frequency(settings.defaultHalftone.frequency, or: 60)
        return inks.map { ink in
            let plate = settings.plate(ink)
            return PlateRow(ink: ink, name: ink.name(in: state), print: plate?.print ?? true, angle: plate?.angle ?? ink.defaultAngle,
                            frequency: Self.frequency(plate?.frequency ?? 0, or: fallback))
        }
    }

    /// `value` when it names a frequency, else `fallback` (0 inherits).
    static func frequency(_ value: Double, or fallback: Double) -> Double { value > 0 ? value : fallback }

    func setPlate(_ ink: PrintInk, print: Bool? = nil, angle: Double? = nil, frequency: Double? = nil) {
        perform(SetPlate(ink, print: print, angle: angle, frequency: frequency, in: document.state))
        changed()
    }

    // MARK: Halftone screen

    static let shapes: [(Wiretuner_Doc_V1_HalftoneShape, String)] = [
        (.round, "Round"), (.ellipse, "Ellipse"), (.line, "Line"), (.diamond, "Diamond"), (.square, "Square"), (.cross, "Cross"),
    ]

    func setDefaultScreen(shape: Wiretuner_Doc_V1_HalftoneShape? = nil, frequency: Double? = nil) {
        var screen = settings.defaultHalftone
        if let shape { screen.shape = shape }
        if let frequency { screen.frequency = frequency }
        commit(.defaultHalftone(screen))
    }

    /// The summary lines of the Print dialog's collapsed pane.
    var summary: [(name: String, value: String)] {
        let s = settings
        let scale: String
        switch s.scaleMode {
        case .uniform: scale = "\(Self.number(s.scaleX))%"
        case .variable: scale = "\(Self.number(s.scaleX))% × \(Self.number(s.scaleY))%"
        case .fit: scale = "Fit on paper"
        }
        let what = selectedOnly && selection != nil ? "\(effectiveSource.title), selected objects" : effectiveSource.title
        let tiling: [DocumentPrintSettings.TileMode: String] = [.none: "None", .automatic: "Automatic", .manual: "Manual"]
        return [("Print", what), ("Scale", scale), ("Tiling", tiling[s.tile]!), ("Output", s.separations ? "Separations" : "Composite"),
                ("Bleed", "\(Self.number(s.bleed)) pt"), ("Sheets", "\(sheetCount)")]
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// The pane's controls.
struct PrintPaneView: View {
    let model: PrintPaneModel

    static func source(_ model: PrintPaneModel) -> Binding<PrintSource> {
        Binding(get: { model.effectiveSource }, set: { model.source = $0; model.changed() })
    }

    static func scaleMode(_ model: PrintPaneModel) -> Binding<DocumentPrintSettings.ScaleMode> {
        Binding(get: { model.settings.scaleMode }, set: { model.commit(.scaleMode($0)) })
    }

    static func selectedOnly(_ model: PrintPaneModel) -> Binding<Bool> {
        Binding(get: { model.selectedOnly && model.selection != nil }, set: { model.selectedOnly = $0; model.changed() })
    }

    static func tile(_ model: PrintPaneModel) -> Binding<DocumentPrintSettings.TileMode> {
        Binding(get: { model.settings.tile }, set: { model.commit(.tile($0)) })
    }

    static func separations(_ model: PrintPaneModel) -> Binding<Bool> {
        Binding(get: { model.settings.separations }, set: { model.commit(.separations($0)) })
    }

    static func mark(_ model: PrintPaneModel, _ mark: DocumentPrintSettings.Mark) -> Binding<Bool> {
        Binding(get: { model.settings.marks.contains(mark) }, set: { model.commit(.mark(mark, $0)) })
    }

    static func shape(_ model: PrintPaneModel) -> Binding<Int> {
        Binding(get: { model.settings.defaultHalftone.shape.rawValue }, set: { model.setDefaultScreen(shape: Wiretuner_Doc_V1_HalftoneShape(rawValue: $0)) })
    }

    static func platePrint(_ model: PrintPaneModel, _ row: PrintPaneModel.PlateRow) -> Binding<Bool> {
        Binding(get: { row.print }, set: { model.setPlate(row.ink, print: $0) })
    }

    static let markTitles: [(DocumentPrintSettings.Mark, String)] = [
        (.crop, "Crop marks"), (.registration, "Registration marks"), (.separationNames, "Separation names"), (.fileNameDate, "File name and date"),
    ]

    /// A checkbox of the pane: its title, identifier, value and the setting it writes.
    struct Switch {
        let title: String
        let id: String
        let value: @Sendable (DocumentPrintSettings) -> Bool
        let setting: @Sendable (Bool) -> PrintSetting
    }

    /// A number field of the pane: its title, identifier, value and the setting a typed value writes
    /// (clamped to the field's range).
    struct Number {
        let title: String
        let id: String
        let value: @Sendable (DocumentPrintSettings) -> Double
        let setting: @Sendable (Double, DocumentPrintSettings) -> PrintSetting
    }

    static let pageBoundaries = Switch(title: "Print page boundaries", id: "print.pageBoundaries", value: { $0.printPageBoundary }, setting: { .printPageBoundary($0) })
    static let outputSwitches: [Switch] = [
        Switch(title: "Print spot colors as process", id: "print.spotAsProcess", value: { $0.spotAsProcess }, setting: { .spotAsProcess($0) }),
        Switch(title: "Screen in WireTuner", id: "print.screenInApp", value: { $0.screenInApp }, setting: { .screenInApp($0) }),
        Switch(title: "Ignore object screens", id: "print.ignoreObjectScreens", value: { $0.ignoreObjectHalftones }, setting: { .ignoreObjectHalftones($0) }),
    ]
    static let imagingSwitches: [Switch] = [
        Switch(title: "Emulsion down", id: "print.emulsionDown", value: { $0.emulsionDown }, setting: { .emulsionDown($0) }),
        Switch(title: "Negative", id: "print.negative", value: { $0.negative }, setting: { .negative($0) }),
        Switch(title: "Include hidden layers", id: "print.hiddenLayers", value: { $0.includeHiddenLayers }, setting: { .includeHiddenLayers($0) }),
        Switch(title: "Print text as outlines", id: "print.textAsOutlines", value: { $0.textAsOutlines }, setting: { .textAsOutlines($0) }),
    ]
    static let scaleX = Number(title: "X %", id: "print.scaleX", value: { $0.scaleX }, setting: { value, _ in .scaleX(min(max(value, 1), 2000)) })
    static let scaleY = Number(title: "Y %", id: "print.scaleY", value: { $0.scaleY }, setting: { value, _ in .scaleY(min(max(value, 1), 2000)) })
    static let offsets: [Number] = [
        Number(title: "Offset X", id: "print.offsetX", value: { $0.offset.x }, setting: { value, s in .offset(Point(x: value, y: s.offset.y)) }),
        Number(title: "Offset Y", id: "print.offsetY", value: { $0.offset.y }, setting: { value, s in .offset(Point(x: s.offset.x, y: value)) }),
    ]
    static let overlap = Number(title: "Overlap", id: "print.tileOverlap", value: { $0.tileOverlap }, setting: { value, _ in .tileOverlap(min(max(value, 0), 720)) })
    static let bleed = Number(title: "Bleed", id: "print.bleed", value: { $0.bleed }, setting: { value, _ in .bleed(min(max(value, 0), 720)) })
    static let imagingNumbers: [Number] = [
        Number(title: "Flatness", id: "print.flatness", value: { $0.flatness }, setting: { value, _ in .flatness(min(max(value, 0), 100)) }),
        Number(title: "Rasterize at (dpi, 0 for vector)", id: "print.rasterize", value: { $0.rasterizeDPI },
               setting: { value, _ in .rasterizeDPI(value <= 0 ? 0 : min(max(value, 72), 2400)) }),
    ]

    static func binding(_ model: PrintPaneModel, _ item: Switch) -> Binding<Bool> {
        Binding(get: { item.value(model.settings) }, set: { model.commit(item.setting($0)) })
    }

    static func commit(_ model: PrintPaneModel, _ item: Number) -> (Double) -> Void {
        { value in model.commit(item.setting(value, model.settings)) }
    }

    static func plateAngle(_ model: PrintPaneModel, _ row: PrintPaneModel.PlateRow) -> (Double) -> Void {
        { model.setPlate(row.ink, angle: min(max($0, 0), 360)) }
    }

    static func plateFrequency(_ model: PrintPaneModel, _ row: PrintPaneModel.PlateRow) -> (Double) -> Void {
        { model.setPlate(row.ink, frequency: min(max($0, 0), 600)) }
    }

    static func screenFrequency(_ model: PrintPaneModel) -> (Double) -> Void {
        { model.setDefaultScreen(frequency: min(max($0, 0), 600)) }
    }

    @ViewBuilder
    func toggle(_ item: Switch) -> some View {
        Toggle(item.title, isOn: Self.binding(model, item)).accessibilityIdentifier(item.id)
    }

    @ViewBuilder
    func field(_ item: Number, _ settings: DocumentPrintSettings) -> some View {
        CommitField(title: item.title, value: item.value(settings), identifier: item.id, commit: Self.commit(model, item))
    }

    var body: some View {
        let _ = model.revision
        let settings = model.settings
        Form {
            Section("Print") {
                Picker("Print", selection: Self.source(model)) {
                    Text(PrintSource.pages.title).tag(PrintSource.pages)
                    Text(PrintSource.outputArea.title).tag(PrintSource.outputArea).disabled(!model.hasOutputArea)
                }
                .accessibilityIdentifier("print.source")
                Toggle("Selected objects only", isOn: Self.selectedOnly(model)).accessibilityIdentifier("print.selectedOnly").disabled(model.selection == nil)
                toggle(Self.pageBoundaries)
            }
            Section("Scale") {
                Picker("Scale", selection: Self.scaleMode(model)) {
                    Text("Uniform").tag(DocumentPrintSettings.ScaleMode.uniform)
                    Text("Variable").tag(DocumentPrintSettings.ScaleMode.variable)
                    Text("Fit on paper").tag(DocumentPrintSettings.ScaleMode.fit)
                }
                .accessibilityIdentifier("print.scaleMode")
                field(Self.scaleX, settings)
                if settings.scaleMode == .variable { field(Self.scaleY, settings) }
                ForEach(Self.offsets, id: \.id) { field($0, settings) }
                Button("Center", action: model.center).accessibilityIdentifier("print.center")
            }
            Section("Tiling") {
                Picker("Tiling", selection: Self.tile(model)) {
                    Text("None").tag(DocumentPrintSettings.TileMode.none)
                    Text("Automatic").tag(DocumentPrintSettings.TileMode.automatic)
                    Text("Manual").tag(DocumentPrintSettings.TileMode.manual)
                }
                .accessibilityIdentifier("print.tile")
                .disabled(settings.scaleMode == .fit)
                field(Self.overlap, settings).disabled(settings.tile != .automatic || settings.scaleMode == .fit)
            }
            Section("Output") {
                Toggle("Separations", isOn: Self.separations(model)).accessibilityIdentifier("print.separations")
                ForEach(model.plates) { row in
                    HStack {
                        Toggle(row.name, isOn: Self.platePrint(model, row)).accessibilityIdentifier("print.plate.\(row.name)")
                        CommitField(title: "Angle", value: row.angle, identifier: "print.plate.\(row.name).angle", commit: Self.plateAngle(model, row))
                        CommitField(title: "lpi", value: row.frequency, identifier: "print.plate.\(row.name).frequency", commit: Self.plateFrequency(model, row))
                    }
                    .disabled(!settings.separations)
                }
                toggle(Self.outputSwitches[0])
                Picker("Halftone screen", selection: Self.shape(model)) {
                    Text("Default").tag(0)
                    ForEach(PrintPaneModel.shapes, id: \.0.rawValue) { Text($0.1).tag($0.0.rawValue) }
                }
                .accessibilityIdentifier("print.screenShape")
                CommitField(title: "Frequency", value: settings.defaultHalftone.frequency, identifier: "print.screenFrequency", commit: Self.screenFrequency(model))
                ForEach(Self.outputSwitches.dropFirst(), id: \.id) { toggle($0) }
            }
            Section("Marks and bleed") {
                ForEach(Self.markTitles, id: \.0.rawValue) { mark, title in
                    Toggle(title, isOn: Self.mark(model, mark)).accessibilityIdentifier("print.mark.\(mark.rawValue)")
                }
                field(Self.bleed, settings)
            }
            Section("Imaging") {
                ForEach(Self.imagingSwitches, id: \.id) { toggle($0) }
                ForEach(Self.imagingNumbers, id: \.id) { field($0, settings) }
            }
            Section {
                Text(model.sheetCount == 1 ? "1 sheet" : "\(model.sheetCount) sheets").accessibilityIdentifier("print.sheets")
                if let warning = model.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("print.clippingWarning")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
    }
}

/// The Print dialog's *{product}* pane (`NSPrintPanelAccessorizing`): the SwiftUI pane in the
/// panel, its summary for the collapsed dialog, and a preview key path bumped on every commit so
/// the panel's preview repaginates.  The panel hands the accessory its print info as the
/// represented object -- at setup and again when a preset is chosen -- and each time that
/// happens, the pane appears or the summary is read, `onPrintInfo` lets the session apply a
/// preset the print info holds.
@MainActor
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let model: PrintPaneModel
    /// Observed by the print panel's preview.
    @objc dynamic var revision = 0
    /// The print info may hold a preset the document does not have yet.
    var onPrintInfo: @MainActor () -> Void = {}

    init(model: PrintPaneModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "WireTuner"
        let previous = model.onChange
        model.onChange = { [weak self] in
            previous()
            self?.revision += 1
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSHostingView(rootView: PrintPaneView(model: model))
    }

    override var representedObject: Any? {
        didSet { onPrintInfo() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        onPrintInfo()
    }

    /// Whether the panel is on screen: its preview is drawing, not the spooled job.
    var isShowing: Bool { isViewLoaded && view.window?.isVisible == true }

    nonisolated func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        MainActor.assumeIsolated {
            onPrintInfo()
            return model.summary.map { [.itemName: $0.name, .itemDescription: $0.value] }
        }
    }

    nonisolated func keyPathsForValuesAffectingPreview() -> Set<String> { ["revision"] }
}
