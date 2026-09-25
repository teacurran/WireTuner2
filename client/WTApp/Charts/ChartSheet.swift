import AppKit
import SwiftUI
import WTModel
import WTProto

/// The Chart sheet (charts.adoc; DRAW-033): the *Data* tab -- entry field, grid, Undo, Import,
/// Transpose, Switch XY, Cut, Copy, Paste, precision and separator -- and the *Type* tab -- the six
/// types, the options, gridlines, axis display and the X and Y Axis sheets -- with btn:[Apply],
/// btn:[OK] and btn:[Cancel].
struct ChartSheetView: View {
    @Bindable var model: ChartSheetModel
    let close: @MainActor () -> Void
    @State private var axis: AxisChoice?

    enum AxisChoice: String, Identifiable {
        case x, y
        var id: String { rawValue }
    }

    static let markers: [(Wiretuner_Doc_V1_ChartMarker, String)] = [(.none, "None"), (.square, "Square"), (.diamond, "Diamond"), (.triangle, "Triangle"), (.circle, "Circle")]
    static let axisDisplays: [(Wiretuner_Doc_V1_ChartAxisDisplay, String)] = [(.left, "Left"), (.right, "Right"), (.both, "Both")]

    /// The sheet's buttons that act on the model alone.
    enum Action: CaseIterable {
        case undo, cut, copy, paste, transpose, switchXY, apply
    }

    static func action(_ action: Action, _ model: ChartSheetModel) -> () -> Void {
        { perform(action, model) }
    }

    static func perform(_ action: Action, _ model: ChartSheetModel) {
        switch action {
        case .undo: model.undo()
        case .cut: model.cut()
        case .copy: model.copy()
        case .paste: model.paste()
        case .transpose: model.transpose()
        case .switchXY: model.switchXY()
        case .apply: model.apply()
        }
    }

    static func selecting(_ position: ChartSheetModel.Position, _ model: ChartSheetModel) -> () -> Void {
        { model.select(position, extending: NSEvent.modifierFlags.contains(.shift)) }
    }

    static func moving(_ rows: Int, _ columns: Int, _ model: ChartSheetModel) -> () -> Void {
        { model.move(rows: rows, columns: columns) }
    }

    static func committing(_ model: ChartSheetModel) -> () -> Void {
        { model.commit() }
    }

    static func finishing(_ model: ChartSheetModel, close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.apply()
            close()
        }
    }

    static func cancelling(_ model: ChartSheetModel, close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.cancel()
            close()
        }
    }

    /// btn:[Import…]: an open panel for a tab-delimited file.
    static func importing(_ model: ChartSheetModel, panel: @escaping @MainActor () -> URL? = ChartSheetView.chooseFile) -> () -> Void {
        { if let url = panel() { model.importFile(url) } }
    }

    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText, .commaSeparatedText]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func typeBinding(_ model: ChartSheetModel) -> Binding<Wiretuner_Doc_V1_ChartType> {
        Binding(get: { model.type }, set: { model.type = $0 })
    }

    static func axisBinding(_ choice: AxisChoice, _ model: ChartSheetModel) -> Binding<Wiretuner_Doc_V1_AxisOptions> {
        Binding(get: { choice == .x ? model.xAxis : model.yAxis }, set: { if choice == .x { model.xAxis = $0 } else { model.yAxis = $0 } })
    }

    static func opening(_ choice: AxisChoice, _ binding: Binding<AxisChoice?>) -> () -> Void {
        { binding.wrappedValue = choice }
    }

    var dataTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Entry", text: $model.entry).onSubmit(Self.committing(model)).accessibilityIdentifier("chart.entry")
                Button("Undo", action: Self.action(.undo, model)).disabled(model.history.isEmpty).accessibilityIdentifier("chart.undo")
                Button("Import…", action: Self.importing(model)).accessibilityIdentifier("chart.import")
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(Array(model.grid.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { column, text in
                                let position = ChartSheetModel.Position(row: row, column: column)
                                Button(action: Self.selecting(position, model)) {
                                    Text(text).frame(width: model.width(of: column), height: 18, alignment: .leading).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .background(model.active == position ? Color.accentColor.opacity(0.3) : model.selected.contains(position) ? Color.accentColor.opacity(0.15) : Color.clear)
                            }
                        }
                    }
                }
            }
            .frame(height: 200)
            .accessibilityIdentifier("chart.grid")
            HStack {
                Button("←", action: Self.moving(0, -1, model))
                Button("→", action: Self.moving(0, 1, model))
                Button("↑", action: Self.moving(-1, 0, model))
                Button("↓", action: Self.moving(1, 0, model))
                Spacer()
                Button("Cut", action: Self.action(.cut, model)).accessibilityIdentifier("chart.cut")
                Button("Copy", action: Self.action(.copy, model)).accessibilityIdentifier("chart.copy")
                Button("Paste", action: Self.action(.paste, model)).accessibilityIdentifier("chart.paste")
                Button("Transpose", action: Self.action(.transpose, model)).accessibilityIdentifier("chart.transpose")
                Button("Switch XY", action: Self.action(.switchXY, model)).disabled(!model.isScatter).accessibilityIdentifier("chart.switchXY")
            }
            HStack {
                Stepper("Decimal precision: \(model.decimalPrecision)", value: $model.decimalPrecision, in: 0...10).accessibilityIdentifier("chart.precision")
                Toggle("Thousands separator", isOn: $model.thousandsSeparator).accessibilityIdentifier("chart.separator")
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.red) }
        }
    }

    var typeTab: some View {
        Form {
            Picker("Type", selection: Self.typeBinding(model)) {
                ForEach(ChartSheetModel.types, id: \.title) { Text($0.title).tag($0.type) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("chart.type")
            TextField("Column width (%)", value: $model.options.columnWidth, format: .number).accessibilityIdentifier("chart.columnWidth")
            TextField("Cluster width (%)", value: $model.options.clusterWidth, format: .number).accessibilityIdentifier("chart.clusterWidth")
            TextField("Separation", value: $model.options.pieSeparation, format: .number).accessibilityIdentifier("chart.separation")
            Picker("Data markers", selection: $model.options.markers) {
                ForEach(Self.markers, id: \.1) { Text($0.1).tag($0.0) }
            }
            Toggle("Data numbers in chart", isOn: $model.options.dataNumbers)
            Toggle("Drop shadow", isOn: $model.options.dropShadow)
            Toggle("Legends across top", isOn: $model.options.legendsAcrossTop)
            Picker("Axis display", selection: $model.options.axisDisplay) {
                ForEach(Self.axisDisplays, id: \.1) { Text($0.1).tag($0.0) }
            }
            .disabled(!model.axesEnabled)
            Toggle("Gridlines: X axis", isOn: $model.options.gridlinesX).disabled(!model.axesEnabled)
            Toggle("Gridlines: Y axis", isOn: $model.options.gridlinesY).disabled(!model.axesEnabled)
            HStack {
                Button("X Axis…", action: Self.opening(.x, $axis)).disabled(!model.axesEnabled).accessibilityIdentifier("chart.xAxis")
                Button("Y Axis…", action: Self.opening(.y, $axis)).disabled(!model.axesEnabled).accessibilityIdentifier("chart.yAxis")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tab", selection: $model.tab) {
                ForEach(ChartSheetModel.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.tab == .data { dataTab } else { typeTab }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(model, close: close)).keyboardShortcut(.cancelAction)
                Button("Apply", action: Self.action(.apply, model)).accessibilityIdentifier("chart.apply")
                Button("OK", action: Self.finishing(model, close: close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("chart.ok")
            }
        }
        .toggleStyle(.checkbox)
        .padding(16)
        .frame(width: 560)
        .sheet(item: $axis) { choice in ChartAxisSheet(axis: Self.axisBinding(choice, model), title: choice == .x ? "X Axis" : "Y Axis") { axis = nil } }
    }
}

/// The X and Y Axis sheets: calculated or manual range, tick marks, prefix and suffix.
struct ChartAxisSheet: View {
    @Binding var axis: Wiretuner_Doc_V1_AxisOptions
    let title: String
    let close: () -> Void

    static let ticks: [(Wiretuner_Doc_V1_ChartTickStyle, String)] = [(.none, "None"), (.across, "Across"), (.inside, "Inside"), (.outside, "Outside")]

    var body: some View {
        Form {
            Text(title).font(.headline)
            Picker("Values", selection: $axis.manual) {
                Text("Calculate from data").tag(false)
                Text("Manual").tag(true)
            }
            .accessibilityIdentifier("chartAxis.manual")
            if axis.manual {
                TextField("Minimum", value: $axis.minimum, format: .number)
                TextField("Maximum", value: $axis.maximum, format: .number)
                TextField("Between", value: $axis.between, format: .number)
            }
            Picker("Major", selection: $axis.major) { ForEach(Self.ticks, id: \.1) { Text($0.1).tag($0.0) } }
            Picker("Minor", selection: $axis.minor) { ForEach(Self.ticks, id: \.1) { Text($0.1).tag($0.0) } }
            Stepper("Count: \(axis.minorCount)", value: $axis.minorCount, in: 0...20)
            TextField("Prefix", text: $axis.prefix).accessibilityIdentifier("chartAxis.prefix")
            TextField("Suffix", text: $axis.suffix).accessibilityIdentifier("chartAxis.suffix")
            HStack {
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
