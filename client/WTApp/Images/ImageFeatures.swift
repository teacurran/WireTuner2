import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync

/// One placed image as the canvas marks read it: its blob, frame, name, the node it was built
/// from and, for a top-level image, its effective resolution.
struct PlacedImageMark: Equatable {
    /// The `image` kind (image.proto).
    static let imageKind: UInt32 = 170

    let assetID: String
    /// The visible frame on the pasteboard.
    let frame: Rect
    let name: String
    let node: OpID?
    /// Pixels per inch at its placed size.
    let ppi: Double
}

/// What the image marks know about blobs beyond the document: which are cached here, which wait
/// to upload, whether the session is offline, and who placed an image.
@MainActor
struct ImageBlobStatus {
    /// Whether the blob `assetID` (hex SHA-256) is in this Mac's cache.
    var isCached: @MainActor (String) -> Bool = { _ in true }
    /// The blobs waiting to upload from this Mac.
    var pending: @MainActor () async -> Set<String> = { [] }
    var isOffline: @MainActor () -> Bool = { false }
    /// The display name of whoever's replica created `node`; nil for this Mac's own.
    var author: @MainActor (OpID) -> String? = { _ in nil }
}

/// The image marks and pixels of one window (IMG-004's app glue, IMG-006, IMG-017): the window's
/// `ImageStore` on the canvas tiles unless *Image display* is *Gray boxes* (the renderer then
/// draws every image as its grey placeholder, and the marks name them), the *Uploading* and
/// *Waiting for network* badges on images whose pixels are still going up, the "uploading from
/// <name>" line on images whose pixels have not arrived from a collaborator, and the amber mark on
/// images below *Warn when image resolution is below*.  The marks are drawn on a layer of their
/// own over the furniture, so they never reach an export or a print.
@MainActor
final class WindowImages {
    weak var window: DocumentWindowController?
    let document: DocumentHandle
    let preferences: PreferenceStore
    var status = ImageBlobStatus()
    let layer = CanvasOverlayLayer()
    private(set) var store: ImageStore?
    private(set) var pending: Set<String> = []
    private(set) var readies = 0
    private var observation: DocumentHandle.ObservationToken?
    private var statusToken: UUID?
    private var preferenceToken: UUID?
    private var previousViewportChange: (@MainActor (Viewport) -> Void)?
    /// Makes the store (the blob cache in the app).
    var makeStore: @MainActor () -> ImageStore?

    init(window: DocumentWindowController, preferences: PreferenceStore, makeStore: @escaping @MainActor () -> ImageStore?) {
        self.window = window
        document = window.documentHandle
        self.preferences = preferences
        self.makeStore = makeStore
    }

    var display: RedrawSettings.ImageDisplay { RedrawSettings(preferences: preferences).imageDisplay }

    func install() {
        guard let window else { return }
        let canvas = window.canvas
        layer.anchorPoint = .zero
        layer.frame = canvas.bounds
        layer.contentsScale = canvas.overlayScale
        layer.drawer = { [weak self] ctx in self?.draw(in: ctx) }
        canvas.layer?.insertSublayer(layer, above: canvas.furnitureLayer)
        previousViewportChange = canvas.onViewportChange
        canvas.onViewportChange = { [weak self] viewport in
            self?.previousViewportChange?(viewport)
            self?.viewportDidChange()
        }
        observation = document.observe { [weak self] _ in self?.contentDidChange() }
        statusToken = window.syncStatus.observe { [weak self] in self?.contentDidChange() }
        preferenceToken = preferences.observe { [weak self] change in self?.preferenceDidChange(change.id) }
        applyDisplay()
        contentDidChange()
    }

    func tearDown() {
        if let observation { document.stopObserving(observation) }
        if let statusToken { window?.syncStatus.stopObserving(statusToken) }
        observation = nil
        statusToken = nil
        layer.removeFromSuperlayer()
    }

    // MARK: Pixels

    /// The store follows *Image display*: none for *Gray boxes*.
    func applyDisplay() {
        guard let canvas = window?.canvas else { return }
        if display == .gray {
            store = nil
        } else if store == nil, let made = makeStore() {
            made.onReady = { [weak self] asset in
                Task { @MainActor in self?.imageReady(asset) }
            }
            store = made
        }
        canvas.tiles.setImageStore(store)
        layer.setNeedsDisplay()
    }

    /// A decoded level is ready: only its images' tiles repaint.
    func imageReady(_ asset: String) {
        readies += 1
        guard let canvas = window?.canvas else { return }
        canvas.tiles.invalidate(pasteboardRects: document.displayList.bounds(ofImageAsset: asset))
    }

    private func preferenceDidChange(_ id: String) {
        if id == PreferenceCatalog.Redraw.imageDisplay.id { applyDisplay() }
        if id == PreferenceCatalog.Document.lowResolutionWarning.id { layer.setNeedsDisplay() }
    }

    // MARK: Marks

    /// The document or sync state changed: the pending uploads are read again.
    @discardableResult
    func contentDidChange() -> Task<Void, Never> {
        layer.setNeedsDisplay()
        let status = status
        return Task { [weak self] in
            let pending = await status.pending()
            guard let self else { return }
            self.pending = pending
            self.layer.setNeedsDisplay()
        }
    }

    private func viewportDidChange() {
        guard let canvas = window?.canvas else { return }
        if layer.frame != canvas.bounds { layer.frame = canvas.bounds }
        layer.setNeedsDisplay()
    }

    /// Every placed image of the document.
    var marks: [PlacedImageMark] { Self.marks(in: document.state) }

    /// The live, reachable image nodes of `state` with their frames (the natural rect through the
    /// node's pasteboard transform) and effective resolution.
    static func marks(in state: EngineState) -> [PlacedImageMark] {
        state.store.nodes.sorted().compactMap { node -> PlacedImageMark? in
            guard state.store.kind(node) == PlacedImageMark.imageKind, state.isLive(node), Reachability.isReachable(node, in: state),
                  case .image(let image)? = state.props(node).kind else { return nil }
            let pixels = image.pixels
            let natural = ImageItem.naturalRect(pixelWidth: Int(pixels.pixelWidth), pixelHeight: Int(pixels.pixelHeight), dpiX: image.dpiX, dpiY: image.dpiY)
            let transform = Objects.pasteboardTransform(of: node, in: state)
            let placed = natural.width * hypot(transform.a, transform.b)
            let ppi = Double(pixels.pixelWidth) / (placed / 72)
            let name = image.sourceName.isEmpty ? image.common.name : image.sourceName
            return PlacedImageMark(assetID: ImportedBlob.hex(pixels.blobSha256), frame: natural.applying(transform), name: name, node: node, ppi: ppi)
        }
    }

    /// What one mark shows.
    enum Badge: Equatable {
        case uploading
        case waitingForNetwork
        /// The pixels have not arrived; the name of whoever is uploading them.
        case remote(String)
    }

    func badge(_ mark: PlacedImageMark) -> Badge? {
        if pending.contains(mark.assetID) { return status.isOffline() ? .waitingForNetwork : .uploading }
        guard !status.isCached(mark.assetID) else { return nil }
        return .remote(mark.node.flatMap(status.author) ?? "someone")
    }

    /// Whether `mark` is below *Warn when image resolution is below*.
    func isLowResolution(_ mark: PlacedImageMark) -> Bool {
        return mark.ppi < Double(preferences[PreferenceCatalog.Document.lowResolutionWarning])
    }

    func draw(in ctx: CGContext) {
        guard let window else { return }
        let viewport = window.canvas.viewport
        let gray = display == .gray
        for mark in marks {
            let corners = [Point(x: mark.frame.minX, y: mark.frame.minY), Point(x: mark.frame.maxX, y: mark.frame.maxY)].map(viewport.toView)
            let rect = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                              width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y))
            if isLowResolution(mark) {
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.62, blue: 0, alpha: 1))
                ctx.setLineWidth(2)
                ctx.stroke(rect.insetBy(dx: 1, dy: 1))
                ctx.restoreGState()
                Self.label(in: ctx, "\(Int(mark.ppi.rounded())) ppi", at: CGPoint(x: rect.minX + 4, y: rect.minY + 4), fill: CGColor(srgbRed: 1, green: 0.62, blue: 0, alpha: 0.9))
            }
            switch badge(mark) {
            case .uploading?:
                Self.label(in: ctx, "Uploading", at: CGPoint(x: rect.maxX - 76, y: rect.maxY - 20), fill: CGColor(gray: 0, alpha: 0.6), ring: true)
            case .waitingForNetwork?:
                Self.label(in: ctx, "Waiting for network", at: CGPoint(x: rect.maxX - 124, y: rect.maxY - 20), fill: CGColor(gray: 0, alpha: 0.6))
            case .remote(let name)?:
                Self.centered(in: ctx, [mark.name, "uploading from \(name)"], rect: rect)
            case nil:
                if gray { Self.centered(in: ctx, [mark.name], rect: rect) }
            }
        }
    }

    /// A small capsule with white text (a progress ring before it while uploading).
    static func label(in ctx: CGContext, _ text: String, at origin: CGPoint, fill: CGColor, ring: Bool = false) {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + (ring ? 16 : 8)
        let box = CGRect(x: origin.x, y: origin.y, width: width, height: 16)
        ctx.saveGState()
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        if ring {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.5)
            ctx.addArc(center: CGPoint(x: box.minX + 8, y: box.midY), radius: 4, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            ctx.strokePath()
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: box.minX + (ring ? 14 : 4), y: box.maxY - 4)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Lines of text centred in `rect` (the placeholder's name and "uploading from").
    static func centered(in ctx: CGContext, _ lines: [String], rect: CGRect) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.darkGray]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY + Double(index) * 14 - Double(lines.count - 1) * 7 + 4)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}

/// The imported-artwork features of the IMG epic's client-ui tasks: each window's image pixels
/// and marks (IMG-006, IMG-017), the Trace tool (IMG-023) and the share inbox (IMG-026's app half).
@MainActor
final class ImageFeatures {
    let preferences: PreferenceStore
    /// The blob cache's directory.
    var blobDirectory: @Sendable () throws -> URL = { try BlobCache.defaultDirectory() }
    /// A window's blob status (the session's store and authors in the app).
    var status: @MainActor (DocumentWindowController) -> ImageBlobStatus = { _ in ImageBlobStatus() }
    let trace: TraceFeatures
    let inbox: ShareInbox
    private var windows: [ObjectIdentifier: (window: DocumentWindowController, images: WindowImages, closing: NSObjectProtocol?)] = [:]

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        trace = TraceFeatures(preferences: preferences)
        inbox = ShareInbox()
    }

    func install(tools: ToolRegistry) {
        trace.install(tools: tools)
        trace.blobURL = { [weak self] hash in self?.cachedURL(hash) }
        trace.isCached = { [weak self] hash in self?.cachedURL(hash) != nil }
    }

    /// The blob `hash`'s file in the cache, when it is there.
    func cachedURL(_ hash: String) -> URL? {
        guard let directory = try? blobDirectory() else { return nil }
        let url = BlobCache(directory: directory).url(for: hash)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The store over the blob cache: a blob draws once its file is here.
    func makeStore() -> ImageStore? {
        guard let directory = try? blobDirectory() else { return nil }
        let cache = BlobCache(directory: directory)
        return ImageStore(blobURL: { hash in
            let url = cache.url(for: hash)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }, cacheDirectory: directory.appending(path: "levels"))
    }

    @discardableResult
    func attach(_ window: DocumentWindowController) -> WindowImages {
        let key = ObjectIdentifier(window)
        if let existing = windows[key] { return existing.images }
        let images = WindowImages(window: window, preferences: preferences) { [weak self] in self?.makeStore() }
        images.status = status(window)
        images.install()
        let closing = window.window.map { nswindow in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nswindow, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { if let window { self?.detach(window) } }
            }
        }
        windows[key] = (window, images, closing)
        return images
    }

    func detach(_ window: DocumentWindowController) {
        guard let entry = windows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        if let closing = entry.closing { NotificationCenter.default.removeObserver(closing) }
        entry.images.tearDown()
    }

    /// The app's blob status for `window`: the blob cache, the store's pending uploads, the sync
    /// state and the session's authors.
    static func status(for window: DocumentWindowController, directory: @escaping @Sendable () throws -> URL) -> ImageBlobStatus {
        var status = ImageBlobStatus()
        status.isCached = { hash in
            guard let directory = try? directory() else { return false }
            return FileManager.default.fileExists(atPath: BlobCache(directory: directory).url(for: hash).path)
        }
        status.pending = { [weak window] in
            guard let store = window?.documentHandle.model?.backend as? LocalStore else { return [] }
            return Set(((try? await store.pendingBlobs()) ?? []).map(\.hash))
        }
        status.isOffline = { [weak window] in
            if case .offline? = window?.syncStatus.state { return true }
            return false
        }
        status.author = { [weak window] node in window?.session?.author(of: node.replica)?.name }
        return status
    }
}

extension AppDelegate {
    /// Image pixels and marks, the Trace tool and the share inbox.
    func installImages() {
        let documents = documents!
        let directory = images.blobDirectory
        images.status = { ImageFeatures.status(for: $0, directory: directory) }
        images.install(tools: tools)
        let imports = imports
        images.inbox.window = { documents.activeWindowController }
        images.inbox.place = { urls, window, app in await ShareInbox.place(urls, on: window, from: app, imports: imports) }
        let library = library
        images.inbox.newDocument = { documents.open(documents.environment.makeDocument(id: library.createDocument(name: "Shared Items").id, title: "Shared Items")) }
        images.inbox.removeStale()
    }
}
