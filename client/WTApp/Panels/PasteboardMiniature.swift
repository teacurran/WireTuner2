import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Document panel's pasteboard view (document-panel.adoc, "The pasteboard view"; DOC-004):
/// the whole pasteboard in miniature at three magnifications, a thumbnail per page numbered in
/// page order, the selected pages highlighted and collaborators' pages marked with their colour.
/// A click selects a page, a double-click also scrolls the window to it, dragging a thumbnail
/// moves the page with its objects (one change on release), and kbd:[Space]-drag scrolls the
/// view.  Thumbnails re-render 250 ms after the document last changed.
@MainActor
final class PasteboardMiniatureView: NSView {
    /// How much larger each magnification button shows the pasteboard than the fit-to-width
    /// small one.
    static let magnifications = [1.0, 2.0, 4.0]
    /// The debounce after a change before thumbnails re-render.
    static let thumbnailDelay: Duration = .milliseconds(250)

    weak var window_: DocumentWindowController?
    /// View points scrolled (Space-drag), at the current magnification.
    private(set) var scroll = Point.zero
    /// Thumbnails by page, with the change count they were drawn at.
    private(set) var thumbnails: [OpID: (count: Int, image: CGImage)] = [:]
    private var renderTask: Task<Void, Never>?
    private var observation: DocumentHandle.ObservationToken?
    /// The press in progress: a page being dragged, or the view being scrolled.
    private(set) var press: (page: OpID?, start: Point, scrolling: Bool)?
    private(set) var dragDelta: Vector?
    /// Whether kbd:[Space] is down; replaceable in tests.
    var spaceDown: @MainActor () -> Bool = { CGEventSource.keyState(.combinedSessionState, key: 49) }

    init(window: DocumentWindowController?) {
        window_ = window
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("document.pasteboard.view")
        follow(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PasteboardMiniatureView is built in code")
    }

    isolated deinit {
        renderTask?.cancel()
        if let observation, let document = window_?.documentHandle { document.stopObserving(observation) }
    }

    override var isFlipped: Bool { true }

    /// Shows `window`'s document, following its changes.
    func follow(_ window: DocumentWindowController?) {
        if window === window_, observation != nil { return }
        if let observation, let document = window_?.documentHandle { document.stopObserving(observation) }
        window_ = window
        thumbnails = [:]
        observation = window?.documentHandle.observe { [weak self] _ in self?.contentDidChange() }
        needsDisplay = true
    }

    /// The document changed: the page rectangles now, the thumbnails once it rests.
    func contentDidChange() {
        needsDisplay = true
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.thumbnailDelay)
            guard !Task.isCancelled else { return }
            self?.renderThumbnails()
        }
    }

    // MARK: Geometry

    /// View points per pasteboard point: the pasteboard fits the width at the small
    /// magnification.
    var scale: Double {
        let level = window_.map { min(max($0.documentPanelScale, 0), Self.magnifications.count - 1) } ?? 0
        return Double(max(bounds.width, 1)) / Pasteboard.side * Self.magnifications[level]
    }

    /// Pasteboard → view.
    var toView: WTGeometry.AffineTransform {
        WTGeometry.AffineTransform.scale(scale).concatenating(.translation(x: -scroll.x, y: -scroll.y))
    }

    func viewRect(_ rect: Rect) -> CGRect { rect.applying(toView).cgRect }

    /// The page whose miniature is under `viewPoint`, the lowest-numbered first.
    func page(at viewPoint: Point) -> Page? {
        guard let pages = window_?.documentHandle.pageList else { return nil }
        let point = Point(x: (viewPoint.x + scroll.x) / scale, y: (viewPoint.y + scroll.y) / scale)
        // Miniature pages are small: take the page within a few view points.
        let reach = 2 / scale
        return pages.pages.first { $0.rect.insetBy(dx: -reach, dy: -reach).contains(point) }
    }

    /// Scrolls by `delta` view points, kept inside the pasteboard.
    func scroll(by delta: Vector) {
        let limit = max(Pasteboard.side * scale - Double(bounds.width), 0)
        let limitY = max(Pasteboard.side * scale - Double(bounds.height), 0)
        scroll = Point(x: min(max(scroll.x - delta.dx, 0), limit), y: min(max(scroll.y - delta.dy, 0), limitY))
        needsDisplay = true
    }

    /// Scrolls so `page` is in the middle of the view.
    func reveal(_ page: Page) {
        let center = page.rect.center
        scroll = Point(x: 0, y: 0)
        scroll(by: Vector(dx: -(center.x * scale - Double(bounds.width) / 2), dy: -(center.y * scale - Double(bounds.height) / 2)))
    }

    // MARK: Thumbnails

    /// Renders every page's thumbnail from the document's drawing (at least the renderer's
    /// smallest zoom; drawn scaled into the miniature).
    func renderThumbnails() {
        guard let document = window_?.documentHandle else { return }
        let count = document.changeCount
        let list = document.displayList
        for page in document.pageList.pages where thumbnails[page.id]?.count != count {
            if let image = Self.thumbnail(of: page, in: list) { thumbnails[page.id] = (count, image) }
        }
        needsDisplay = true
    }

    /// A page's drawing, its longer side about 128 pixels.
    static func thumbnail(of page: Page, in list: DisplayList) -> CGImage? {
        let zoom = Viewport.clampedZoom(128 / max(page.rect.width, page.rect.height))
        let viewport = Viewport(scrollOrigin: page.rect.origin, zoom: zoom, size: Size(width: page.rect.width * zoom, height: page.rect.height * zoom))
        return CoreGraphicsRenderer(background: .white).renderBitmap(list, viewport: viewport)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CanvasView.pasteboardColor)
        ctx.fill(bounds)
        guard let window = window_ else { return }
        let document = window.documentHandle
        let selected = Set(document.selectedPages.map(\.id))
        let participants = window.presence.participants
        let font = NSFont.systemFont(ofSize: 9)
        for page in document.pageList.pages {
            var rect = viewRect(page.rect)
            if press?.page == page.id, let dragDelta { rect = rect.offsetBy(dx: dragDelta.dx * scale, dy: dragDelta.dy * scale) }
            ctx.setFillColor(.white)
            ctx.fill(rect)
            if let image = thumbnails[page.id]?.image {
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
            ctx.setStrokeColor(selected.contains(page.id) ? NSColor.controlAccentColor.cgColor : NSColor.gray.cgColor)
            ctx.setLineWidth(selected.contains(page.id) ? 2 : 1)
            ctx.stroke(rect)
            ("\(page.number)" as NSString).draw(at: CGPoint(x: rect.minX + 2, y: rect.maxY + 1), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            for (index, participant) in participants.filter({ CanvasFurniture.page(of: $0, in: document.pageList)?.id == page.id }).enumerated() {
                ctx.setFillColor(PresencePalette.color(at: participant.colorIndex).cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 7 - Double(index) * 7, y: rect.minY + 1, width: 5, height: 5))
            }
        }
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        pressed(at: Point(convert(event.locationInWindow, from: nil)), clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged(to: Point(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        released(at: Point(convert(event.locationInWindow, from: nil)))
    }

    /// A press: kbd:[Space] scrolls; on a page it selects it (a double-click also shows it in the
    /// window) and starts a drag.
    func pressed(at point: Point, clickCount: Int) {
        guard let window = window_ else { return }
        if spaceDown() {
            press = (nil, point, true)
            return
        }
        let page = page(at: point)
        press = (page?.id, point, false)
        guard let page else { return }
        window.documentHandle.selectPage(id: page.id)
        if clickCount >= 2 { window.showCurrentPage() }
        needsDisplay = true
    }

    func dragged(to point: Point) {
        guard let press else { return }
        if press.scrolling {
            scroll(by: Vector(dx: point.x - press.start.x, dy: point.y - press.start.y))
            self.press = (nil, point, true)
            return
        }
        guard press.page != nil else { return }
        dragDelta = Vector(dx: (point.x - press.start.x) / scale, dy: (point.y - press.start.y) / scale)
        needsDisplay = true
    }

    /// The release of a thumbnail drag moves the page with its objects ("Move page").
    func released(at point: Point) {
        defer {
            press = nil
            dragDelta = nil
            needsDisplay = true
        }
        guard let press, !press.scrolling, let id = press.page, let window = window_ else { return }
        let delta = Vector(dx: (point.x - press.start.x) / scale, dy: (point.y - press.start.y) / scale)
        guard abs(delta.dx) * scale >= 2 || abs(delta.dy) * scale >= 2, let page = window.documentHandle.pageList[id] else { return }
        let moved = Pasteboard.clamp(page.rect.offset(by: delta))
        window.objectEditing.perform(MovePage(id, by: Vector(dx: moved.minX - page.rect.minX, dy: moved.minY - page.rect.minY)))
    }
}

/// The pasteboard view in the Document panel's SwiftUI body.
struct PasteboardMiniature: NSViewRepresentable {
    let window: DocumentWindowController
    /// The panel's revision: a change redraws the view.
    let revision: Int

    func makeNSView(context: Context) -> PasteboardMiniatureView {
        let view = PasteboardMiniatureView(window: window)
        view.renderThumbnails()
        return view
    }

    func updateNSView(_ view: PasteboardMiniatureView, context: Context) {
        view.follow(window)
        view.needsDisplay = true
    }
}
