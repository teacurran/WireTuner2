import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// The Inspect panel (inspect.adoc, "The Inspect panel", "Copying as code", "Copying as PNG";
/// COLLAB-037's snippet half over COLLAB-036's library): menu:Window[Inspect] reads the front
/// window's selection -- one object, or several as one group -- and shows its *Layout* (position of
/// the top-left corner on its page and size), the *Code* tabs (SVG, CSS, Swift from WTInterchange's
/// snippets, each with btn:[Copy]) and btn:[PNG 1×] / btn:[PNG 2×] / btn:[PNG 3×], with the
/// *Notation*, *Unit* and *Scale* pop-ups every value follows.
@MainActor
@Observable
final class InspectPanelModel {
    enum Tab: String, CaseIterable, Identifiable {
        case svg = "SVG"
        case css = "CSS"
        case swift = "Swift"
        var id: String { rawValue }
    }

    static let scales: [Double] = [1, 2, 3]
    static let notations: [(SnippetNotation, String)] = [(.hex, "Hex"), (.rgb, "rgb()"), (.displayP3, "Display P3"), (.oklch, "OKLCH"), (.cmyk, "CMYK")]
    static let units: [(SnippetUnit, String)] = [(.points, "Points"), (.pixels, "Pixels"), (.millimeters, "Millimeters"), (.centimeters, "Centimeters"),
                                                  (.inches, "Inches")]

    @ObservationIgnored var window: @MainActor () -> DocumentWindowController? = { nil }
    /// A blob's bytes by SHA-256 when it is on this Mac (the placed images a snippet draws).
    @ObservationIgnored var blob: (Data) -> Data? = { _ in nil }
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    /// Where the unit and scale are remembered on this Mac (`inspect.unit`, `inspect.scale`).
    @ObservationIgnored let defaults: UserDefaults?
    /// Chooses where *Option*-click on a PNG button saves; nil when cancelled.
    @ObservationIgnored var chooseDestination: @MainActor (String) -> URL? = InspectPanelModel.savePanel
    /// Whether kbd:[Option] is held (a PNG button saves instead of copying).
    @ObservationIgnored var optionDown: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    var notation: SnippetNotation = .hex
    var unit: SnippetUnit = .pixels {
        didSet { defaults?.set(unit.rawValue, forKey: Self.unitKey) }
    }
    var scale: Double = 1 {
        didSet { defaults?.set(scale, forKey: Self.scaleKey) }
    }

    /// A custom factor typed in the scale field, kept between 0.1× and 16×.
    func setCustomScale(_ value: Double) {
        scale = value.isFinite ? min(max(value, 0.1), 16) : 1
    }
    /// A scale as the pop-up shows it ("1.5×").
    static func scaleTitle(_ scale: Double) -> String {
        (scale.rounded() == scale ? "\(Int(scale))" : String(format: "%g", scale)) + "×"
    }

    static let unitKey = "inspect.unit"
    static let scaleKey = "inspect.scale"
    var tab: Tab = .svg
    private(set) var revision = 0
    /// What the last copy put on the pasteboard ("Copied CSS").
    private(set) var copied: String?

    /// `defaults` remembers the unit and scale (COLLAB-037's rest); nil keeps them for the panel's
    /// life only.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let raw = defaults?.string(forKey: Self.unitKey), let stored = SnippetUnit(rawValue: raw) { unit = stored }
        if let stored = defaults?.object(forKey: Self.scaleKey) as? Double, stored > 0 { scale = stored }
    }

    /// The selection or the document changed: the panel reads again.
    func touch() {
        revision += 1
        copied = nil
    }

    var options: SnippetOptions { SnippetOptions(notation: notation, unit: unit, scale: scale) }

    /// The selection as a snippet object: the one selected object, or every selected object as
    /// one group (drawn as the SVG and PNG snippets; the CSS and Swift ones say what they cannot
    /// express).  Nil with nothing selected.
    var object: SnippetObject? {
        _ = revision
        guard let window = window() else { return nil }
        let document = window.documentHandle
        let nodes = window.selection.selection.ids.map(\.opID)
        let objects = nodes.compactMap { ExportSnapshot.snippetObject($0, scene: document.scene, state: document.state, blob: blob) }
        guard let first = objects.first else { return nil }
        guard objects.count > 1 else { return first }
        var assets: [String: ExportAsset] = [:]
        for object in objects {
            for (id, asset) in object.assets where assets[id] == nil { assets[id] = asset }
        }
        return SnippetObject(name: "selection", shape: .other, item: .group(GroupItem(children: objects.map(\.item))), assets: assets,
                             swatchNames: first.swatchNames)
    }

    /// *Colors*, *Stroke*, *Fills*, *Effects*, *Typography* and *Text* (COLLAB-037's rest), in the
    /// notation, unit and scale.
    func readout(_ object: SnippetObject) -> SnippetReadout {
        SnippetReadout(object, options: options)
    }

    /// *Layout*: the top-left corner on the object's page and the size, in the unit.
    func layout(_ object: SnippetObject) -> [(label: String, value: String)] {
        let bounds = object.bounds
        let page = window()?.documentHandle.pageList.page(containing: bounds.center)?.rect ?? Rect(x: 0, y: 0, width: 0, height: 0)
        let origin = Point(x: page.minX, y: page.minY)
        return [
            ("X", unit.format(bounds.minX - origin.x, scale: scale)), ("Y", unit.format(bounds.minY - origin.y, scale: scale)),
            ("Width", unit.format(bounds.width, scale: scale)), ("Height", unit.format(bounds.height, scale: scale)),
        ]
    }

    /// The snippet of `tab`.
    func code(_ tab: Tab, for object: SnippetObject) -> String {
        switch tab {
        case .svg: SVGSnippet.make(object)
        case .css: CSSSnippet.make(object, options: options)
        case .swift: SwiftSnippet.make(object, options: options).text
        }
    }

    /// btn:[Copy] in a Code tab (and a click on a Layout value): the text on the pasteboard.
    @discardableResult
    func copy(_ text: String, what: String) -> Bool {
        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        copied = "Copied \(what)"
        return wrote
    }

    @discardableResult
    func copyCode(_ tab: Tab) -> Bool {
        guard let object else { return false }
        return copy(code(tab, for: object), what: tab.rawValue)
    }

    /// A PNG button: kbd:[Option]-click saves the PNG to a file, a click copies it.
    @discardableResult
    func png(scale: Double) -> Data? {
        optionDown() ? savePNG(scale: scale) : copyPNG(scale: scale)
    }

    /// kbd:[Option]-click on btn:[PNG 1×] … btn:[PNG 3×]: the PNG written to a chosen file.
    @discardableResult
    func savePNG(scale: Double) -> Data? {
        guard let object, let url = chooseDestination(PNGSnippet.fileName(object, scale: scale)) else { return nil }
        let data = PNGSnippet.make(object, scale: scale)
        do {
            try data.write(to: url, options: .atomic)
            copied = "Saved \(url.lastPathComponent)"
            return data
        } catch {
            copied = "The PNG could not be saved"
            return nil
        }
    }

    static func savePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// btn:[PNG 1×] … btn:[PNG 3×]: the selection as a PNG at `scale` on the pasteboard.
    @discardableResult
    func copyPNG(scale: Double) -> Data? {
        guard let object else { return nil }
        let data = PNGSnippet.make(object, scale: scale)
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        copied = "Copied \(PNGSnippet.fileName(object, scale: scale))"
        return data
    }
}

enum InspectPanel {
    static let id: PanelID = "inspect"
    static let group = "Inspect"

    static func descriptor(model: InspectPanelModel) -> PanelDescriptor {
        PanelDescriptor(id: id, title: "Inspect", icon: "ruler", defaultGroup: group, menuOrder: 74, helpSlug: "inspect") {
            InspectPanelBody(model: model)
        }
    }
}

struct InspectPanelBody: View {
    @Bindable var model: InspectPanelModel

    static func copying(_ model: InspectPanelModel, _ text: String, _ what: String) -> () -> Void { { model.copy(text, what: what) } }
    static func copyingCode(_ model: InspectPanelModel, _ tab: InspectPanelModel.Tab) -> () -> Void { { model.copyCode(tab) } }
    static func copyingPNG(_ model: InspectPanelModel, _ scale: Double) -> () -> Void { { model.png(scale: scale) } }
    static func customScale(_ model: InspectPanelModel) -> Binding<Double> {
        Binding(get: { model.scale }, set: { model.setCustomScale($0) })
    }

    /// A section of labelled values, each copied by a click.
    @ViewBuilder
    static func rows(_ title: String, _ rows: [SnippetReadout.Row], model: InspectPanelModel) -> some View {
        if !rows.isEmpty {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Button(action: copying(model, row.value.isEmpty ? row.label : row.value, row.label)) {
                    HStack(alignment: .top) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inspect.\(title.lowercased()).\(row.label)")
            }
        }
    }

    var body: some View {
        if let object = model.object {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Notation", selection: $model.notation) {
                            ForEach(InspectPanelModel.notations, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .accessibilityIdentifier("inspect.notation")
                        Picker("Unit", selection: $model.unit) {
                            ForEach(InspectPanelModel.units, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .accessibilityIdentifier("inspect.unit")
                        Picker("Scale", selection: $model.scale) {
                            ForEach(InspectPanelModel.scales, id: \.self) { Text("\(Int($0))×").tag($0) }
                            if !InspectPanelModel.scales.contains(model.scale) { Text(InspectPanelModel.scaleTitle(model.scale)).tag(model.scale) }
                        }
                        .accessibilityIdentifier("inspect.scale")
                        // A custom factor (inspect.adoc, "Units and scale").
                        TextField("Custom", value: Self.customScale(model), format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 48)
                            .accessibilityIdentifier("inspect.customScale")
                    }
                    .labelsHidden()
                    Text("Layout").font(.headline)
                    ForEach(model.layout(object), id: \.label) { row in
                        Button(action: Self.copying(model, row.value, row.label)) {
                            HStack {
                                Text(row.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(row.value).monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("inspect.layout.\(row.label)")
                    }
                    let readout = model.readout(object)
                    if !readout.colors.isEmpty {
                        Text("Colors").font(.headline)
                        ForEach(Array(readout.colors.enumerated()), id: \.offset) { _, row in
                            Button(action: Self.copying(model, row.value, row.name ?? "color")) {
                                HStack {
                                    SwiftUI.Circle().fill(SwiftUI.Color(cgColor: row.color.cgColor)).frame(width: 12, height: 12)
                                    Text(row.name ?? "").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(row.value).monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("inspect.color.\(row.value)")
                        }
                    }
                    Self.rows("Stroke", readout.stroke, model: model)
                    Self.rows("Fills", readout.fills, model: model)
                    Self.rows("Effects", readout.effects, model: model)
                    ForEach(Array(readout.typography.enumerated()), id: \.offset) { index, run in
                        Self.rows(readout.typography.count > 1 ? "Typography \(index + 1)" : "Typography", run, model: model)
                    }
                    if let text = readout.text {
                        Text("Text").font(.headline)
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("inspect.text")
                        Button("Copy Text", action: Self.copying(model, text, "text")).accessibilityIdentifier("inspect.copyText")
                    }
                    Text("Code").font(.headline)
                    Picker("Code", selection: $model.tab) {
                        ForEach(InspectPanelModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("inspect.tab")
                    Text(model.code(model.tab, for: object))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("inspect.code")
                    Button("Copy", action: Self.copyingCode(model, model.tab)).accessibilityIdentifier("inspect.copy")
                    Text("Export").font(.headline)
                    HStack {
                        ForEach(InspectPanelModel.scales, id: \.self) { scale in
                            Button("PNG \(Int(scale))×", action: Self.copyingPNG(model, scale)).accessibilityIdentifier("inspect.png.\(Int(scale))")
                        }
                    }
                    if let copied = model.copied {
                        Text(copied).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("inspect.copied")
                    }
                }
                .padding()
            }
        } else {
            Text("Select an object to inspect it.")
                .font(.callout).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("inspect.empty")
        }
    }
}
