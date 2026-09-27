import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// The Trace tool's options as the options sheet edits them and the preferences keep them
/// (tracing.adoc, "Setting the Trace tool options"): the kernel's `Trace.Options` plus the
/// sampling resolution and the wand's tolerance.
struct TraceSettings: Codable, Equatable {
    var colors = 16
    var grays = false
    var noise = 0
    var conformity = 5
    var outerEdge = false
    var centerline = false
    var uniform = false
    /// Pixels per point the canvas is sampled at.
    var resolution = 2.0
    /// The wand's colour tolerance, 0 ... 255.
    var tolerance = 32
    /// *Tracer* (IMG-029): the raw value of `Trace.Tracer`; nil (settings saved before it) reads
    /// as *Classic*.
    var tracerName: String?

    var tracer: Trace.Tracer {
        get { tracerName.flatMap(Trace.Tracer.init(rawValue:)) ?? .classic }
        set { tracerName = newValue.rawValue }
    }
    /// *Trace layers*: the raw value of `TraceLayers`; nil (settings saved before it) reads as *All*.
    var layersName: String?

    var layers: TraceLayers {
        get { layersName.flatMap(TraceLayers.init(rawValue:)) ?? .all }
        set { layersName = newValue.rawValue }
    }

    static let key = "trace.options"

    var options: Trace.Options {
        Trace.Options(colors: colors, grays: grays, noiseTolerance: noise, conformity: conformity, outerEdge: outerEdge,
                      mode: centerline ? .centerline : .outline, uniform: uniform)
    }

    static func load(_ defaults: UserDefaults) -> TraceSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TraceSettings.self, from: $0) } ?? TraceSettings()
    }

    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// A wand selection (tracing.adoc, "Tracing an area of color"): the pixels of the sampled area
/// whose colour is within the tolerance of a clicked pixel and connected to it, added to or
/// taken from the selection.
struct WandSelection: Equatable {
    let width: Int
    let height: Int
    private(set) var mask: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        mask = [UInt8](repeating: 0, count: width * height)
    }

    /// A selection of the pixels `mask` sets (one byte per pixel, 1 selected), as *Select Subject*
    /// makes one (IMG-028); a mask of the wrong size selects nothing.
    init(width: Int, height: Int, mask: [UInt8]) {
        self.init(width: width, height: height)
        if mask.count == width * height { self.mask = mask.map { $0 == 0 ? 0 : 1 } }
    }

    var count: Int { mask.reduce(0) { $0 + Int($1) } }
    var isEmpty: Bool { !mask.contains(1) }

    /// Flood-fills from `(x, y)` over `bitmap` within `tolerance`, adding (or subtracting) the region.
    mutating func apply(_ bitmap: Trace.Bitmap, x: Int, y: Int, tolerance: Int, subtract: Bool) {
        guard x >= 0, y >= 0, x < width, y < height, bitmap.width == width, bitmap.height == height else { return }
        func pixel(_ index: Int) -> (Int, Int, Int) {
            (Int(bitmap.pixels[index * 4]), Int(bitmap.pixels[index * 4 + 1]), Int(bitmap.pixels[index * 4 + 2]))
        }
        let seed = pixel(y * width + x)
        var visited = [Bool](repeating: false, count: width * height)
        var stack = [y * width + x]
        visited[stack[0]] = true
        while let index = stack.popLast() {
            mask[index] = subtract ? 0 : 1
            let (px, py) = (index % width, index / width)
            for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let next = ny * width + nx
                guard !visited[next] else { continue }
                let color = pixel(next)
                if abs(color.0 - seed.0) <= tolerance && abs(color.1 - seed.1) <= tolerance && abs(color.2 - seed.2) <= tolerance {
                    visited[next] = true
                    stack.append(next)
                }
            }
        }
    }

    /// Whether the pixel at `(x, y)` is selected.
    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] == 1
    }

    /// *Tab*: the selection inverted.
    mutating func invert() {
        mask = mask.map { 1 - $0 }
    }

    /// `bitmap` with everything outside the selection turned to paper (white), for tracing.
    func masked(_ bitmap: Trace.Bitmap) -> Trace.Bitmap {
        var pixels = bitmap.pixels
        for index in 0..<(width * height) where mask[index] == 0 {
            pixels[index * 4] = 255
            pixels[index * 4 + 1] = 255
            pixels[index * 4 + 2] = 255
            pixels[index * 4 + 3] = 255
        }
        return Trace.Bitmap(width: width, height: height, pixels: pixels)!
    }
}

/// A controller a closure made before it can reach, weakly.
@MainActor
final class WeakController {
    weak var controller: NSViewController?
}

/// The Trace tool (IMG-023; tracing.adoc, "Tracing an area", "Tracing an area of color"): a marquee
/// (kbd:[Shift] square, kbd:[Option] from the centre) traces the artwork under it; a click picks
/// an area of colour with the wand (kbd:[Shift] adds, kbd:[Option] takes away, kbd:[Tab] inverts)
/// shown with marching ants, and kbd:[Return] traces it, or kbd:[E] converts its edge to one
/// unfilled path.  The trace runs off the main actor with a progress sheet and btn:[Cancel]; the
/// result is one named group directly above the traced image.  A placeholder (pixels not here)
/// is refused.
@MainActor
final class TraceTool: Tool {
    static let id: ToolID = "trace"
    static let dragThreshold = 3.0

    let features: TraceFeatures
    private(set) var context: ToolContext?
    private(set) var start: Point?
    private(set) var current: Point?
    private(set) var modifiers: KeyModifiers = []
    /// The wand's sampled area, its map back to the pasteboard, and the selection.
    private(set) var wand: (bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform, area: Rect, selection: WandSelection)?

    init(features: TraceFeatures) {
        self.features = features
    }

    var cursor: NSCursor { .crosshair }
    var hasSomethingToCancel: Bool { start != nil || wand != nil }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage("Drag to trace an area; click to pick a color area, Return to trace it")
    }

    func deactivate() {
        cancel()
        context = nil
    }

    /// The marquee in pasteboard space, with kbd:[Shift] and kbd:[Option] applied.
    static func marquee(from start: Point, to end: Point, modifiers: KeyModifiers) -> Rect {
        var dx = end.x - start.x, dy = end.y - start.y
        if modifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if modifiers.contains(.option) {
            return Rect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return Rect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
    }

    var marquee: Rect? {
        guard let start, let current else { return nil }
        return Self.marquee(from: start, to: current, modifiers: modifiers)
    }

    func mouseDown(_ e: CanvasEvent) {
        start = e.pasteboardPoint
        current = e.pasteboardPoint
        modifiers = e.modifiers
    }

    func mouseDragged(_ e: CanvasEvent) {
        current = e.pasteboardPoint
        modifiers = e.modifiers
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        guard let context, let start else { return }
        defer {
            self.start = nil
            current = nil
            context.host.setNeedsOverlayDisplay()
        }
        let view = context.host.viewport.toView(start)
        if hypot(e.viewPoint.x - view.x, e.viewPoint.y - view.y) <= Self.dragThreshold {
            pick(at: e.pasteboardPoint, modifiers: e.modifiers)
        } else {
            features.trace(Self.marquee(from: start, to: e.pasteboardPoint, modifiers: e.modifiers), in: context)
        }
    }

    /// What the wand options popover does with the selection.
    enum WandAction: String, CaseIterable, Identifiable {
        /// *Trace selection*: the selected pixels with the current options.
        case trace
        /// *Convert selection edge*: one closed path along the selection's boundary, unfilled.
        case edge

        var id: String { rawValue }
        var title: String { self == .trace ? "Trace selection" : "Convert selection edge" }
    }

    /// A wand click: the area under the image (or the view) is sampled once, then each click
    /// adds or takes away a connected area of colour; a plain click inside the selection opens
    /// the wand options popover.
    func pick(at point: Point, modifiers: KeyModifiers) {
        guard let context else { return }
        if let wand, modifiers.isDisjoint(with: [.shift, .option]), let inverse = wand.transform.inverted() {
            let pixel = inverse.apply(point)
            if wand.selection.contains(x: Int(pixel.x), y: Int(pixel.y)) {
                features.showWandOptions(self, context.host.viewport.toView(point), context)
                return
            }
        }
        if wand == nil || !(wand!.area.contains(point)) || !(modifiers.contains(.shift) || modifiers.contains(.option)) {
            guard let area = features.sampleArea(at: point, in: context), let sampled = features.sample(area, in: context, clip: false) else { return }
            wand = (sampled.bitmap, sampled.transform, area, WandSelection(width: sampled.bitmap.width, height: sampled.bitmap.height))
        }
        guard var current = wand, let inverse = current.transform.inverted() else { return }
        let pixel = inverse.apply(point)
        current.selection.apply(current.bitmap, x: Int(pixel.x), y: Int(pixel.y), tolerance: features.settings.tolerance, subtract: modifiers.contains(.option))
        wand = current
        context.host.setNeedsOverlayDisplay()
        context.host.showStatusMessage("\(current.selection.count) pixels selected: Return traces them, E converts the edge, Tab inverts")
    }

    /// *Select Subject* (IMG-028): `selection` of `bitmap` (mapped to the pasteboard by
    /// `transform`, over `area`) becomes the wand selection, marching ants and all, as if picked.
    func seed(bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform, area: Rect, selection: WandSelection) {
        wand = (bitmap, transform, area, selection)
        context?.host.setNeedsOverlayDisplay()
        context?.host.showStatusMessage("\(selection.count) pixels selected: Return traces them, E converts the edge, Tab inverts")
    }

    /// The popover's btn:[Trace]: runs `action` on the selection and ends it.
    @discardableResult
    func perform(_ action: WandAction) -> Task<Void, Never>? {
        guard let context, let current = wand else { return nil }
        wand = nil
        context.host.setNeedsOverlayDisplay()
        return features.traceSelection(current.bitmap, selection: current.selection, transform: current.transform, area: current.area,
                                       edgeOnly: action == .edge, in: context)
    }

    func flagsChanged(_ e: CanvasEvent) {
        modifiers = e.modifiers
        context?.host.setNeedsOverlayDisplay()
    }

    func keyDown(_ e: NSEvent) -> Bool {
        guard let context, var current = wand else { return false }
        switch e.keyCode {
        case 36, 76:
            features.traceSelection(current.bitmap, selection: current.selection, transform: current.transform, area: current.area, edgeOnly: false, in: context)
            wand = nil
        case 48:
            current.selection.invert()
            wand = current
        case 14:
            features.traceSelection(current.bitmap, selection: current.selection, transform: current.transform, area: current.area, edgeOnly: true, in: context)
            wand = nil
        default:
            return false
        }
        context.host.setNeedsOverlayDisplay()
        return true
    }

    /// The marquee, and the wand selection's edge as marching ants.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        if let marquee {
            let a = viewport.toView(Point(x: marquee.minX, y: marquee.minY)), b = viewport.toView(Point(x: marquee.maxX, y: marquee.maxY))
            ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        if let wand, !wand.selection.isEmpty {
            for contour in Trace.outline(mask: wand.selection.mask, width: wand.selection.width, height: wand.selection.height, conformity: 8) {
                for (index, segment) in contour.segments.enumerated() {
                    let p0 = viewport.toView(wand.transform.apply(segment.p0)), p3 = viewport.toView(wand.transform.apply(segment.p3))
                    if index == 0 { ctx.move(to: CGPoint(x: p0.x, y: p0.y)) }
                    ctx.addLine(to: CGPoint(x: p3.x, y: p3.y))
                }
                ctx.closePath()
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    func cancel() {
        start = nil
        current = nil
        wand = nil
        context?.host.setNeedsOverlayDisplay()
    }
}

/// Runs traces for the tool: sampling, the progress sheet, placement, and the options sheet.
@MainActor
@Observable
final class TraceFeatures {
    @ObservationIgnored let preferences: PreferenceStore
    var settings: TraceSettings {
        didSet { settings.save(preferences.defaults) }
    }
    private(set) var progress: Double?
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Shows the progress sheet while a trace runs (replaceable in tests).
    @ObservationIgnored var showProgress: @MainActor (TraceFeatures, ToolContext) -> Void = { _, _ in }
    @ObservationIgnored var hideProgress: @MainActor () -> Void = {}
    /// Whether an image's pixels are on this Mac (a placeholder is refused).
    @ObservationIgnored var isCached: @MainActor (String) -> Bool = { _ in true }
    /// Where an image's pixels are on this Mac.
    @ObservationIgnored var blobURL: @MainActor (String) -> URL? = { _ in nil }
    /// Shows the wand options popover at a view point (replaceable in tests).
    @ObservationIgnored var showWandOptions: @MainActor (TraceTool, Point, ToolContext) -> Void = { tool, point, context in
        WandOptionsPopover.show(for: tool, at: point, in: context)
    }

    init(preferences: PreferenceStore) {
        self.preferences = preferences
        settings = TraceSettings.load(preferences.defaults)
    }

    func install(tools: ToolRegistry) {
        let options: @MainActor @Sendable () -> NSViewController = { [self] in
            let box = WeakController()
            let controller = NSHostingController(rootView: TraceOptionsSheet(features: self) { ToolOptionsPlaceholder.close(box.controller?.view.window) })
            box.controller = controller
            controller.title = "Trace Options"
            return controller
        }
        tools.replace(ToolDescriptor(id: TraceTool.id, title: "Trace", symbolName: "photo", shortcuts: [KeyEquivalent("8")], options: options,
                                     helpSlug: "tracing") { [self] in
            TraceTool(features: self)
        })
        showProgress = { features, context in
            guard let window = (context.host as? NSView)?.window else { return }
            let sheet = NSWindow(contentViewController: NSHostingController(rootView: TraceProgressSheet(features: features)))
            sheet.isReleasedWhenClosed = false
            window.beginSheet(sheet)
            features.hideProgress = { [weak window, weak sheet] in if let sheet { window?.endSheet(sheet) } }
        }
    }

    /// The image under `point`, the area the wand samples: its frame (the view's visible area
    /// over no image).
    func sampleArea(at point: Point, in context: ToolContext) -> Rect? {
        if let mark = marks(in: context.document.state).last(where: { $0.frame.contains(point) }) {
            guard isCached(mark.assetID) else {
                refuse(mark.name, in: context)
                return nil
            }
            return mark.frame
        }
        let viewport = context.host.viewport
        let a = viewport.toPasteboard(Point(x: 0, y: 0)), b = viewport.toPasteboard(Point(x: viewport.size.width, y: viewport.size.height))
        return Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func refuse(_ name: String, in context: ToolContext) {
        message = "“\(name)” cannot be traced until its pixels have downloaded"
        context.host.showStatusMessage(message!)
    }

    /// What `rect` traces: the image under its centre from its own pixels (a marquee turns what
    /// lies outside it to paper), else the canvas rendered at *Resolution*.
    func sample(_ rect: Rect, in context: ToolContext, clip: Bool) -> (bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform)? {
        let state = context.document.state
        if let mark = marks(in: state).last(where: { $0.frame.contains(rect.center) }), let node = mark.node,
           let url = blobURL(mark.assetID), let sampled = Self.imageBitmap(node, url: url, state: state) {
            return clip ? (Self.clipped(sampled.bitmap, transform: sampled.transform, to: rect), sampled.transform) : sampled
        }
        return Trace.Sampling.render(settings.layers.filter(context.document.displayList, in: state), rect: rect, pixelsPerPoint: settings.resolution)
    }

    /// The placed images on the *Trace layers* choice's layers.
    func marks(in state: EngineState) -> [PlacedImageMark] {
        let layers = settings.layers
        guard layers != .all else { return WindowImages.marks(in: state) }
        let order = LayerOrder(state)
        return WindowImages.marks(in: state).filter { mark in mark.node.map { layers.includes(node: $0, in: state, order: order) } ?? false }
    }

    /// An image node's pixels (at most 2,048 on the long edge) and the map from them to the pasteboard.
    static func imageBitmap(_ node: OpID, url: URL, state: EngineState) -> (bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform)? {
        guard case .image(let image)? = state.props(node).kind, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options), let bitmap = Trace.Bitmap(cgImage: decoded) else { return nil }
        let natural = ImageItem.naturalRect(pixelWidth: Int(image.pixels.pixelWidth), pixelHeight: Int(image.pixels.pixelHeight), dpiX: image.dpiX, dpiY: image.dpiY)
        let toLocal = WTGeometry.AffineTransform.scale(x: natural.width / Double(bitmap.width), y: natural.height / Double(bitmap.height))
        return (bitmap, toLocal.concatenating(Objects.pasteboardTransform(of: node, in: state)))
    }

    /// `bitmap` with the pixels whose centres fall outside `rect` turned to paper.
    static func clipped(_ bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform, to rect: Rect) -> Trace.Bitmap {
        var pixels = bitmap.pixels
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where !rect.contains(transform.apply(Point(x: Double(x) + 0.5, y: Double(y) + 0.5))) {
                let index = (y * bitmap.width + x) * 4
                pixels.replaceSubrange(index..<(index + 4), with: [255, 255, 255, 255])
            }
        }
        return Trace.Bitmap(width: bitmap.width, height: bitmap.height, pixels: pixels)!
    }

    /// The topmost top-level object under `rect`'s centre, which the result goes above.
    func source(for rect: Rect, in context: ToolContext) -> OpID? {
        context.selection.pick(at: context.host.viewport.toView(rect.center), viewport: context.host.viewport, subselect: false)?.id.opID
    }

    /// A marquee trace.
    @discardableResult
    func trace(_ rect: Rect, in context: ToolContext) -> Task<Void, Never>? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        if let refused = placeholder(under: rect, in: context) {
            refuse(refused, in: context)
            return nil
        }
        guard let sampled = sample(rect, in: context, clip: true) else { return nil }
        return run(sampled.bitmap, transform: sampled.transform, source: source(for: rect, in: context), options: settings.options, in: context)
    }

    /// A wand selection's trace, or its edge as one unfilled path.
    @discardableResult
    func traceSelection(_ bitmap: Trace.Bitmap, selection: WandSelection, transform: WTGeometry.AffineTransform, area: Rect, edgeOnly: Bool,
                        in context: ToolContext) -> Task<Void, Never>? {
        guard !selection.isEmpty else { return nil }
        let source = source(for: area, in: context)
        if edgeOnly {
            let contours = Trace.outline(mask: selection.mask, width: selection.width, height: selection.height, conformity: settings.conformity, keepHoles: false)
            let path = Trace.TracedPath(contours: contours.map { $0.applying(transform) }, stroke: Color(red: 0, green: 0, blue: 0))
            return place(Trace.Result(paths: [path]), source: source, name: "Selection edge", in: context)
        }
        return run(selection.masked(bitmap), transform: transform, source: source, options: settings.options, in: context)
    }

    /// The name of a placeholder image under `rect`, if any.
    func placeholder(under rect: Rect, in context: ToolContext) -> String? {
        marks(in: context.document.state).first { $0.frame.intersects(rect) && !isCached($0.assetID) }?.name
    }

    private func run(_ bitmap: Trace.Bitmap, transform: WTGeometry.AffineTransform, source: OpID?, options: Trace.Options, in context: ToolContext) -> Task<Void, Never> {
        task?.cancel()
        progress = 0
        message = nil
        showProgress(self, context)
        let box = TraceProgressBox()
        box.receive = { [weak self] value in self?.progress = value }
        let photo = settings.tracer == .photo
        let task = Task { [self] in
            do {
                if photo {
                    let result = try await PhotoTrace.trace(bitmap, options: options, transform: transform) { value in box.send(value) }
                    finish()
                    placePhoto(result, source: source, in: context)
                } else {
                    let result = try await Trace.trace(bitmap, options: options, transform: transform) { value in box.send(value) }
                    finish()
                    place(result, source: source, name: nil, in: context)
                }
            } catch {
                finish()
                message = "The trace was cancelled"
            }
        }
        self.task = task
        return task
    }

    private func finish() {
        progress = nil
        hideProgress()
    }

    /// btn:[Cancel] in the progress sheet.
    func cancelTrace() {
        task?.cancel()
    }

    /// The traced paths as one group above `source` (or on the current layer), one change.
    @discardableResult
    func place(_ result: Trace.Result, source: OpID?, name: String?, in context: ToolContext) -> Task<Void, Never> {
        let state = context.document.state
        let sourceName = source.map { ObjectNaming.name(of: $0, in: state) }
        let children = Self.imported(result.paths)
        return place(ImportedGroup(children: children, name: name ?? sourceName.map { "Trace of \($0)" } ?? "Trace"), source: source, in: context)
    }

    /// `group` above `source` (or on the current layer), one change.
    @discardableResult
    func place(_ group: ImportedGroup, source: OpID?, in context: ToolContext) -> Task<Void, Never> {
        let layer = context.objectEditing?.activeLayer
        let sink = context.commandSink
        return Task { [weak self] in
            let change = await sink.perform(PlaceTrace(group, above: source, layer: layer)).value
            if change == nil { self?.message = "Nothing was traced" }
        }
    }

    /// Traced paths as imported ones.
    static func imported(_ paths: [Trace.TracedPath]) -> [ImportedNode] {
        paths.map { traced in
            let contours = traced.contours.map(Self.imported)
            let stroke = traced.stroke.map { ImportedStroke(paint: .solid($0), style: StrokeStyle(width: traced.strokeWidth ?? 1)) }
            return .path(ImportedPath(contours: contours, fill: traced.fill.map { .solid(traced.color ?? $0) } ?? .none, stroke: stroke))
        }
    }

    /// A kernel contour as an imported one (cubic segments).
    static func imported(_ contour: Contour) -> ImportedContour {
        ImportedContour(start: contour.segments.first?.p0 ?? Point(x: 0, y: 0),
                        segments: contour.segments.map { .cubic(control1: $0.p1, control2: $0.p2, to: $0.p3) }, closed: contour.isClosed)
    }
}

/// Carries the kernel's progress from its queue to the main actor.
final class TraceProgressBox: @unchecked Sendable {
    var receive: @MainActor (Double) -> Void = { _ in }

    func send(_ value: Double) {
        Task { @MainActor [self] in receive(value) }
    }
}

/// The progress sheet with btn:[Cancel].
struct TraceProgressSheet: View {
    let features: TraceFeatures

    static func cancel(_ features: TraceFeatures) -> () -> Void { { features.cancelTrace() } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tracing…").font(.headline)
            ProgressView(value: features.progress ?? 1)
            HStack {
                Spacer()
                Button("Cancel", action: Self.cancel(features)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// The Trace tool's options sheet (a double-click on the tool), kept in the preferences.
struct TraceOptionsSheet: View {
    @Bindable var features: TraceFeatures
    let close: @MainActor () -> Void

    var body: some View {
        Form {
            Picker("Tracer", selection: $features.settings.tracer) {
                ForEach(Trace.Tracer.allCases, id: \.self) { Text(PhotoTrace.title($0)).tag($0) }
            }
            .accessibilityIdentifier("trace.tracer")
            Stepper("Colors \(features.settings.colors)", value: $features.settings.colors, in: 2...256)
            Toggle("Grays", isOn: $features.settings.grays)
            Stepper("Noise tolerance \(features.settings.noise)", value: $features.settings.noise, in: 0...20)
            Stepper("Trace conformity \(features.settings.conformity)", value: $features.settings.conformity, in: 0...10)
            Toggle("Outer edge only", isOn: $features.settings.outerEdge)
            Toggle("Centerline", isOn: $features.settings.centerline)
            Toggle("Uniform lines", isOn: $features.settings.uniform)
            Stepper("Resolution \(Int(features.settings.resolution * 72)) ppi", value: $features.settings.resolution, in: 1...8, step: 1)
            Picker("Trace layers", selection: $features.settings.layers) {
                ForEach(TraceLayers.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("trace.layers")
            Stepper("Wand tolerance \(features.settings.tolerance)", value: $features.settings.tolerance, in: 0...255)
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// The wand options popover (tracing.adoc, "Tracing an area of color"): a click inside the
/// selection offers *Trace selection* or *Convert selection edge*, then btn:[Trace].
struct WandOptionsView: View {
    let tool: TraceTool
    let close: @MainActor () -> Void
    @State var action: TraceTool.WandAction = .trace

    static func trace(_ tool: TraceTool, _ action: TraceTool.WandAction, close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            close()
            tool.perform(action)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $action) {
                ForEach(TraceTool.WandAction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("trace.wand.action")
            HStack {
                Spacer()
                Button("Trace", action: Self.trace(tool, action, close: close)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("trace.wand.trace")
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}

/// Presents `WandOptionsView` in an `NSPopover` beside the click.
@MainActor
enum WandOptionsPopover {
    static func show(for tool: TraceTool, at point: Point, in context: ToolContext) {
        guard let view = context.host as? NSView else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WandOptionsView(tool: tool) { [weak popover] in popover?.close() })
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), of: view, preferredEdge: .maxY)
    }
}
