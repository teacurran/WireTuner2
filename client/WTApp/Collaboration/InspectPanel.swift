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
    var notation: SnippetNotation = .hex
    var unit: SnippetUnit = .pixels
    var scale: Double = 1
    var tab: Tab = .svg
    private(set) var revision = 0
    /// What the last copy put on the pasteboard ("Copied CSS").
    private(set) var copied: String?

    init() {}

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
    static func copyingPNG(_ model: InspectPanelModel, _ scale: Double) -> () -> Void { { model.copyPNG(scale: scale) } }

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
                        }
                        .accessibilityIdentifier("inspect.scale")
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
