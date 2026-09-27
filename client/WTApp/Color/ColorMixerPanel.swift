import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Color Mixer's state and actions (color-mixer.adoc; COLOR-008, with COLOR-023's P3 and
/// OKLCH modes): the mode, the new colour and the original it started from (the split well), the
/// sliders' values in the mode's units, the colour field, *Web Safe*, the gamut indicator,
/// btn:[Apply] (to the selection's Fill, Stroke or Both), btn:[Add to Swatches] (the sheet, or
/// kbd:[Cmd]-click with the last spot/process choice and the default name), *Apply as you mix*,
/// the macOS Colors panel, drops in and drags out.  The mode, the colours and the last spot
/// choice persist on this Mac.
@MainActor
@Observable
final class ColorMixerModel {
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case cmyk, rgb, p3, oklch, hls, grayscale, system
        var id: String { rawValue }

        var title: String {
            switch self {
            case .cmyk: "CMYK"
            case .rgb: "RGB"
            case .p3: "P3"
            case .oklch: "OKLCH"
            case .hls: "HLS"
            case .grayscale: "Grayscale"
            case .system: "System"
            }
        }

        /// The mode a colour in `space` is shown in (a Lab colour in OKLCH).
        static func of(_ space: RenderColor.Space) -> Mode {
            switch space {
            case .cmyk: .cmyk
            case .sRGB: .rgb
            case .displayP3: .p3
            case .lab, .oklab: .oklch
            }
        }
    }

    /// One slider: its title, range and unit (the field shows the value in it).
    struct Component: Hashable {
        let title: String
        let range: ClosedRange<Double>
        let unit: String
    }

    let workspace: ColorWorkspace
    private(set) var mode: Mode
    /// The new colour (the right half of the well).
    private(set) var current: RenderColor
    /// The colour mixing started from (the left half); nil before anything was loaded.
    private(set) var original: RenderColor?
    /// The swatch the original came from: its colour is re-read when someone edits it.
    private(set) var loadedSwatch: OpID?
    /// The sliders' values in the mode's units.
    private(set) var values: [Double] = []
    /// *Apply as you mix*: a slider drag bound to the selection writes one change per drag.
    var live = false
    /// The Add sheet's last spot/process choice (kbd:[Cmd]-click reuses it).
    private(set) var lastSpot = false
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var dragging = false
    /// The macOS Colors panel, when *System* is showing it.
    @ObservationIgnored var colorPanel: NSColorPanel?
    @ObservationIgnored private lazy var panelTarget = ColorPanelTarget(model: self)

    static let defaultsKey = "wt.colors.mixer"
    static let addSheet = "mixer.add-sheet"

    init(workspace: ColorWorkspace, defaults: UserDefaults? = nil) {
        self.workspace = workspace
        self.defaults = defaults
        let saved = defaults.flatMap { $0.data(forKey: Self.defaultsKey) }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        let opening: RenderColor = workspace.defaultSpace == .sRGB ? RenderColor(red: 0, green: 0, blue: 0) : RenderColor(displayP3Red: 0, green: 0, blue: 0)
        current = saved.flatMap { ColorValues.cachedColor($0.current) } ?? opening
        original = saved?.original.flatMap(ColorValues.cachedColor)
        mode = saved?.mode ?? Mode.of(opening.space)
        lastSpot = saved?.lastSpot ?? false
        values = Self.values(of: current, in: mode, defaultSpace: workspace.defaultSpace)
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var mode: Mode
        var current: Data
        var original: Data?
        var lastSpot: Bool
    }

    private func save() {
        let saved = Saved(mode: mode, current: ColorValues.cached(current), original: original.map(ColorValues.cached), lastSpot: lastSpot)
        defaults?.set(try? JSONEncoder().encode(saved), forKey: Self.defaultsKey)
    }

    // MARK: Modes and components

    static func components(_ mode: Mode) -> [Component] {
        switch mode {
        case .cmyk: ["C", "M", "Y", "K"].map { Component(title: $0, range: 0...100, unit: "%") }
        case .rgb, .p3: ["R", "G", "B"].map { Component(title: $0, range: 0...255, unit: "") }
        case .oklch: [Component(title: "L", range: 0...100, unit: "%"), Component(title: "C", range: 0...0.4, unit: ""), Component(title: "H", range: 0...360, unit: "°")]
        case .hls: [Component(title: "H", range: 0...360, unit: "°"), Component(title: "L", range: 0...100, unit: "%"), Component(title: "S", range: 0...100, unit: "%")]
        case .grayscale: [Component(title: "K", range: 0...100, unit: "%")]
        case .system: []
        }
    }

    var components: [Component] { Self.components(mode) }

    /// `color`'s slider values in `mode`.
    static func values(of color: RenderColor, in mode: Mode, defaultSpace: RenderColor.Space) -> [Double] {
        switch mode {
        case .cmyk:
            let c = color.converted(to: .cmyk).clampedToSpace.components
            return [c.x, c.y, c.z, c.w].map { $0 * 100 }
        case .rgb, .p3:
            let c = color.converted(to: mode == .rgb ? .sRGB : .displayP3).clampedToSpace.components
            return [c.x, c.y, c.z].map { $0 * 255 }
        case .oklch:
            let lab = color.converted(to: .oklab).components
            let lch = WTColor.Math.oklch(fromOKLab: SIMD3(lab.x, lab.y, lab.z))
            return [lch.x * 100, lch.y, lch.z]
        case .hls:
            let hls = ColorModels.hls(color, in: ColorModels.rgbSpace(of: color, fallback: defaultSpace))
            return [hls.hue, hls.lightness * 100, hls.saturation * 100]
        case .grayscale:
            if color.space == .cmyk, color.components.x == 0, color.components.y == 0, color.components.z == 0 { return [color.components.w * 100] }
            let rgb = color.srgb
            return [(1 - (0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z)) * 100]
        case .system:
            return []
        }
    }

    /// The colour `values` make in `mode`.
    static func color(_ values: [Double], in mode: Mode, base: RenderColor, defaultSpace: RenderColor.Space) -> RenderColor {
        switch mode {
        case .cmyk: return RenderColor(cyan: values[0] / 100, magenta: values[1] / 100, yellow: values[2] / 100, black: values[3] / 100)
        case .rgb: return RenderColor(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255)
        case .p3: return RenderColor(displayP3Red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255)
        case .oklch: return RenderColor(oklchL: values[0] / 100, chroma: values[1], hue: values[2])
        case .hls:
            let space = ColorModels.rgbSpace(of: base, fallback: defaultSpace)
            return ColorModels.color(ColorModels.HLS(hue: values[0], lightness: values[1] / 100, saturation: values[2] / 100), in: space)
        case .grayscale: return RenderColor(cyan: 0, magenta: 0, yellow: 0, black: values[0] / 100)
        case .system: return base
        }
    }

    /// A mode button: *System* opens the Colors panel; the others show that mode's sliders.
    func select(_ mode: Mode) {
        self.mode = mode
        values = Self.values(of: current, in: mode, defaultSpace: workspace.defaultSpace)
        if mode == .system { openColorPanel() }
        save()
    }

    /// A slider or field: component `index` set to `value` (clamped to its range).
    func set(_ index: Int, to value: Double) {
        let components = self.components
        guard components.indices.contains(index) else { return }
        values[index] = min(max(value, components[index].range.lowerBound), components[index].range.upperBound)
        current = Self.color(values, in: mode, base: current, defaultSpace: workspace.defaultSpace)
        save()
        if live, dragging { workspace.apply(ColorResolver.inline(current)) }
    }

    /// A slider drag begins (`true`) or ends: with *Apply as you mix* on, the selection previews
    /// the colour as it is mixed and the drag is written as one change on mouse-up (D-076).
    func dragging(_ editing: Bool) {
        guard live, let document = workspace.document else { return }
        guard editing != dragging else { return }
        dragging = editing
        if editing { document.beginGesture() } else { document.endGesture() }
    }

    /// Replaces the new colour (a pick, a drop, a field entry): the mode follows its space.
    func take(_ color: RenderColor, switchMode: Bool = true) {
        current = color
        if switchMode, mode != .system { mode = Mode.of(color.space) }
        values = Self.values(of: current, in: mode, defaultSpace: workspace.defaultSpace)
        save()
    }

    // MARK: The field and Web Safe

    /// The colour field's text: the new colour in its own form (`#E63946`, `p3(…)`, `oklch(…)`).
    var fieldText: String { ColorText.field(current) }

    /// The field's entry: a colour switches the Mixer to its space; anything else is refused.
    @discardableResult
    func submit(_ text: String) -> Bool {
        guard let color = ColorText.parse(text.hasPrefix("#") || text.contains("(") || text.contains(" ") ? text : "#" + text) else { return false }
        take(color)
        return true
    }

    /// btn:[Web Safe]: the nearest of the 216 web-safe colours (sRGB).
    func webSafe() {
        take(ColorModels.webSafe(current))
    }

    /// *sRGB*, *P3* or *Out of gamut*.
    var gamut: String {
        switch WTColor.Gamut.indicator(for: current) {
        case .sRGB: "sRGB"
        case .displayP3: "P3"
        case .outOfGamut: "Out of gamut"
        }
    }

    // MARK: Loading

    /// Loads a colour to inspect: the original and the new colour become it, in its own space.
    func load(_ color: RenderColor, swatch: OpID? = nil) {
        original = color
        loadedSwatch = swatch
        take(color)
    }

    /// A drop on the well.
    @discardableResult
    func drop(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace), let color = payload.color else { return false }
        let swatch = ColorResolver.swatch(of: payload.ref).flatMap { payload.document == workspace.document?.id ? $0 : nil }
        load(color, swatch: swatch)
        return true
    }

    /// The original as it is now: a loaded swatch someone has since edited shows its new colour.
    var originalNow: RenderColor? {
        if let loadedSwatch, let color = workspace.swatches?.list.resolver.color(ofSwatch: loadedSwatch) { return color }
        return original
    }

    /// A click on the left half copies the original back to the right.
    func restoreOriginal() {
        guard let originalNow else { return }
        take(originalNow)
    }

    /// Dragging the new (or original) colour carries it as an unnamed colour.
    func dragPayload(original: Bool = false) -> ColorRefPasteboard {
        let color = original ? originalNow ?? current : current
        return ColorRefPasteboard(ref: ColorResolver.inline(color), color: color, document: workspace.document?.id ?? "")
    }

    // MARK: Applying and adding

    /// btn:[Apply]: the new colour, unnamed, on the selection's Fill, Stroke or Both.
    @discardableResult
    func apply() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.apply(ColorResolver.inline(current))
    }

    /// btn:[Add to Swatches]: the naming sheet, or with kbd:[Cmd] the default name and the last
    /// spot/process choice at once.
    @discardableResult
    func addToSwatches(quickly: Bool = NSEvent.modifierFlags.contains(.command)) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if quickly { return add(name: "", spot: lastSpot) }
        workspace.present(AddSwatchSheet(color: current, spot: lastSpot, finish: finishAdding), title: "Add to Swatches", identifier: Self.addSheet)
        return nil
    }

    /// The sheet's answer: nil for btn:[Cancel].
    func finishAdding(_ answer: AddSwatchSheet.Answer?) {
        workspace.dismiss(Self.addSheet)
        guard let answer else { return }
        add(name: answer.name, spot: answer.spot)
    }

    @discardableResult
    func add(name: String, spot: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        lastSpot = spot
        save()
        return workspace.perform(AddSwatch(current, name: name, spot: spot))
    }

    // MARK: The macOS Colors panel

    /// *System*: the Colors panel in continuous mode, reporting to the Mixer.
    func openColorPanel(_ panel: NSColorPanel = NSColorPanel.shared) {
        colorPanel = panel
        panel.isContinuous = true
        panel.setTarget(panelTarget)
        panel.setAction(#selector(ColorPanelTarget.changeColor(_:)))
        panel.color = ColorDrag.nsColor(current)
        panel.orderFront(nil)
    }

    /// A pick in the Colors panel: Display P3, or gamut-mapped sRGB when that is the default.
    func take(systemColor color: NSColor) {
        take(ColorDrag.color(color, defaultSpace: workspace.defaultSpace), switchMode: false)
    }
}

/// Receives the Colors panel's `changeColor(_:)` for the Mixer.
@MainActor
final class ColorPanelTarget: NSObject {
    weak var model: ColorMixerModel?

    init(model: ColorMixerModel) {
        self.model = model
    }

    @objc func changeColor(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { return }
        model?.take(systemColor: panel.color)
    }
}

/// The naming sheet of btn:[Add to Swatches] (swatches.adoc, "Adding colors").
struct AddSwatchSheet: View {
    struct Answer: Equatable {
        var name: String
        var spot: Bool
    }

    let color: RenderColor
    let finish: (Answer?) -> Void
    @State private var name: String
    @State private var spot: Bool

    init(color: RenderColor, spot: Bool, finish: @escaping (Answer?) -> Void) {
        self.color = color
        self.finish = finish
        _name = State(initialValue: ColorText.defaultName(color))
        _spot = State(initialValue: spot)
    }

    static func adding(_ name: Binding<String>, _ spot: Binding<Bool>, _ finish: @escaping (Answer?) -> Void) -> () -> Void {
        { finish(Answer(name: name.wrappedValue, spot: spot.wrappedValue)) }
    }

    static func cancelling(_ finish: @escaping (Answer?) -> Void) -> () -> Void {
        { finish(nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColorChipView(chip: .color(color), size: CGSize(width: 32, height: 24))
                TextField("Name", text: $name).accessibilityIdentifier("add-swatch.name")
            }
            Picker("Type", selection: $spot) {
                Text("Process").tag(false)
                Text("Spot").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("add-swatch.spot")
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancelling(finish)).keyboardShortcut(.cancelAction)
                Button("Add", action: Self.adding($name, $spot, finish)).keyboardShortcut(.defaultAction).accessibilityIdentifier("add-swatch.add")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - The panel body

/// The Color Mixer body: mode buttons, sliders with fields, the colour field (RGB, P3, OKLCH),
/// *Web Safe*, the split well with the gamut indicator, btn:[Apply] and btn:[Add to Swatches].
struct ColorMixerBody: View {
    let model: ColorMixerModel

    static func selecting(_ mode: ColorMixerModel.Mode, _ model: ColorMixerModel) -> () -> Void {
        { model.select(mode) }
    }

    static func binding(_ index: Int, _ model: ColorMixerModel) -> Binding<Double> {
        Binding(get: { model.values.indices.contains(index) ? model.values[index] : 0 }, set: { model.set(index, to: $0) })
    }

    static func fieldCommit(_ index: Int, _ model: ColorMixerModel) -> (Double) -> Void {
        { model.set(index, to: $0) }
    }

    static func modeBinding(_ model: ColorMixerModel) -> Binding<ColorMixerModel.Mode> {
        Binding(get: { model.mode }, set: { model.select($0) })
    }

    static func dropping(_ model: ColorMixerModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.drop(from: pasteboard) }
    }

    static func dragging(_ model: ColorMixerModel, original: Bool) -> () -> NSItemProvider {
        { ColorDrag.itemProvider(model.dragPayload(original: original)) }
    }

    static func liveBinding(_ model: ColorMixerModel) -> Binding<Bool> {
        Binding(get: { model.live }, set: { model.live = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: Self.modeBinding(model)) {
                ForEach(ColorMixerModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .accessibilityIdentifier("mixer.mode")
            ForEach(Array(model.components.enumerated()), id: \.offset) { index, component in
                HStack {
                    Text(component.title).frame(width: 14)
                    Slider(value: Self.binding(index, model), in: component.range, onEditingChanged: model.dragging)
                        .accessibilityIdentifier("mixer.slider.\(component.title)")
                    CommitField(title: component.title, value: model.values[index],
                                identifier: "mixer.field.\(component.title)", commit: Self.fieldCommit(index, model))
                        .frame(width: 56)
                }
            }
            if [.rgb, .p3, .oklch].contains(model.mode) {
                MixerFieldView(text: model.fieldText, submit: model.submit)
                if model.mode == .rgb {
                    Button("Web Safe", action: model.webSafe).accessibilityIdentifier("mixer.web-safe")
                }
            }
            HStack(spacing: 0) {
                if model.workspace.splitColorBox {
                    Button(action: model.restoreOriginal) { ColorChipView(chip: model.originalNow.map(ColorWellModel.Chip.color) ?? .none, size: CGSize(width: 40, height: 28)) }
                        .buttonStyle(.plain)
                        .onDrag(Self.dragging(model, original: true))
                        .accessibilityIdentifier("mixer.original")
                }
                ColorChipView(chip: .color(model.current), size: CGSize(width: model.workspace.splitColorBox ? 40 : 80, height: 28))
                    .onDrag(Self.dragging(model, original: false))
                    .accessibilityIdentifier("mixer.current")
                Text(model.gamut).font(.caption).padding(.leading, 8).accessibilityIdentifier("mixer.gamut")
            }
            .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(model))
            .panelContextMenu(.colorBox)
            Toggle("Apply as you mix", isOn: Self.liveBinding(model)).accessibilityIdentifier("mixer.live")
            HStack {
                Button("Apply", action: ColorAction.run(model.apply)).accessibilityIdentifier("mixer.apply")
                Button("Add to Swatches", action: ColorAction.run(model.addToSwatchesFromButton)).accessibilityIdentifier("mixer.add")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension ColorMixerModel {
    /// The button's action: kbd:[Cmd] read as it is clicked.
    @discardableResult
    func addToSwatchesFromButton() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        addToSwatches()
    }
}

/// The colour field: shows the new colour's form; kbd:[Return] takes an entry.
struct MixerFieldView: View {
    let text: String
    let submit: (String) -> Bool
    @State private var entry = ""

    static func submitting(_ entry: Binding<String>, _ submit: @escaping (String) -> Bool) -> () -> Void {
        { _ = submit(entry.wrappedValue) }
    }

    static func syncing(_ entry: Binding<String>, _ text: String) -> () -> Void {
        { entry.wrappedValue = text }
    }

    var body: some View {
        TextField("Color", text: $entry)
            .onSubmit(Self.submitting($entry, submit))
            .onAppear(perform: Self.syncing($entry, text))
            .onChange(of: text, Self.syncing($entry, text))
            .accessibilityIdentifier("mixer.field")
    }
}
