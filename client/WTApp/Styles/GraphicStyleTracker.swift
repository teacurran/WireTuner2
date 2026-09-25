import CoreGraphics
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Styles panel's view of one document (styles.adoc, "Client"; LIB-020): a
/// `GraphicStyleResolver` and a `GraphicStyleIndex` kept current on every change the document
/// applies -- local, undo, redo, remote or a reload -- so the panel's rows, previews, counts and
/// highlights re-read when `revision` moves.  A reload re-reads the index in full; a change
/// refreshes only the nodes it touched.
@MainActor @Observable
final class GraphicStyleTracker {
    private(set) var resolver: GraphicStyleResolver
    private(set) var index: GraphicStyleIndex
    /// Counts the changes applied since the tracker was made.
    private(set) var revision = 0
    @ObservationIgnored let document: WTModel.Document
    @ObservationIgnored private var token: WTModel.Document.ObservationToken?

    init(document: WTModel.Document) {
        self.document = document
        let resolver = GraphicStyleResolver(document.state)
        self.resolver = resolver
        index = GraphicStyleIndex(document.state, styles: resolver)
        token = document.observe { [weak self] event in self?.apply(event) }
    }

    /// Stops following the document.
    func stop() {
        if let token { document.stopObserving(token) }
        token = nil
    }

    func apply(_ event: DocumentEvent) {
        resolver.update(event.after)
        if event.origin == .reload {
            index = GraphicStyleIndex(event.after, styles: resolver)
        } else {
            index.refresh(GraphicStyleIndex.touched(by: event.change), in: event.after, styles: resolver)
        }
        revision += 1
    }
}

/// A style's preview (styles.adoc, "Styles panel": "rendered by `WTRender` from a fixed sample
/// path ... through the resolver"): a rounded rectangle drawn with the style's resolved look, the
/// categories no style of its chain supplies taken from the document defaults -- what a new object
/// with the style would show.  Swatch references resolve through the document's colours.
enum StylePreview {
    static let compact = Size(width: 30, height: 20)
    static let large = Size(width: 64, height: 40)

    /// The look a preview draws.
    static func appearance(of style: OpID, resolver: GraphicStyleResolver, state: EngineState) -> Wiretuner_Doc_V1_AppearanceProps {
        let defaults = DocumentDefaults.appearance(in: state)
        guard let resolved = resolver.resolved(style) else { return defaults }
        var look = resolved.appearance
        if resolved.sources[.fills] == nil { look.fills = defaults.fills }
        if resolved.sources[.strokes] == nil { look.strokes = defaults.strokes }
        if resolved.sources[.effects] == nil { look.effects = defaults.effects }
        return look
    }

    /// The sample path: a rounded rectangle inset in `size`.
    static func sample(_ size: Size) -> DisplayPath {
        let inset = 3.0
        let rect = Rect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let radius = min(rect.width, rect.height) / 4
        let k = radius * 0.5523
        var path = DisplayPath()
        path.move(to: Point(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: Point(x: rect.maxX - radius, y: rect.minY))
        path.addCubicCurve(control1: Point(x: rect.maxX - radius + k, y: rect.minY), control2: Point(x: rect.maxX, y: rect.minY + radius - k),
                           to: Point(x: rect.maxX, y: rect.minY + radius))
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY - radius))
        path.addCubicCurve(control1: Point(x: rect.maxX, y: rect.maxY - radius + k), control2: Point(x: rect.maxX - radius + k, y: rect.maxY),
                           to: Point(x: rect.maxX - radius, y: rect.maxY))
        path.addLine(to: Point(x: rect.minX + radius, y: rect.maxY))
        path.addCubicCurve(control1: Point(x: rect.minX + radius - k, y: rect.maxY), control2: Point(x: rect.minX, y: rect.maxY - radius + k),
                           to: Point(x: rect.minX, y: rect.maxY - radius))
        path.addLine(to: Point(x: rect.minX, y: rect.minY + radius))
        path.addCubicCurve(control1: Point(x: rect.minX, y: rect.minY + radius - k), control2: Point(x: rect.minX + radius - k, y: rect.minY),
                           to: Point(x: rect.minX + radius, y: rect.minY))
        path.close()
        return path
    }

    /// `appearance` drawn on the sample path at `size` points (2× pixels).
    static func image(_ appearance: Wiretuner_Doc_V1_AppearanceProps, state: EngineState, size: Size) -> CGImage? {
        let look = ColorResolver.$current.withValue(ColorResolver(state)) { Appearances.resolve(appearance) }
        let item = DisplayItem.path(PathItem(path: sample(size), appearance: look))
        return CoreGraphicsRenderer(background: .white).renderBitmap(DisplayList(canvas: "style-preview", items: [item]), viewport: Viewport(size: size), scale: 2)
    }
}
