import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Graphic Hose sheet (graphic-hose.adoc, "Choosing a hose", "Hose options", "Making and
/// editing hoses"; DRAW-040): the *Hose* view -- the *Sets* pop-up (the document's sets, a
/// separator, the library's, then *New…*, *Duplicate…*, *Rename…*, *Delete…* and *Restore default
/// hoses*), the name prompt with *In this document* / *In my library*, the *Contents* pop-up with
/// its preview, btn:[Paste In] and btn:[Remove] -- and the *Options* view.  `.wthose` files
/// dropped on it go into the library.  It follows the document, so a collaborator's new object or
/// option shows while it is open.
struct GraphicHoseSheet: View {
    @Bindable var model: GraphicHoseModel
    let dismiss: @MainActor () -> Void

    static func choosing(_ choice: GraphicHoseModel.Choice, _ model: GraphicHoseModel) -> () -> Void {
        { model.choose(choice) }
    }

    static func naming(_ naming: GraphicHoseModel.Naming, _ model: GraphicHoseModel) -> () -> Void {
        { model.beginNaming(naming) }
    }

    static func dropping(_ model: GraphicHoseModel) -> ([NSItemProvider]) -> Bool {
        { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importBundles([url]) }
                }
            }
            return !providers.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Graphic Hose").font(.headline)
            Picker("", selection: $model.page) {
                ForEach(GraphicHoseModel.Page.allCases, id: \.self) { page in Text(page.title).tag(page) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("hose.page")
            if model.page == .hose { HoseSetView(model: model) } else { HoseOptionsView(model: model) }
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.red).accessibilityIdentifier("hose.failure")
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction).accessibilityIdentifier("hose.done")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: Self.dropping(model))
    }
}

/// The *Hose* view.
struct HoseSetView: View {
    @Bindable var model: GraphicHoseModel

    /// btn:[Paste In] reads the window's clipboard.
    static func pasting(_ model: GraphicHoseModel) -> () -> Void {
        { model.pasteIn() }
    }

    static func contents(_ model: GraphicHoseModel) -> Binding<Int> {
        Binding(get: { model.contentsIndex }, set: { model.contentsIndex = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sets")
                Menu(model.choiceName.isEmpty ? "No hose" : model.choiceName) {
                    ForEach(model.documentSets, id: \.id) { set in
                        Button(set.name, action: GraphicHoseSheet.choosing(.document(set.id), model))
                    }
                    Divider()
                    ForEach(model.entries, id: \.url) { entry in
                        Button(entry.name, action: GraphicHoseSheet.choosing(.library(entry.url), model))
                    }
                    Divider()
                    Button("New…", action: GraphicHoseSheet.naming(.new, model))
                    Button("Duplicate…", action: GraphicHoseSheet.naming(.duplicate, model)).disabled(model.choice == nil)
                    Button("Rename…", action: GraphicHoseSheet.naming(.rename, model)).disabled(model.choice == nil)
                    Button("Delete…", action: ColorAction.run(model.delete)).disabled(model.choice == nil)
                    Button("Restore default hoses", action: ColorAction.run(model.restoreDefaults))
                }
                .accessibilityIdentifier("hose.sets")
            }
            if model.naming != nil { HoseNamingView(model: model) }
            HStack {
                Text("Contents")
                Picker("", selection: Self.contents(model)) {
                    ForEach(Array(model.contents.enumerated()), id: \.offset) { index, title in Text(title).tag(index) }
                }
                .labelsHidden()
                .accessibilityIdentifier("hose.contents")
            }
            Group {
                if let image = model.contentsPreview() {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("No objects").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 100)
            .accessibilityIdentifier("hose.preview")
            if let extras = model.shown?.set.extras, !extras.isEmpty {
                Text("Only the first ten objects are sprayed.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Paste In", action: Self.pasting(model)).disabled(model.choice == nil).accessibilityIdentifier("hose.paste")
                Button("Remove", action: ColorAction.run(model.removeObject)).disabled(model.contents.isEmpty).accessibilityIdentifier("hose.remove")
            }
        }
    }
}

/// The name prompt of *New…*, *Duplicate…* and *Rename…*.
struct HoseNamingView: View {
    @Bindable var model: GraphicHoseModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $model.nameText).accessibilityIdentifier("hose.name")
            if model.naming != .rename {
                Picker("Keep", selection: $model.location) {
                    ForEach(GraphicHoseModel.Location.allCases, id: \.self) { location in Text(location.title).tag(location) }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("hose.location")
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelNaming)
                Button("Save", action: ColorAction.run(model.commitNaming)).accessibilityIdentifier("hose.save")
            }
        }
        .padding(8)
        .background(SwiftUI.Color.secondary.opacity(0.1))
    }
}

/// The *Options* view: order, spacing, scale and rotation, saved with the set (one option per
/// change).
struct HoseOptionsView: View {
    let model: GraphicHoseModel

    static let orders: [(Wiretuner_Doc_V1_HoseOrder, String)] = [(.loop, "Loop"), (.backAndForth, "Back and forth"), (.random, "Random")]
    static let spacings: [(Wiretuner_Doc_V1_HoseSpacing, String)] = [(.grid, "Grid"), (.variable, "Variable"), (.random, "Random")]
    static let scales: [(Wiretuner_Doc_V1_HoseScale, String)] = [(.uniform, "Uniform"), (.random, "Random")]
    static let rotations: [(Wiretuner_Doc_V1_HoseRotation, String)] = [(.uniform, "Uniform"), (.incremental, "Incremental"), (.random, "Random")]

    /// The shown set's options as read (unset enums as their defaults).
    static func options(_ model: GraphicHoseModel) -> HoseSprayOptions {
        model.shown?.set.options ?? HoseSprayOptions()
    }

    static func order(_ model: GraphicHoseModel) -> Binding<Wiretuner_Doc_V1_HoseOrder> {
        Binding(get: {
            switch options(model).order {
            case .loop: .loop
            case .backAndForth: .backAndForth
            case .random: .random
            }
        }, set: { model.setOption(.order($0)) })
    }

    static func spacing(_ model: GraphicHoseModel) -> Binding<Wiretuner_Doc_V1_HoseSpacing> {
        Binding(get: {
            switch options(model).spacing {
            case .grid: .grid
            case .variable: .variable
            case .random: .random
            }
        }, set: { model.setOption(.spacing($0)) })
    }

    static func scale(_ model: GraphicHoseModel) -> Binding<Wiretuner_Doc_V1_HoseScale> {
        Binding(get: { options(model).scale == .random ? .random : .uniform }, set: { model.setOption(.scale($0)) })
    }

    static func rotation(_ model: GraphicHoseModel) -> Binding<Wiretuner_Doc_V1_HoseRotation> {
        Binding(get: {
            switch options(model).rotation {
            case .uniform: .uniform
            case .incremental: .incremental
            case .random: .random
            }
        }, set: { model.setOption(.rotation($0)) })
    }

    /// A number field for an option, clamped to its range; the angle is shown in degrees.
    static func number(_ model: GraphicHoseModel, read: @escaping (HoseSprayOptions) -> Double, range: ClosedRange<Double>,
                       write: @escaping (Double) -> HoseOption) -> Binding<Double> {
        Binding(get: { read(options(model)) }, set: { model.setOption(write(min(max($0, range.lowerBound), range.upperBound))) })
    }

    static func gridSize(_ model: GraphicHoseModel) -> Binding<Double> {
        number(model, read: \.gridSize, range: 1 ... 1000) { .gridSize($0) }
    }

    static func spacingAmount(_ model: GraphicHoseModel) -> Binding<Double> {
        number(model, read: \.spacingAmount, range: 0 ... 200) { .spacingAmount($0) }
    }

    static func scalePercent(_ model: GraphicHoseModel) -> Binding<Double> {
        number(model, read: \.scalePercent, range: 1 ... 200) { .scalePercent($0) }
    }

    static func angle(_ model: GraphicHoseModel) -> Binding<Double> {
        number(model, read: { $0.angle * 180 / .pi }, range: -360 ... 360) { .angle($0 * .pi / 180) }
    }

    var body: some View {
        let spacing = Self.options(model).spacing
        Form {
            Picker("Order", selection: Self.order(model)) { ForEach(Self.orders, id: \.0) { Text($0.1).tag($0.0) } }
                .accessibilityIdentifier("hose.order")
            Picker("Spacing", selection: Self.spacing(model)) { ForEach(Self.spacings, id: \.0) { Text($0.1).tag($0.0) } }
                .accessibilityIdentifier("hose.spacing")
            if spacing == .grid {
                TextField("Grid size", value: Self.gridSize(model), format: .number).accessibilityIdentifier("hose.grid-size")
            } else {
                TextField(spacing == .random ? "Deviation" : "Amount", value: Self.spacingAmount(model), format: .number)
                    .accessibilityIdentifier("hose.spacing-amount")
            }
            Picker("Scale", selection: Self.scale(model)) { ForEach(Self.scales, id: \.0) { Text($0.1).tag($0.0) } }
                .accessibilityIdentifier("hose.scale")
            TextField("Scale %", value: Self.scalePercent(model), format: .number).accessibilityIdentifier("hose.scale-percent")
            Picker("Rotation", selection: Self.rotation(model)) { ForEach(Self.rotations, id: \.0) { Text($0.1).tag($0.0) } }
                .accessibilityIdentifier("hose.rotation")
            TextField("Angle", value: Self.angle(model), format: .number).accessibilityIdentifier("hose.angle")
        }
        .disabled(model.choice == nil)
    }
}
