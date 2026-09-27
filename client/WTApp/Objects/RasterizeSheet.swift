import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// menu:Modify[Rasterize…] (IMG-024; rasterizing.adoc): resolution, anti-aliasing, background,
/// colour mode and *Keep originals*, with the result's pixel count as the options change, the
/// warning over the *Downsample images larger than* preference and the refusal over 200 MiB.
/// btn:[Rasterize] draws the selection off the main actor -- with a progress bar and btn:[Cancel]
/// above 16 MP -- stores the image as a blob (queued for upload) and writes one change.
@MainActor
@Observable
final class RasterizeModel {
    enum ResolutionChoice: String, CaseIterable, Identifiable {
        case screen, proof, print, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .screen: "72 ppi (screen)"
            case .proof: "144 ppi (proof)"
            case .print: "300 ppi (print)"
            case .custom: "Custom"
            }
        }
    }

    enum Phase: Equatable {
        case ready
        case rendering(Double)
        case failed(String)
        case done
    }

    /// The selected top-level objects, bottom first.
    let nodes: [OpID]
    /// Their display items as placed, bottom first.
    let selection: DisplayList
    var resolutionChoice = ResolutionChoice.print
    var customResolution = 300.0
    var antiAliasing = RasterizeOptions.AntiAliasing.medium
    var transparent = true
    var colorMode = RasterizeOptions.ColorMode.rgb
    var keepOriginals = false
    private(set) var phase = Phase.ready
    /// The *Downsample images larger than* preference, in pixels (nil: off).
    let downsampleLimit: Int?
    @ObservationIgnored let output: WTColor.OutputContext
    @ObservationIgnored let base: CoreGraphicsRenderer?
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
    @ObservationIgnored let storeBlob: @MainActor (ImportedBlob) async throws -> Void
    @ObservationIgnored var onClose: @MainActor () -> Void = {}
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set by btn:[Cancel] while rendering; read by the renderer between bands.
    @ObservationIgnored private let cancelFlag = RasterizeCancel()

    init(nodes: [OpID], selection: DisplayList, downsampleLimit: Int?, output: WTColor.OutputContext = .standard, base: CoreGraphicsRenderer? = nil,
         perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>,
         storeBlob: @escaping @MainActor (ImportedBlob) async throws -> Void) {
        self.nodes = nodes
        self.selection = selection
        self.downsampleLimit = downsampleLimit
        self.output = output
        self.base = base
        self.perform = perform
        self.storeBlob = storeBlob
    }

    /// The selected objects of `window` (a nested selection as its top-level object), bottom
    /// first, and their display items as placed.
    static func selection(in window: DocumentWindowController) -> (nodes: [OpID], list: DisplayList) {
        let document = window.documentHandle
        let state = document.state
        let selected = Set(window.selection.model.ids.map(\.opID))
        let objects = selected.filter { node in
            guard state.isLive(node), Objects.isObject(node, in: state) else { return false }
            var parent = state.store.placement(node)?.parent
            while let id = parent {
                if selected.contains(id) { return false }
                parent = state.store.placement(id)?.parent
            }
            return true
        }
        let ordered = Objects.stackingOrder(Array(objects), in: state)
        let scene = document.scene
        let placed = ordered.compactMap { node in scene.object(node).map { (node, $0.item) } }
        let list = DisplayList(canvas: CanvasID("rasterize-\(document.id)"), items: placed.map(\.1), nodeIDs: placed.map { NodeID($0.0) })
        return (placed.map(\.0), list)
    }

    var options: RasterizeOptions {
        let resolution: RasterizeOptions.Resolution = switch resolutionChoice {
        case .screen: .screen
        case .proof: .proof
        case .print: .print
        case .custom: .custom(customResolution)
        }
        return RasterizeOptions(resolution: resolution, antiAliasing: antiAliasing, background: transparent ? .transparent : .white,
                                colorMode: colorMode, keepOriginals: keepOriginals)
    }

    var plan: RasterizePlan? { SelectionRasterizer.plan(selection, options: options) }

    /// "1,200 × 800 pixels (0.96 MP)".
    var readout: String { plan?.readout ?? "Nothing to rasterize" }

    /// The warning or refusal under the readout.
    var warning: String? {
        guard let plan else { return nil }
        if plan.isRefused { return "The result would be over 200 MB. Lower the resolution or rasterize in pieces." }
        if plan.exceeds(downsampleLimit: downsampleLimit) { return "The result is larger than the Downsample images larger than preference; it is not downsampled." }
        return nil
    }

    /// Why btn:[Rasterize] is off, if it is.
    var unavailableReason: String? {
        do { try options.validate() } catch { return "Choose a resolution from 36 to 2,400 ppi" }
        guard let plan else { return "The selection draws nothing" }
        return plan.isRefused ? "The result is too large" : nil
    }

    /// Whether rendering shows the progress bar (over 16 MP).
    var showsProgress: Bool { (plan?.pixelCount ?? 0) > SelectionRasterizer.progressThreshold }

    /// btn:[Rasterize].
    @discardableResult
    func rasterize() -> Task<Void, Never>? {
        guard unavailableReason == nil, task == nil else { return nil }
        phase = .rendering(0)
        cancelFlag.reset()
        let (selection, options, output, base, flag) = (selection, options, output, base, cancelFlag)
        let nodes = nodes
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [self] in self?.progressed(fraction) }
        }
        let task = Task { [weak self] in
            do {
                let image = try await SelectionRasterizer.rasterizeInBackground(selection, options: options, output: output, base: base) { fraction in
                    report(fraction)
                    return !flag.isSet
                }
                guard let self else { return }
                try await self.storeBlob(image.pixels.blob)
                _ = await self.perform(RasterizeObjects(nodes, image: image, keepOriginals: options.keepOriginals)).value
                self.phase = .done
                self.task = nil
                self.onClose()
            } catch {
                guard let self else { return }
                self.task = nil
                self.phase = error is CancellationError ? .ready : .failed(Self.message(error))
            }
        }
        self.task = task
        return task
    }

    private func progressed(_ fraction: Double) {
        if case .rendering = phase { phase = .rendering(fraction) }
    }

    static func message(_ error: any Error) -> String {
        switch error as? RasterizeError {
        case .invalidResolution?: "Choose a resolution from 36 to 2,400 ppi."
        case .nothingToRasterize?: "The selection draws nothing."
        case .tooLarge?: "The result would be over 200 MB."
        case nil: "The selection could not be rasterized: \(error.localizedDescription)"
        }
    }

    /// btn:[Cancel]: stops a render at its next band, else closes the sheet.
    func cancel() {
        if task != nil {
            cancelFlag.set()
        } else {
            onClose()
        }
    }
}

/// The cancel flag the render polls from its thread.
final class RasterizeCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
    func reset() { lock.withLock { value = false } }
}

struct RasterizeSheet: View {
    @Bindable var model: RasterizeModel

    static func rasterize(_ model: RasterizeModel) -> () -> Void { { model.rasterize() } }
    static func cancel(_ model: RasterizeModel) -> () -> Void { { model.cancel() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Resolution", selection: $model.resolutionChoice) {
                    ForEach(RasterizeModel.ResolutionChoice.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("rasterize.resolution")
                if model.resolutionChoice == .custom {
                    TextField("Custom (ppi)", value: $model.customResolution, format: .number).accessibilityIdentifier("rasterize.custom")
                }
                Picker("Anti-aliasing", selection: $model.antiAliasing) {
                    Text("None").tag(RasterizeOptions.AntiAliasing.none)
                    Text("Low").tag(RasterizeOptions.AntiAliasing.low)
                    Text("Medium").tag(RasterizeOptions.AntiAliasing.medium)
                    Text("High").tag(RasterizeOptions.AntiAliasing.high)
                }
                Picker("Background", selection: $model.transparent) {
                    Text("Transparent").tag(true)
                    Text("White").tag(false)
                }
                Picker("Color mode", selection: $model.colorMode) {
                    Text("RGB").tag(RasterizeOptions.ColorMode.rgb)
                    Text("CMYK").tag(RasterizeOptions.ColorMode.cmyk)
                    Text("Grayscale").tag(RasterizeOptions.ColorMode.grayscale)
                }
                Toggle("Keep originals", isOn: $model.keepOriginals)
            }
            Text(model.readout).font(.callout).accessibilityIdentifier("rasterize.readout")
            if let warning = model.warning { Text(warning).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("rasterize.warning") }
            switch model.phase {
            case .rendering(let fraction) where model.showsProgress:
                ProgressView(value: fraction) { Text("Rasterizing…") }.accessibilityIdentifier("rasterize.progress")
            case .failed(let message): Text(message).foregroundStyle(.red).font(.callout)
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("Rasterize", action: Self.rasterize(model)).keyboardShortcut(.defaultAction)
                    .disabled(model.unavailableReason != nil || model.phase != .ready && model.phase != .done && !Self.failed(model.phase))
                    .accessibilityIdentifier("rasterize.rasterize")
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    static func failed(_ phase: RasterizeModel.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}
