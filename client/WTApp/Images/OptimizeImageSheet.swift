import AppKit
import ImageIO
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto

/// menu:Modify[Optimize Image…] (IMG-020; external-editors.adoc, "Optimizing an image"): the
/// selected images re-encoded with the sheet's format, quality, resampling (downsampling only),
/// colour mode and *Strip metadata*.  The sheet shows each image's current and resulting pixel
/// size and effective resolution, the stored size now and the estimate (encoded off the main
/// actor, cancelled when an option changes), and a before/after preview at 100% of the first
/// image.  btn:[Optimize] encodes every image off the main actor, stores the results as blobs
/// (queued for upload) and writes them in one change ("Optimize _name_" / "Optimize (N images)").
/// *Trim to crop* (IMG-025's rest; cropping-bitmaps.adoc) first cuts each cropped image to its crop
/// (`ImageCropping.trimRect`), so only the visible pixels are encoded, and writes those images with
/// `TrimImageToCrop` -- the crop reset, the visible part left where it is -- in the same change.
@MainActor
@Observable
final class OptimizeImageModel {
    /// One selected image.
    struct Item: Identifiable, Equatable {
        let node: OpID
        let name: String
        /// The stored bytes, nil when the blob is not on this Mac yet.
        let data: Data?
        let pixelWidth: Int
        let pixelHeight: Int
        /// The width on the page, in points.
        let placedWidth: Double
        /// The crop (unit square) when the image is cropped.
        var crop: Rect? = nil
        var id: OpID { node }
    }

    enum Phase: Equatable {
        case ready
        case working
        case failed(String)
        case done
    }

    /// The resample choice as the sheet's pop-up has it.
    enum ResampleChoice: String, CaseIterable, Identifiable {
        case none, effectiveResolution, pixelSize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .effectiveResolution: "To effective resolution"
            case .pixelSize: "To pixel size"
            }
        }
    }

    let items: [Item]
    var format: ImageOptimizeOptions.Format = .keep { didSet { optionsChanged() } }
    var quality = 85 { didSet { optionsChanged() } }
    var resampleChoice = ResampleChoice.none { didSet { optionsChanged() } }
    var resolution = 300.0 { didSet { optionsChanged() } }
    var pixelSize = 2048 { didSet { optionsChanged() } }
    var colorMode: ImageOptimizeOptions.ColorMode = .keep { didSet { optionsChanged() } }
    var stripMetadata = false { didSet { optionsChanged() } }
    /// *Trim to crop*: cropped images keep only their visible pixels.
    var trimToCrop = false { didSet { optionsChanged() } }
    /// Whether any selected image is cropped (the checkbox is enabled).
    var canTrim: Bool { items.contains { $0.crop != nil } }
    /// The estimated stored size of every image together, nil while it is being computed.
    private(set) var estimate: Int?
    private(set) var phase = Phase.ready
    /// The first image before and after, at 100%, cropped to the preview's size.
    private(set) var preview: (before: CGImage?, after: CGImage?) = (nil, nil)
    @ObservationIgnored private var estimating: Task<Void, Never>?
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>
    @ObservationIgnored let storeBlobs: @MainActor ([ImportedBlob]) async throws -> Void
    @ObservationIgnored var onClose: @MainActor () -> Void = {}
    /// How long option changes settle before the estimate runs.
    @ObservationIgnored var settle: Duration = .milliseconds(150)

    init(items: [Item], perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>,
         storeBlobs: @escaping @MainActor ([ImportedBlob]) async throws -> Void) {
        self.items = items
        self.perform = perform
        self.storeBlobs = storeBlobs
    }

    /// The selected live images of `window` with their bytes from `blobs`.
    static func items(in window: DocumentWindowController, blobs: BlobPlacement) -> [Item] {
        let state = window.documentHandle.state
        return window.selection.model.ids.map(\.opID).compactMap { node in
            guard state.isLive(node), state.nodeKind(node) == .image, case .image(let image)? = state.props(node).kind else { return nil }
            let transform = Objects.transform(of: node, in: state)
            let scale = (transform.a * transform.a + transform.b * transform.b).squareRoot()
            return Item(node: node, name: ObjectNaming.name(of: node, in: state), data: blobs.cached(image.pixels.blobSha256),
                        pixelWidth: Int(image.pixels.pixelWidth), pixelHeight: Int(image.pixels.pixelHeight),
                        placedWidth: ImageNodes.naturalRect(image).width * scale,
                        crop: ImageCropping.isCropped(node, in: state) ? ImageCropping.crop(of: image) : nil)
        }
    }

    var options: ImageOptimizeOptions {
        let resample: ImageOptimizeOptions.Resample = switch resampleChoice {
        case .none: .none
        case .effectiveResolution: .effectiveResolution(resolution)
        case .pixelSize: .pixelSize(pixelSize)
        }
        return ImageOptimizeOptions(format: format, quality: quality, resample: resample, colorMode: colorMode, stripMetadata: stripMetadata)
    }

    /// The formats this Mac writes, in the pop-up's order.
    var formats: [ImageOptimizeOptions.Format] { ImageOptimizeOptions.Format.allCases.filter(\.isAvailable) }

    /// Whether `format` would lose an image's displayed alpha (JPEG): dimmed in the pop-up.
    func dims(_ format: ImageOptimizeOptions.Format) -> Bool {
        !format.holdsAlpha && items.contains { $0.data.map(Self.hasAlpha) ?? false }
    }

    static func hasAlpha(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// "4,000 × 3,000 px, 600 ppi → 2,000 × 1,500 px, 300 ppi" for each image.
    func planLine(_ item: Item) -> String {
        let plan = ImageOptimizer.plan(width: item.pixelWidth, height: item.pixelHeight, placedWidth: item.placedWidth, resample: options.resample)
        let now = "\(plan.pixelWidth.formatted()) × \(plan.pixelHeight.formatted()) px, \(Int(plan.effectiveResolution.rounded())) ppi"
        guard plan.resamples else { return now }
        return now + " → \(plan.targetWidth.formatted()) × \(plan.targetHeight.formatted()) px, \(Int(plan.targetResolution.rounded())) ppi"
    }

    /// The stored size of every image now.
    var storedSize: Int { items.reduce(0) { $0 + ($1.data?.count ?? 0) } }

    /// "12.4 MB → about 2.1 MB".
    var sizeLine: String {
        let now = ByteCountFormatter.string(fromByteCount: Int64(storedSize), countStyle: .file)
        guard let estimate else { return "\(now) → estimating…" }
        return "\(now) → about \(ByteCountFormatter.string(fromByteCount: Int64(estimate), countStyle: .file))"
    }

    /// Why btn:[Optimize] is off, if it is.
    var unavailableReason: String? {
        if items.isEmpty { return "Select an image" }
        if items.contains(where: { $0.data == nil }) { return "An image’s pixels have not downloaded yet" }
        do { try options.validate() } catch { return (error as? ImageOptimizeError).map(Self.message) ?? error.localizedDescription }
        return nil
    }

    static func message(_ error: ImageOptimizeError) -> String {
        switch error {
        case .invalidOption(let text): text
        case .unreadable: "The image could not be read."
        default: "The image could not be written."
        }
    }

    // MARK: Estimate and preview

    /// What is encoded for `item`: its bytes and width on the page, cut to its crop when trimming.
    func input(_ item: Item) -> (data: Data, placedWidth: Double, trimmed: Bool)? {
        guard let data = item.data else { return nil }
        guard trimToCrop, let crop = item.crop else { return (data, item.placedWidth, false) }
        let kept = ImageCropping.trimRect(crop, width: item.pixelWidth, height: item.pixelHeight)
        guard let cut = Self.trimmed(data, to: kept) else { return (data, item.placedWidth, false) }
        return (cut, item.placedWidth * Double(kept.width) / Double(max(item.pixelWidth, 1)), true)
    }

    /// `data`'s pixels in `rect` (top-left origin), re-encoded in the image's own format (at full
    /// quality when it is lossy); nil when it cannot be read.
    nonisolated static func trimmed(_ data: Data, to rect: (x: Int, y: Int, width: Int, height: Int)) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cut = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        CGImageDestinationAddImage(destination, cut, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Cancels the running estimate and starts one for the current options.
    func optionsChanged() {
        estimating?.cancel()
        estimate = nil
        let options = options
        let inputs = items.compactMap { item in input(item).map { ($0.data, $0.placedWidth) } }
        let settle = settle
        estimating = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { () -> (Int, CGImage?, CGImage?)? in
                var total = 0
                var after: CGImage?
                for (index, (data, width)) in inputs.enumerated() {
                    if Task.isCancelled { return nil }
                    guard let pixels = try? ImageOptimizer.optimize(data, placedWidth: width, options: options) else { return nil }
                    total += pixels.blob.data.count
                    if index == 0 { after = Self.image(pixels.blob.data) }
                }
                return (total, inputs.first.flatMap { Self.image($0.0) }, after)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.estimate = result.0
            self.preview = (result.1.map { Self.crop($0) }, result.2.map { Self.crop($0) })
        }
    }

    /// Waits for the running estimate (tests).
    func settled() async { await estimating?.value }

    nonisolated static func image(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// The centre `side` × `side` pixels: the preview at 100%.
    nonisolated static func crop(_ image: CGImage, side: Int = 160) -> CGImage {
        let width = min(side, image.width), height = min(side, image.height)
        let rect = CGRect(x: (image.width - width) / 2, y: (image.height - height) / 2, width: width, height: height)
        return image.cropping(to: rect) ?? image
    }

    // MARK: Optimize

    /// btn:[Optimize]: every image encoded off the main actor, stored, then one change.
    @discardableResult
    func optimize() -> Task<Void, Never>? {
        guard unavailableReason == nil, phase != .working else { return nil }
        phase = .working
        estimating?.cancel()
        let options = options
        let inputs = items.map { item in
            let input = input(item)
            return (item.node, input?.data ?? Data(), input?.placedWidth ?? item.placedWidth, input?.trimmed ?? false)
        }
        let names = items.map(\.name)
        return Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) { () -> Result<[(OpID, ImportedPixels, Bool)], any Error> in
                Result { try inputs.map { ($0.0, try ImageOptimizer.optimize($0.1, placedWidth: $0.2, options: options), $0.3) } }
            }.value
            guard let self else { return }
            do {
                let optimized = try results.get()
                try await self.storeBlobs(optimized.map(\.1.blob))
                _ = await self.perform(Self.command(optimized, names: names)).value
                self.phase = .done
                self.onClose()
            } catch {
                self.phase = .failed((error as? ImageOptimizeError).map(Self.message) ?? "The images could not be optimized: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        estimating?.cancel()
        onClose()
    }

    /// The one change: the trimmed images through `TrimImageToCrop`, the others through
    /// `OptimizeImages`, under the optimize label.
    static func command(_ results: [(OpID, ImportedPixels, Bool)], names: [String]) -> any WTModel.Command {
        let optimize = OptimizeImages(results.filter { !$0.2 }.map { (node: $0.0, pixels: $0.1) }, names: names)
        let trims = results.filter(\.2).map { TrimImageToCrop($0.0, pixels: $0.1.pixelSource) }
        guard !trims.isEmpty else { return optimize }
        let label = OptimizeImages(results.map { (node: $0.0, pixels: $0.1) }, names: names).label
        return CommandBatch(label, trims + (optimize.results.isEmpty ? [] : [optimize]))
    }
}

struct OptimizeImageSheet: View {
    @Bindable var model: OptimizeImageModel

    static func optimize(_ model: OptimizeImageModel) -> () -> Void { { model.optimize() } }
    static func cancel(_ model: OptimizeImageModel) -> () -> Void { { model.cancel() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Format", selection: $model.format) {
                    ForEach(model.formats, id: \.self) { format in
                        Text(format == .keep ? "Keep" : format.rawValue.uppercased())
                            .foregroundStyle(model.dims(format) ? .secondary : .primary)
                            .tag(format)
                    }
                }
                .accessibilityIdentifier("optimize.format")
                if model.format.isLossy {
                    Stepper("Quality: \(model.quality)", value: $model.quality, in: 1...100).accessibilityIdentifier("optimize.quality")
                }
                Picker("Resample", selection: $model.resampleChoice) {
                    ForEach(OptimizeImageModel.ResampleChoice.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("optimize.resample")
                switch model.resampleChoice {
                case .none: EmptyView()
                case .effectiveResolution: TextField("Resolution (ppi)", value: $model.resolution, format: .number)
                case .pixelSize: TextField("Longer edge (px)", value: $model.pixelSize, format: .number)
                }
                Picker("Color mode", selection: $model.colorMode) {
                    Text("Keep").tag(ImageOptimizeOptions.ColorMode.keep)
                    Text("Grayscale").tag(ImageOptimizeOptions.ColorMode.grayscale)
                    Text("RGB").tag(ImageOptimizeOptions.ColorMode.rgb)
                }
                Toggle("Strip metadata", isOn: $model.stripMetadata)
                Toggle("Trim to crop", isOn: $model.trimToCrop).disabled(!model.canTrim)
                    .help(model.canTrim ? "Keep only the pixels inside the crop" : "No selected image is cropped")
                    .accessibilityIdentifier("optimize.trim")
            }
            ForEach(model.items) { item in
                Text("\(item.name): \(model.planLine(item))").font(.caption).lineLimit(1).accessibilityIdentifier("optimize.plan")
            }
            Text(model.sizeLine).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("optimize.size")
            HStack(spacing: 12) {
                ForEach(Array([("Before", model.preview.before), ("After", model.preview.after)].enumerated()), id: \.offset) { _, entry in
                    VStack {
                        if let image = entry.1 {
                            Image(decorative: image, scale: 1).frame(width: 160, height: 160)
                        } else {
                            Rectangle().fill(.quaternary).frame(width: 160, height: 160)
                        }
                        Text(entry.0).font(.caption)
                    }
                }
            }
            if case .failed(let message) = model.phase { Text(message).foregroundStyle(.red).font(.callout) }
            HStack {
                if let reason = model.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("Optimize", action: Self.optimize(model)).keyboardShortcut(.defaultAction)
                    .disabled(model.unavailableReason != nil || model.phase == .working)
                    .accessibilityIdentifier("optimize.optimize")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
