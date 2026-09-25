import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTRender

/// The preview strip under a glyph tab's canvas (glyph-editing.adoc, "The preview strip";
/// FONT-017): a line set with the font as it is -- every glyph's live artwork flattened as the
/// generator would, with kerning (`MetricsSetting`, the Metrics window's setting) -- the current
/// glyph highlighted, characters without a glyph as hollow boxes.  The text defaults to the *Font
/// preview text* preference; the size pop-up and the *Kern* checkbox set the rest.  A click on a
/// glyph opens it.  The strip follows the document 150 ms after a change; its top edge resizes
/// it, down to hidden, and menu:View[Preview Strip] shows or hides it.
@MainActor
@Observable
final class PreviewStripModel {
    static let sizes: [Double] = [24, 36, 48, 72, 96]
    static let debounce: Duration = .milliseconds(150)
    static let minimumHeight = 40.0

    @ObservationIgnored let document: DocumentHandle
    /// The glyph highlighted (the tab's).
    let glyph: OpID?
    var text: String {
        didSet { if text != oldValue { reload() } }
    }
    var size = 36.0
    var kerning = true {
        didSet { if kerning != oldValue { reload() } }
    }
    var height = 90.0
    var isHidden = false
    private(set) var setting = MetricsSetting(items: [])
    private(set) var upm = 1_000.0
    private(set) var ascender = 800.0
    @ObservationIgnored var debounce = PreviewStripModel.debounce
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var token: DocumentHandle.ObservationToken?
    /// Opens a glyph clicked in the strip.
    @ObservationIgnored var open: @MainActor (OpID) -> Void = { _ in }

    init(document: DocumentHandle, glyph: OpID?, text: String) {
        self.document = document
        self.glyph = glyph
        self.text = text
        reload()
        token = document.observe { [weak self] _ in self?.schedule() }
    }

    func stop() {
        if let token { document.stopObserving(token) }
        token = nil
        pending?.cancel()
    }

    /// A change arrived: the strip redraws once changes pause.
    func schedule() {
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// Waits for the redraw in flight (tests).
    func settle() async { await pending?.value }

    func reload() {
        let state = document.state
        let metrics = WTModel.FontInfo(state).metrics
        upm = Double(metrics.upm)
        ascender = metrics.ascender
        setting = MetricsSetting.layout(text, in: state, kerning: kerning)
    }

    var scale: Double { size / max(upm, 1) }

    /// The item at `x` view points along the strip (12 points of margin).
    func item(atX x: Double) -> MetricsSetting.Item? {
        let unit = (x - 12) / scale
        return setting.items.first { unit >= $0.x && unit < $0.x + $0.advance + $0.kern }
    }

    /// A click at `x`: its glyph opens.
    func click(atX x: Double) {
        if let glyph = item(atX: x)?.glyph { open(glyph) }
    }

    /// Dragging the top edge by `delta` (points upward); below the minimum the strip hides.
    func resize(by delta: Double) {
        let proposed = height + delta
        if proposed < Self.minimumHeight {
            isHidden = true
        } else {
            height = min(proposed, 400)
            isHidden = false
        }
    }

    /// The glyph paths in view space, flipped (y down), with each item's box and highlight.
    func paths(height viewHeight: Double) -> [(path: CGPath, box: CGRect?, highlighted: Bool)] {
        let scale = scale
        let baseline = min(ascender * scale + 8, viewHeight)
        return setting.items.map { item in
            let transform = CGAffineTransform(translationX: 12 + item.x * scale, y: baseline).scaledBy(x: scale, y: scale)
            let path = MetricsModel.cgPath(DisplayPath(contours: item.outline.contours), transform: transform)
            let box = item.glyph == nil ? CGRect(x: 12 + item.x * scale, y: baseline - ascender * scale, width: item.advance * scale, height: ascender * scale) : nil
            return (path, box, item.glyph != nil && item.glyph == glyph)
        }
    }
}

/// The strip's drawing.
@MainActor
final class PreviewStripCanvas: NSView {
    let model: PreviewStripModel
    private var dragStart: NSPoint?

    init(model: PreviewStripModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PreviewStripCanvas is built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let context = NSGraphicsContext.current!.cgContext
        for entry in model.paths(height: bounds.height) {
            if entry.highlighted, let bounds = Optional(entry.path.boundingBoxOfPath), !bounds.isNull {
                context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor)
                context.fill(bounds.insetBy(dx: -2, dy: -2))
            }
            context.addPath(entry.path)
            context.setFillColor(NSColor.labelColor.cgColor)
            context.fillPath()
            if let box = entry.box {
                context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
                context.stroke(box)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        model.click(atX: convert(event.locationInWindow, from: nil).x)
    }
}

struct PreviewStripCanvasRepresentable: NSViewRepresentable {
    let model: PreviewStripModel

    func makeNSView(context: Context) -> PreviewStripCanvas { PreviewStripCanvas(model: model) }
    func updateNSView(_ view: PreviewStripCanvas, context: Context) { view.needsDisplay = true }
}

/// The strip: the resize edge, the text field, the size pop-up, *Kern*, and the setting.
struct PreviewStripView: View {
    @Bindable var model: PreviewStripModel

    static func resizing(_ model: PreviewStripModel) -> (DragGesture.Value) -> Void {
        { value in model.resize(by: -value.translation.height) }
    }

    var body: some View {
        if model.isHidden {
            Color.clear.frame(height: 0)
        } else {
            strip
        }
    }

    var strip: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 4)
                .gesture(DragGesture().onEnded(Self.resizing(model)))
                .accessibilityIdentifier("previewStrip.edge")
            HStack {
                TextField("Preview", text: $model.text).frame(width: 220).accessibilityIdentifier("previewStrip.text")
                Picker("Size", selection: $model.size) { ForEach(PreviewStripModel.sizes, id: \.self) { Text("\(Int($0))").tag($0) } }
                    .frame(width: 110)
                Toggle("Kern", isOn: $model.kerning).toggleStyle(.checkbox).accessibilityIdentifier("previewStrip.kern")
                Spacer()
            }
            .padding(.horizontal, 8)
            PreviewStripCanvasRepresentable(model: model)
        }
        .frame(height: model.height)
    }
}

/// One glyph tab's strip, laid along the bottom of its canvas.
@MainActor
final class PreviewStripHost {
    let model: PreviewStripModel
    let view: NSHostingView<PreviewStripView>
    private static var hosts: [ObjectIdentifier: PreviewStripHost] = [:]

    init(model: PreviewStripModel) {
        self.model = model
        view = NSHostingView(rootView: PreviewStripView(model: model))
    }

    static func host(of window: DocumentWindowController) -> PreviewStripHost? { hosts[ObjectIdentifier(window)] }

    /// Adds the strip to a glyph tab (nothing for other windows).
    @discardableResult
    static func attach(_ window: DocumentWindowController, preferences: PreferenceStore, open: @escaping @MainActor (OpID) -> Void) -> PreviewStripHost? {
        guard let glyph = window.documentHandle.glyphCanvasNode, hosts[ObjectIdentifier(window)] == nil else { return nil }
        let model = PreviewStripModel(document: window.documentHandle, glyph: glyph, text: preferences[PreferenceCatalog.Typeface.previewText])
        model.open = open
        let host = PreviewStripHost(model: model)
        hosts[ObjectIdentifier(window)] = host
        let strip = host.view
        strip.translatesAutoresizingMaskIntoConstraints = false
        window.window?.contentView?.addSubview(strip)
        let ruler = window.rulerHost
        NSLayoutConstraint.activate([
            strip.bottomAnchor.constraint(equalTo: ruler.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: ruler.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: ruler.trailingAnchor),
        ])
        return host
    }

    static func detach(_ window: DocumentWindowController) {
        hosts[ObjectIdentifier(window)]?.model.stop()
        hosts[ObjectIdentifier(window)]?.view.removeFromSuperview()
        hosts[ObjectIdentifier(window)] = nil
    }

    /// menu:View[Preview Strip].
    static func command(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: "view.previewStrip", title: "Preview Strip", menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewZoom),
                keywords: ["glyph", "preview", "strip"],
                validation: {
                    guard let host = window().flatMap(host(of:)) else { return .disabled(TypefaceFeatures.noGlyphCanvas) }
                    return .checked(!host.model.isHidden)
                },
                action: .perform {
                    guard let host = window().flatMap(host(of:)) else { return }
                    host.model.isHidden.toggle()
                })
    }
}
