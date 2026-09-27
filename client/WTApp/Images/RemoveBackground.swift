import AppKit
import CryptoKit
import ImageIO
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// menu:Object[Image > Remove Background…] and menu:Object[Image > Select Subject] (bitmaps.adoc,
/// "Removing a background"; IMG-028's app half over WTRender's `SubjectMask` and WTModel's
/// `RemoveImageBackground` / `ClipImageToSubject`).  The sheet segments the one selected image on
/// this Mac (off the main actor), shows it with the background faded and the chosen subjects
/// outlined; a click in the preview picks another subject, kbd:[Shift]-click adds one; *Soften
/// edge* (0 to 10 px, default 1) feathers a transparent image's cut.  btn:[Remove Background]
/// makes the chosen result, one change.  *Select Subject* segments the image and hands every
/// subject to the Trace tool as its wand selection.  Placeholders, bilevel and indexed images and
/// selections of more than one object are refused (`SubjectImages.refusal`).
@MainActor
@Observable
final class RemoveBackgroundModel {
    static let sheet = "image.remove-background"
    static let removeID = CommandID("image.removeBackground")
    static let selectID = CommandID("image.selectSubject")

    /// What btn:[Remove Background] makes.
    enum Result: String, CaseIterable, Identifiable {
        case transparentImage, clippingPath
        var id: String { rawValue }
        var title: String { self == .transparentImage ? "Transparent image" : "Clipping path" }
    }

    @ObservationIgnored let window: DocumentWindowController
    @ObservationIgnored let node: OpID
    @ObservationIgnored let image: CGImage
    @ObservationIgnored var segmenter: any SubjectSegmenter = VisionSubjectSegmenter()
    /// Stores a new blob for the document (the window's blob queue in the app).
    @ObservationIgnored var storeBlob: @MainActor (Data, DocumentHandle) async throws -> Void
    @ObservationIgnored var sheets = SheetPresenter()
    let name: String
    private(set) var segmentation: SubjectSegmentation?
    var chosen: [Int] = []
    var soften = 1.0
    var result = Result.transparentImage
    private(set) var isWorking = false
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(window: DocumentWindowController, node: OpID, image: CGImage, storeBlob: @escaping @MainActor (Data, DocumentHandle) async throws -> Void) {
        self.window = window
        self.node = node
        self.image = image
        self.storeBlob = storeBlob
        name = SubjectImages.name(of: node, in: window.documentHandle.state)
    }

    // MARK: Commands

    /// The one selected image of `window` when the commands apply, else why not.
    static func target(_ window: DocumentWindowController?, isCached: (String) -> Bool) -> Target {
        guard let window else { return .refused("No document is open") }
        let state = window.documentHandle.state
        let nodes = window.selection.selection.ids.map(\.opID)
        if let refusal = SubjectImages.refusal(nodes, in: state, isCached: isCached) { return .refused(refusal) }
        return .image(nodes[0])
    }

    enum Target: Equatable {
        case image(OpID)
        case refused(String)
    }

    /// The full-resolution picture of `node` from the blob at `url`.
    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?, images: ImageFeatures,
                         storeBlob: @escaping @MainActor (Data, DocumentHandle) async throws -> Void) -> [Command] {
        let validation: @MainActor @Sendable () -> CommandValidation = {
            if case .refused(let reason) = target(window(), isCached: { images.cachedURL($0) != nil }) { return .disabled(reason) }
            return .enabled
        }
        let menu = MenuPath(ContextMenuCatalog.Menu.object, "Image", section: 1)
        return [
            Command(id: removeID, title: "Remove Background…", menu: menu, contexts: [.bitmap], keywords: ["image", "background", "subject", "cut out", "mask"],
                    validation: validation, action: .perform {
                        guard let window = window(), case .image(let node) = target(window, isCached: { images.cachedURL($0) != nil }) else { return }
                        open(node, in: window, images: images, storeBlob: storeBlob)
                    }),
            Command(id: selectID, title: "Select Subject", menu: menu, contexts: [.bitmap], keywords: ["image", "subject", "wand", "selection", "trace"],
                    validation: validation, action: .perform {
                        guard let window = window(), case .image(let node) = target(window, isCached: { images.cachedURL($0) != nil }) else { return }
                        Task { await selectSubject(node, in: window, images: images) }
                    }),
        ]
    }

    /// Opens the sheet for `node` and starts the segmentation.
    @discardableResult
    static func open(_ node: OpID, in window: DocumentWindowController, images: ImageFeatures,
                     storeBlob: @escaping @MainActor (Data, DocumentHandle) async throws -> Void) -> RemoveBackgroundModel? {
        let hash = ImageNodes.assetID(window.documentHandle.state.props(node).image.pixels)
        guard let url = images.cachedURL(hash), let image = decode(url) else { return nil }
        let model = RemoveBackgroundModel(window: window, node: node, image: image, storeBlob: storeBlob)
        model.present()
        model.start()
        return model
    }

    func present() {
        sheets.present(RemoveBackgroundSheet(model: self), title: "Remove Background", identifier: Self.sheet)
    }

    /// Segments the image off the main actor; every subject found is chosen.
    @discardableResult
    func start() -> Task<Void, Never> {
        isWorking = true
        message = nil
        let image = image
        let segmenter = segmenter
        let task = Task { [weak self] in
            do {
                let found = try await SubjectMask.segment(image, segmenter: segmenter)
                self?.segmentation = found
                self?.chosen = found.allInstances
            } catch SubjectMask.Failure.noSubjectFound {
                self?.message = "No subject was found in this image"
            } catch {
                self?.message = "The subject could not be found"
            }
            self?.isWorking = false
        }
        self.task = task
        return task
    }

    // MARK: The preview

    /// A click at `point` in the preview (unit image space, y down): that subject alone, or with
    /// kbd:[Shift] added to (or taken from) the chosen ones.
    func click(at point: Point, adding: Bool) {
        guard let segmentation, let instance = segmentation.instance(at: point) else { return }
        if adding {
            if let index = chosen.firstIndex(of: instance) { chosen.remove(at: index) } else { chosen.append(instance) }
        } else {
            chosen = [instance]
        }
        chosen.sort()
    }

    /// The preview: the image with the background faded to 30% and the chosen subjects at full
    /// strength, at most `side` px on the long edge.
    func preview(side: Int = 480) -> CGImage? {
        let scale = min(1, Double(side) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let segmentation, let mask = segmentation.mask(for: chosen).scaled(width: width, height: height) else { return context.makeImage() }
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height) {
            // Background pixels fade toward white: 30% of the picture shows through.
            let keep = 0.3 + 0.7 * Double(mask.values[index]) / 255
            for channel in 0..<3 {
                let value = Double(pixels[index * 4 + channel])
                pixels[index * 4 + channel] = UInt8((value * keep + 255 * (1 - keep)).rounded())
            }
        }
        return context.makeImage()
    }

    // MARK: Results

    var canRemove: Bool { segmentation != nil && !chosen.isEmpty && !isWorking }

    /// btn:[Remove Background]: the chosen result, one change; the sheet closes.
    @discardableResult
    func remove() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard canRemove, let segmentation else { return nil }
        let document = window.documentHandle
        guard document.state.isLive(node) else {
            message = "The image was deleted"
            return nil
        }
        isWorking = true
        let image = image, chosen = chosen, soften = soften, node = node, name = name, result = result
        let frame = ImageNodes.naturalRect(document.state.props(node).image)
        return Task { [weak self] in
            defer { self?.isWorking = false }
            do {
                let command: any WTModel.Command
                switch result {
                case .transparentImage:
                    let png = try await SubjectMask.transparentImage(image, segmentation: segmentation, instances: chosen, soften: soften)
                    try await self?.storeBlob(png, document)
                    command = RemoveImageBackground(node, pixels: Self.pixels(png, width: image.width, height: image.height), name: name)
                case .clippingPath:
                    let mask = try SubjectMask.mask(segmentation, instances: chosen, width: image.width, height: image.height)
                    command = ClipImageToSubject(node, contours: mask.path(in: frame), name: name)
                }
                let change = await document.perform(command).value
                self?.close()
                return change
            } catch {
                self?.message = "The background could not be removed"
                return nil
            }
        }
    }

    /// The `PixelSource` of an alpha PNG of `width` × `height`.
    static func pixels(_ png: Data, width: Int, height: Int) -> Wiretuner_Doc_V1_PixelSource {
        var pixels = Wiretuner_Doc_V1_PixelSource()
        pixels.blobSha256 = Data(SHA256.hash(data: png))
        pixels.format = "public.png"
        pixels.pixelWidth = Int32(width)
        pixels.pixelHeight = Int32(height)
        pixels.mode = .rgb
        pixels.bitsPerChannel = 8
        pixels.hasAlpha_p = true
        return pixels
    }

    func close() {
        task?.cancel()
        sheets.dismiss(Self.sheet)
    }

    // MARK: Select Subject

    /// *Select Subject*: every subject of `node` as the Trace tool's wand selection, the tool
    /// active; nil (with a status message) when none is found.
    @discardableResult
    static func selectSubject(_ node: OpID, in window: DocumentWindowController, images: ImageFeatures,
                              segmenter: any SubjectSegmenter = VisionSubjectSegmenter()) async -> WandSelection? {
        let state = window.documentHandle.state
        let hash = ImageNodes.assetID(state.props(node).image.pixels)
        guard let url = images.cachedURL(hash), let image = decode(url),
              let sampled = TraceFeatures.imageBitmap(node, url: url, state: state) else { return nil }
        do {
            let segmentation = try await SubjectMask.segment(image, segmenter: segmenter)
            let mask = try SubjectMask.mask(segmentation, instances: segmentation.allInstances, width: sampled.bitmap.width, height: sampled.bitmap.height)
            let selection = WandSelection(width: mask.width, height: mask.height, mask: mask.thresholded)
            window.toolManager.select(TraceTool.id)
            guard let tool = window.toolManager.activeTool as? TraceTool else { return nil }
            let area = Objects.bounds(of: node, in: state) ?? Rect(x: 0, y: 0, width: 1, height: 1)
            tool.seed(bitmap: sampled.bitmap, transform: sampled.transform, area: area, selection: selection)
            return selection
        } catch {
            window.canvas.showStatusMessage("No subject was found in this image")
            return nil
        }
    }
}

/// The Remove Background sheet.
struct RemoveBackgroundSheet: View {
    @Bindable var model: RemoveBackgroundModel

    static func cancel(_ model: RemoveBackgroundModel) -> () -> Void { { model.close() } }
    static func remove(_ model: RemoveBackgroundModel) -> () -> Void { { model.remove() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove Background").font(.headline)
            ZStack {
                if let preview = model.preview() {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                                    let point = Point(x: tap.location.x / max(geometry.size.width, 1), y: tap.location.y / max(geometry.size.height, 1))
                                    model.click(at: point, adding: NSEvent.modifierFlags.contains(.shift))
                                })
                            }
                        }
                        .accessibilityIdentifier("remove-background.preview")
                }
                if model.isWorking { ProgressView().controlSize(.large) }
            }
            .frame(width: 480, height: 320)
            HStack {
                Text("Soften edge")
                Slider(value: $model.soften, in: 0...10, step: 1).frame(width: 160).accessibilityIdentifier("remove-background.soften")
                Text("\(Int(model.soften)) px").monospacedDigit()
            }
            Picker("Result", selection: $model.result) {
                ForEach(RemoveBackgroundModel.Result.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("remove-background.result")
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("remove-background.message") }
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(model)).keyboardShortcut(.cancelAction)
                Button("Remove Background", action: Self.remove(model)).keyboardShortcut(.defaultAction).disabled(!model.canRemove)
            }
        }
        .padding(16)
    }
}

extension AppDelegate {
    /// *Remove Background…* and *Select Subject* (IMG-028), their blobs through the window's queue.
    func installSubjectCommands() {
        let documents = documents!
        let placement = imports.blobs
        let store: @MainActor (Data, DocumentHandle) async throws -> Void = { data, document in
            try await placement.store([(data: data, mediaType: "image/png")], for: document)
        }
        for command in RemoveBackgroundModel.commands(window: { documents.activeWindowController }, images: images, storeBlob: store) {
            commands.replace(command)
        }
    }
}
