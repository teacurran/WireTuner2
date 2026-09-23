import AppKit
import WTRender

/// An empty ruler strip.  DOC-014 draws ticks and labels in it from the viewport and the
/// document's unit; until then it is a plain band of the right size.
@MainActor
final class RulerStripView: NSView {
    enum Orientation: String {
        case horizontal, vertical
    }

    let orientation: Orientation
    /// Set by the host on every viewport change, for DOC-014's drawing.
    var viewport: Viewport?

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.ruler)
        setAccessibilityIdentifier("ruler.\(orientation.rawValue)")
        setAccessibilityLabel(orientation == .horizontal ? "Horizontal ruler" : "Vertical ruler")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerStripView is built in code")
    }
}

/// The canvas area: ruler strips along the top and left edges with the zero-point corner
/// between them, the canvas, and the two scroll bars along the right and bottom edges.  Laid
/// out by hand so the canvas gets every remaining point.  The scroll bars are plain
/// `NSScroller`s driven by `CanvasScrollerModel` (there is no `NSScrollView`).
@MainActor
final class RulerHostView: NSView {
    static let rulerThickness: CGFloat = 16

    let canvas: CanvasView
    let horizontalRuler = RulerStripView(orientation: .horizontal)
    let verticalRuler = RulerStripView(orientation: .vertical)
    let corner = NSView()
    let horizontalScroller: NSScroller
    let verticalScroller: NSScroller

    /// View menu > Page Rulers > Show (DOC-014 binds it to `ViewState.page_rulers`).
    var rulersVisible = true {
        didSet {
            horizontalRuler.isHidden = !rulersVisible
            verticalRuler.isHidden = !rulersVisible
            corner.isHidden = !rulersVisible
            needsLayout = true
        }
    }

    var onHorizontalScroll: (@MainActor (Double) -> Void)?
    var onVerticalScroll: (@MainActor (Double) -> Void)?

    init(canvas: CanvasView) {
        self.canvas = canvas
        horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 15))
        verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        corner.wantsLayer = true
        corner.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        corner.setAccessibilityIdentifier("ruler.corner")
        for scroller in [horizontalScroller, verticalScroller] {
            scroller.scrollerStyle = .legacy
            scroller.isEnabled = true
            scroller.target = self
            scroller.action = #selector(scrollerMoved(_:))
        }
        horizontalScroller.setAccessibilityIdentifier("canvas.scroller.horizontal")
        verticalScroller.setAccessibilityIdentifier("canvas.scroller.vertical")
        for view in [canvas, horizontalRuler, verticalRuler, corner, horizontalScroller, verticalScroller] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerHostView is built in code")
    }

    override var isFlipped: Bool { true }

    static var scrollerWidth: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    /// The canvas frame for a host of `size` (top-left origin).
    static func canvasFrame(in size: CGSize, rulersVisible: Bool) -> CGRect {
        let ruler = rulersVisible ? rulerThickness : 0
        let scroller = scrollerWidth
        return CGRect(x: ruler, y: ruler, width: max(size.width - ruler - scroller, 0), height: max(size.height - ruler - scroller, 0))
    }

    override func layout() {
        super.layout()
        let ruler = rulersVisible ? Self.rulerThickness : 0
        let canvasFrame = Self.canvasFrame(in: bounds.size, rulersVisible: rulersVisible)
        let scroller = Self.scrollerWidth
        corner.frame = CGRect(x: 0, y: 0, width: ruler, height: ruler)
        horizontalRuler.frame = CGRect(x: canvasFrame.minX, y: 0, width: canvasFrame.width, height: ruler)
        verticalRuler.frame = CGRect(x: 0, y: canvasFrame.minY, width: ruler, height: canvasFrame.height)
        horizontalScroller.frame = CGRect(x: canvasFrame.minX, y: canvasFrame.maxY, width: canvasFrame.width, height: scroller)
        verticalScroller.frame = CGRect(x: canvasFrame.maxX, y: canvasFrame.minY, width: scroller, height: canvasFrame.height)
        if canvas.frame != canvasFrame { canvas.frame = canvasFrame }
    }

    /// Shows the scroll bars' state for `viewport`.
    func update(horizontal: ScrollAxisState, vertical: ScrollAxisState, viewport: Viewport) {
        apply(horizontal, to: horizontalScroller)
        apply(vertical, to: verticalScroller)
        horizontalRuler.viewport = viewport
        verticalRuler.viewport = viewport
    }

    private func apply(_ state: ScrollAxisState, to scroller: NSScroller) {
        scroller.knobProportion = CGFloat(state.knobProportion)
        scroller.doubleValue = state.value
        scroller.isEnabled = state.isScrollable
    }

    /// A click in the track moves by one page of the current extent.
    static func value(after part: NSScroller.Part, current: Double, knobProportion: Double) -> Double {
        let page = knobProportion / max(1 - knobProportion, 1e-9)
        switch part {
        case .decrementPage: return max(current - page, 0)
        case .incrementPage: return min(current + page, 1)
        default: return current
        }
    }

    @objc func scrollerMoved(_ sender: NSScroller) {
        let value = Self.value(after: sender.hitPart, current: sender.doubleValue, knobProportion: Double(sender.knobProportion))
        if sender === horizontalScroller {
            onHorizontalScroll?(value)
        } else {
            onVerticalScroll?(value)
        }
    }
}
