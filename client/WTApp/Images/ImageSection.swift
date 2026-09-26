import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Object panel's image section (bitmaps.adoc, "Image properties in the Object panel"; IMG-016,
/// and IMG-025's crop fields): the kind with its mode, *File* with btn:[Links…], *Pixels*,
/// *Stored* and *Effective* resolution (the lock writes both axes; the effective value turns amber
/// below *Warn when image resolution is below*), *Scale* as a percentage and a width and height
/// (the lock keeps them proportional), *Color mode*, *Display alpha channel* for images with alpha,
/// and for bilevel and grayscale images *Transparent*, btn:[Edit ramp…] and the *Tint* well (the
/// image's `tint`, its one fill row), the crop in pixels with btn:[Reset], and the btn:[Info]
/// popover.  *Color settings* and btn:[Edit With…] are the sections beside it (CMS-013, IMG-019).
/// Every control is one change; values are read from the document on every render, so a remote
/// scale shows in *Effective* at once.  The readings are `WTModel.ImageDetails`.
@MainActor
struct ImageSectionModel {
    let panel: ObjectPanelModel
    let images: [ImageDetails]

    init?(_ panel: ObjectPanelModel) {
        let state = panel.document.state
        let images = panel.objects.compactMap { ImageDetails($0.id, in: state) }
        guard !images.isEmpty, images.count == panel.objects.count else { return nil }
        self.panel = panel
        self.images = images
    }

    var nodes: [OpID] { images.map(\.node) }
    /// The one image, when one is selected (the rows that read one picture).
    var one: ImageDetails? { images.count == 1 ? images[0] : nil }

    /// A value every image shares; nil when they differ.
    func shared<T: Equatable>(_ read: (ImageDetails) -> T) -> T? {
        let first = read(images[0])
        return images.allSatisfy { read($0) == first } ? first : nil
    }

    var kindLabel: String { shared(\.kindLabel) ?? "Images" }
    var showsAlpha: Bool { images.allSatisfy(\.hasAlpha) }
    var showsGray: Bool { images.allSatisfy(\.isGray) }
    var displayAlpha: MixedState { MixedState(images.map(\.displayAlpha)) }
    var transparent: MixedState { MixedState(images.map(\.transparent)) }
    var effectivePPI: Double? { shared { ($0.effectivePPI * 10).rounded() / 10 } }

    /// Whether any image is below `threshold` ppi.
    func warns(below threshold: Double) -> Bool { images.contains { $0.isBelow(threshold) } }

    // MARK: Commands (one change each)

    func setDisplayAlpha(_ on: Bool) -> any WTModel.Command { SetImageSetting(nodes, .displayAlpha(on)) }
    func setTransparent(_ on: Bool) -> any WTModel.Command { SetImageSetting(nodes, .transparentBackground(on)) }

    /// *Stored* resolution: both axes with the lock on, else the one typed.
    func setStored(_ ppi: Double, horizontal: Bool, locked: Bool) -> (any WTModel.Command)? {
        guard ppi > 0, ppi.isFinite else { return nil }
        if locked { return SetImageResolution(nodes, dpiX: ppi, dpiY: ppi) }
        return horizontal ? SetImageResolution(nodes, dpiX: ppi, dpiY: nil) : SetImageResolution(nodes, dpiX: nil, dpiY: ppi)
    }

    /// Each image scaled about its own top-left by `factors` (one "Scale" change).
    func scale(_ factors: (ImageDetails) -> (x: Double, y: Double)?) -> (any WTModel.Command)? {
        let state = panel.document.state
        let commands: [any WTModel.Command] = images.compactMap { image in
            guard let (x, y) = factors(image), x != 1 || y != 1, let bounds = Objects.bounds(of: image.node, in: state) else { return nil }
            return TransformObjects([image.node], matrix: .scale(x: x, y: y), about: Point(x: bounds.minX, y: bounds.minY), kind: .scale)
        }
        return commands.isEmpty ? nil : CommandBatch("Scale", commands)
    }

    /// *Scale* %: both axes with the lock on.
    func setScale(_ percent: Double, horizontal: Bool = true, locked: Bool) -> (any WTModel.Command)? {
        scale { $0.scaleFactors(toPercent: percent, horizontal: locked || horizontal, vertical: locked || !horizontal) }
    }

    /// The placed width or height, the other following with the lock on.
    func setSize(_ points: Double, width: Bool, locked: Bool) -> (any WTModel.Command)? {
        scale { $0.scaleFactors(toSize: points, width: width, locked: locked) }
    }

    /// The *Tint* well: *None* removes the tint.
    func setTint(_ ref: Wiretuner_Doc_V1_ColorRef) -> any WTModel.Command {
        if case .none? = ref.ref { return SetImageSetting(nodes, .tint(nil)) }
        return SetImageSetting(nodes, .tint(ref))
    }

    /// A crop edge typed in pixels (the one image): `field` 0 left, 1 top, 2 width, 3 height.
    func setCrop(_ value: Double, field: Int) -> (any WTModel.Command)? {
        guard let image = one else { return nil }
        var px = image.cropPixels
        switch field {
        case 0: px = Rect(x: value, y: px.minY, width: px.width, height: px.height)
        case 1: px = Rect(x: px.minX, y: value, width: px.width, height: px.height)
        case 2: px = Rect(x: px.minX, y: px.minY, width: value, height: px.height)
        default: px = Rect(x: px.minX, y: px.minY, width: px.width, height: value)
        }
        guard let crop = ImageCropping.unit(fromPixels: px, width: image.pixelWidth, height: image.pixelHeight) else { return nil }
        return CropImage([image.node], crop: crop, name: panel.document.state.displayName(of: image.node))
    }

    /// btn:[Reset] beside *Crop*: "Remove Crop".
    func resetCrop() -> (any WTModel.Command)? {
        let cropped = images.filter(\.isCropped).map(\.node)
        return cropped.isEmpty ? nil : CropImage(cropped, crop: nil)
    }

    /// The *Image Info…* lines of the one image.
    func infoLines() -> [(String, String)] {
        guard let image = one else { return [] }
        let state = panel.document.state
        let props = state.props(image.node).image
        let profile = ImageColorInfo(image.node, in: state)?.embedded?.name
        return ImageInfoLines.lines(image, format: props.pixels.format, profile: profile, fileSize: nil,
                                    placedBy: ImageSection.author(image.node, panel.document))
    }
}

/// The gray ramp sheet (bitmaps.adoc, "Gray ramp"): presets, *Lightness* and *Contrast*, btn:[Reset]
/// back to Normal, btn:[Apply] writing the ramp without closing, btn:[OK] writing and closing,
/// btn:[Cancel] putting back the ramp the images had when it opened.  Each write is one change.
@MainActor
@Observable
final class RampSheetModel {
    @ObservationIgnored let document: DocumentHandle
    let nodes: [OpID]
    let original: GrayRamp
    var ramp: GrayRamp
    /// The ramp last written.
    private(set) var applied: GrayRamp

    init(document: DocumentHandle, nodes: [OpID], ramp: GrayRamp) {
        self.document = document
        self.nodes = nodes
        original = ramp
        self.ramp = ramp
        applied = ramp
    }

    static let presets: [(GrayRamp.Preset, String)] = [(.normal, "Normal"), (.inverted, "Inverted"), (.lighten, "Lighten"), (.darken, "Darken"),
                                                         (.custom, "Custom")]

    func choose(_ preset: GrayRamp.Preset) {
        ramp = GrayRamp(preset: preset, lightness: preset == .custom ? ramp.lightness : 0, contrast: preset == .custom ? ramp.contrast : 0)
    }

    /// A slider moved: the ramp becomes Custom.
    func adjust(lightness: Int? = nil, contrast: Int? = nil) {
        ramp = GrayRamp(preset: .custom, lightness: lightness ?? ramp.lightness, contrast: contrast ?? ramp.contrast)
    }

    func reset() { ramp = .normal }

    /// Writes the ramp when it differs from the one last written.
    @discardableResult
    func apply() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard ramp != applied else { return nil }
        applied = ramp
        return document.perform(SetImageSetting(nodes, .ramp(ramp.effectivePreset == .normal ? nil : ramp)))
    }

    /// btn:[Cancel]: the images' ramp as it was, when Apply changed it.
    @discardableResult
    func cancel() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        ramp = original
        return apply()
    }

    /// The ramp's curve as 256 gray levels (the sheet's preview strip).
    var levels: [UInt8] { ramp.lut() }
}

struct RampSheetView: View {
    @Bindable var model: RampSheetModel
    let close: () -> Void

    static func lightness(_ model: RampSheetModel) -> Binding<Double> {
        Binding(get: { Double(model.ramp.lightness) }, set: { model.adjust(lightness: Int($0.rounded())) })
    }

    static func contrast(_ model: RampSheetModel) -> Binding<Double> {
        Binding(get: { Double(model.ramp.contrast) }, set: { model.adjust(contrast: Int($0.rounded())) })
    }

    static func cancelling(_ model: RampSheetModel, _ close: @escaping () -> Void) -> () -> Void {
        {
            model.cancel()
            close()
        }
    }

    static func keeping(_ model: RampSheetModel, _ close: @escaping () -> Void) -> () -> Void {
        {
            model.apply()
            close()
        }
    }

    static func preset(_ model: RampSheetModel) -> Binding<GrayRamp.Preset> {
        Binding(get: { model.ramp.effectivePreset }, set: { model.choose($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gray Ramp").font(.headline)
            Canvas { context, size in
                let levels = model.levels
                let step = size.width / CGFloat(levels.count)
                for (index, level) in levels.enumerated() {
                    let gray = Double(level) / 255
                    context.fill(Path(CGRect(x: CGFloat(index) * step, y: 0, width: step + 0.5, height: size.height)),
                                 with: .color(SwiftUI.Color(white: gray)))
                }
            }
            .frame(height: 24)
            .accessibilityIdentifier("imageRamp.preview")
            Picker("Preset", selection: Self.preset(model)) {
                ForEach(RampSheetModel.presets, id: \.0) { Text($0.1).tag($0.0) }
            }
            .accessibilityIdentifier("imageRamp.preset")
            Slider(value: Self.lightness(model), in: -100...100) { Text("Lightness") }.accessibilityIdentifier("imageRamp.lightness")
            Slider(value: Self.contrast(model), in: -100...100) { Text("Contrast") }.accessibilityIdentifier("imageRamp.contrast")
            HStack {
                Button("Reset") { model.reset() }.accessibilityIdentifier("imageRamp.reset")
                Spacer()
                Button("Cancel", action: Self.cancelling(model, close))
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("imageRamp.cancel")
                Button("Apply") { model.apply() }.accessibilityIdentifier("imageRamp.apply")
                Button("OK", action: Self.keeping(model, close))
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("imageRamp.ok")
            }
        }
        .padding()
        .frame(width: 340)
    }
}

/// The *Image Info…* lines.
struct ImageInfoView: View {
    let lines: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                GridRow {
                    Text(line.0).foregroundStyle(.secondary)
                    Text(line.1).textSelection(.enabled)
                }
            }
        }
        .padding()
        .accessibilityIdentifier("imageInfo")
    }
}

/// The section's registration, its hooks into the app and menu:Object[Image Info…].
@MainActor
enum ImageSection {
    static let infoID: CommandID = "object.imageInfo"
    /// *Warn when image resolution is below*, ppi.
    static var threshold: @MainActor () -> Double = { 150 }
    /// Runs a command by id (btn:[Links…] runs menu:Edit[Links…]).
    static var perform: @MainActor (CommandID) -> Void = { _ in }
    /// Who placed `node` (the replica that created it), nil for this Mac.
    static var author: @MainActor (OpID, DocumentHandle) -> String? = { _, _ in nil }
    /// Shows the popover (replaceable in tests).
    static var showPopover: @MainActor (NSPopover, NSRect, NSView) -> Void = { popover, rect, view in
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "image", order: 72, kinds: [.image]) { panel in
            ImageSectionModel(panel).map { AnyView(ImageSectionView(model: $0)) }
        })
    }

    /// The selected images of `window`.
    static func selectedImages(_ window: DocumentWindowController?) -> [OpID] {
        guard let window else { return [] }
        let state = window.documentHandle.state
        return window.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .image }
    }

    /// The popover of `window`'s one selected image, shown beside it on the canvas.
    @discardableResult
    static func showInfo(in window: DocumentWindowController) -> NSPopover? {
        let images = selectedImages(window)
        guard images.count == 1 else { return nil }
        let panel = ObjectPanelModel(document: window.documentHandle, selection: window.selection.selection)
        guard let model = ImageSectionModel(panel) else { return nil }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ImageInfoView(lines: model.infoLines()))
        let canvas = window.canvas
        let bounds = Objects.bounds(of: images[0], in: window.documentHandle.state) ?? Rect(x: 0, y: 0, width: 1, height: 1)
        let topLeft = canvas.viewport.toView(Point(x: bounds.maxX, y: bounds.minY))
        showPopover(popover, NSRect(x: topLeft.x, y: canvas.bounds.height - topLeft.y - 1, width: 1, height: 1), canvas)
        return popover
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        [Command(id: infoID, title: "Image Info…", menu: MenuPath(ContextMenuCatalog.Menu.object, "Image", section: 0), contexts: [.bitmap],
                 keywords: ["image", "resolution", "pixels", "profile", "information"],
                 validation: { selectedImages(window()).count == 1 ? .enabled : .disabled("Select one image") },
                 action: .perform { if let window = window() { showInfo(in: window) } })]
    }
}

/// Local view state: the locks and the sheet and popover.
@MainActor
@Observable
final class ImageSectionState {
    var resolutionLocked = true
    var scaleLocked = true
    var ramp: RampSheetModel?
    var showsInfo = false
}

struct ImageSectionView: View {
    let model: ImageSectionModel
    @State private var state = ImageSectionState()

    static func toggle(_ value: MixedState, _ perform: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value.isOn }, set: { perform($0) })
    }

    static func perform(_ model: ImageSectionModel, _ command: (any WTModel.Command)?) {
        model.panel.perform(command)
    }

    static func tintActions(_ model: ImageSectionModel) -> ColorWellActions {
        ColorWellActions(document: model.panel.document) { ref in perform(model, model.setTint(ref)) }
    }

    /// A typed field of the section.
    enum Field: CaseIterable {
        case stored, storedVertical, scale, width, height, cropLeft, cropTop, cropWidth, cropHeight
    }

    /// What committing `field` writes, with the locks of `state`.
    static func commit(_ model: ImageSectionModel, _ state: ImageSectionState, _ field: Field) -> (Double) -> Void {
        { value in
            let command: (any WTModel.Command)? = switch field {
            case .stored: model.setStored(value, horizontal: true, locked: state.resolutionLocked)
            case .storedVertical: model.setStored(value, horizontal: false, locked: false)
            case .scale: model.setScale(value, locked: state.scaleLocked)
            case .width: model.setSize(value, width: true, locked: state.scaleLocked)
            case .height: model.setSize(value, width: false, locked: state.scaleLocked)
            case .cropLeft: model.setCrop(value, field: 0)
            case .cropTop: model.setCrop(value, field: 1)
            case .cropWidth: model.setCrop(value, field: 2)
            case .cropHeight: model.setCrop(value, field: 3)
            }
            perform(model, command)
        }
    }

    static func resettingCrop(_ model: ImageSectionModel) -> () -> Void { { perform(model, model.resetCrop()) } }
    static func showingLinks() { ImageSection.perform("edit.links") }
    static func showingInfo(_ state: ImageSectionState) -> () -> Void { { state.showsInfo = true } }

    static func openRamp(_ model: ImageSectionModel, _ state: ImageSectionState) -> () -> Void {
        { state.ramp = RampSheetModel(document: model.panel.document, nodes: model.nodes, ramp: model.shared(\.ramp) ?? .normal) }
    }

    var body: some View {
        let unit = model.panel.unit
        Form {
            Text(model.kindLabel).font(.headline).accessibilityIdentifier("object.image.kind")
            if let one = model.one {
                LabeledContent("File") {
                    HStack {
                        Text(one.file).lineLimit(1)
                        Button("Links…", action: Self.showingLinks).accessibilityIdentifier("object.image.links")
                    }
                }
                LabeledContent("Pixels", value: one.pixelsText).accessibilityIdentifier("object.image.pixels")
                LabeledContent("Color mode", value: one.modeText).accessibilityIdentifier("object.image.mode")
            }
            HStack {
                CommitField(title: "Stored", value: model.shared(\.dpiX), identifier: "object.image.stored", commit: Self.commit(model, state, .stored))
                if !state.resolutionLocked {
                    CommitField(title: "Stored V", value: model.shared(\.dpiY), identifier: "object.image.storedV", commit: Self.commit(model, state, .storedVertical))
                }
                Toggle(isOn: $state.resolutionLocked) { Image(systemName: state.resolutionLocked ? "lock" : "lock.open") }
                    .toggleStyle(.button).accessibilityIdentifier("object.image.storedLock")
            }
            let warns = model.warns(below: ImageSection.threshold())
            LabeledContent("Effective") {
                HStack(spacing: 4) {
                    if warns { Image(systemName: "exclamationmark.triangle.fill") }
                    Text(model.effectivePPI.map { "\($0.formatted()) ppi" } ?? "Mixed")
                }
                .foregroundStyle(warns ? SwiftUI.Color.orange : SwiftUI.Color.primary)
            }
            .accessibilityIdentifier("object.image.effective")
            HStack {
                CommitField(title: "Scale %", value: model.shared { ($0.scaleX * 1000).rounded() / 10 }, identifier: "object.image.scale", commit: Self.commit(model, state, .scale))
                Toggle(isOn: $state.scaleLocked) { Image(systemName: state.scaleLocked ? "lock" : "lock.open") }
                    .toggleStyle(.button).accessibilityIdentifier("object.image.scaleLock")
            }
            MeasureField(title: "Width", value: model.shared(\.placedSize.width), unit: unit, identifier: "object.image.width", commit: Self.commit(model, state, .width))
            MeasureField(title: "Height", value: model.shared(\.placedSize.height), unit: unit, identifier: "object.image.height", commit: Self.commit(model, state, .height))
            if model.showsAlpha {
                Toggle("Display alpha channel", isOn: Self.toggle(model.displayAlpha) { Self.perform(model, model.setDisplayAlpha($0)) })
                    .accessibilityIdentifier("object.image.displayAlpha")
            }
            if model.showsGray {
                Toggle("Transparent", isOn: Self.toggle(model.transparent) { Self.perform(model, model.setTransparent($0)) })
                    .accessibilityIdentifier("object.image.transparent")
                Button("Edit ramp…", action: Self.openRamp(model, state)).accessibilityIdentifier("object.image.editRamp")
                ColorWellView(title: "Tint", model: ColorWellModel(ref: model.shared(\.tint) ?? nil, state: model.panel.document.state),
                              actions: Self.tintActions(model), identifier: "object.image.tint")
            }
            if let one = model.one {
                let px = one.cropPixels
                LabeledContent("Crop") {
                    Button("Reset", action: Self.resettingCrop(model)).disabled(!one.isCropped).accessibilityIdentifier("object.image.cropReset")
                }
                HStack {
                    CommitField(title: "Left", value: px.minX, identifier: "object.image.cropLeft", commit: Self.commit(model, state, .cropLeft))
                    CommitField(title: "Top", value: px.minY, identifier: "object.image.cropTop", commit: Self.commit(model, state, .cropTop))
                }
                HStack {
                    CommitField(title: "Width", value: px.width, identifier: "object.image.cropWidth", commit: Self.commit(model, state, .cropWidth))
                    CommitField(title: "Height", value: px.height, identifier: "object.image.cropHeight", commit: Self.commit(model, state, .cropHeight))
                }
                Button("Info…", action: Self.showingInfo(state))
                    .accessibilityIdentifier("object.image.info")
                    .popover(isPresented: $state.showsInfo) { ImageInfoView(lines: model.infoLines()) }
            }
        }
        .padding(.horizontal)
        .sheet(item: $state.ramp) { ramp in
            RampSheetView(model: ramp) { state.ramp = nil }
        }
    }
}

extension RampSheetModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
