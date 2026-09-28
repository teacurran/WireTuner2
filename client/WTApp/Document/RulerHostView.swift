import AppKit
import WTRender

/// The canvas area: the canvas, with ruler strips along the top and left edges of its safe area
/// and the zero-point corner between them, and the two scroll bars along the safe area's right
/// and bottom edges.  The canvas fills the whole host -- it runs under the docked panels, the
/// status bar and these strips (D-077) -- and the parts the window lays over it (`obscured`)
/// are left out of its safe area.  The scroll bars are plain `NSScroller`s driven by
/// `CanvasScrollerModel` (there is no `NSScrollView`).
@MainActor
final class RulerHostView: NSView {
    static let rulerThickness: CGFloat = 16

    let canvas: CanvasView
    let horizontalRuler = RulerStripView(orientation: .horizontal)
    let verticalRuler = RulerStripView(orientation: .vertical)
    let corner = RulerCornerView(frame: .zero)
    let horizontalScroller: NSScroller
    let verticalScroller: NSScroller
    /// The square where the two scroll bars meet (the canvas would show through it).
    let scrollerCorner = NSView()

    /// How far the window's docks and status bar reach over this host from its left, right and
    /// bottom edges (top is unused): the rulers, scroll bars and the canvas's safe area sit
    /// inside what is left.
    var obscured = NSEdgeInsetsZero {
        didSet {
            guard !NSEdgeInsetsEqual(obscured, oldValue) else { return }
            needsLayout = true
        }
    }

    /// View menu > Page Rulers > Show (`ViewState.page_rulers`).
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
        for scroller in [horizontalScroller, verticalScroller] {
            scroller.scrollerStyle = .legacy
            scroller.isEnabled = true
            scroller.target = self
            scroller.action = #selector(scrollerMoved(_:))
        }
        horizontalScroller.setAccessibilityIdentifier("canvas.scroller.horizontal")
        verticalScroller.setAccessibilityIdentifier("canvas.scroller.vertical")
        scrollerCorner.wantsLayer = true
        scrollerCorner.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scrollerCorner.setAccessibilityElement(false)
        for view in [canvas, horizontalRuler, verticalRuler, corner, horizontalScroller, verticalScroller, scrollerCorner] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerHostView is built in code")
    }

    override var isFlipped: Bool { true }

    static var scrollerWidth: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    /// The canvas's safe area for a host of `size` (top-left origin): inside the rulers and
    /// scroll bars, and clear of the `obscured` edges.  The canvas itself fills the host.
    static func canvasFrame(in size: CGSize, rulersVisible: Bool, obscured: NSEdgeInsets = NSEdgeInsetsZero) -> CGRect {
        let ruler = rulersVisible ? rulerThickness : 0
        let scroller = scrollerWidth
        let x = obscured.left + ruler
        let y = ruler
        return CGRect(x: x, y: y, width: max(size.width - obscured.right - scroller - x, 0), height: max(size.height - obscured.bottom - scroller - y, 0))
    }

    /// The canvas's covered edges (view points) for a host of `size`: what `canvasFrame` leaves out.
    static func canvasInsets(in size: CGSize, rulersVisible: Bool, obscured: NSEdgeInsets) -> CanvasInsets {
        let safe = canvasFrame(in: size, rulersVisible: rulersVisible, obscured: obscured)
        return CanvasInsets(top: Double(safe.minY), left: Double(safe.minX), bottom: Double(size.height - safe.maxY), right: Double(size.width - safe.maxX))
    }

    override func layout() {
        super.layout()
        let ruler = rulersVisible ? Self.rulerThickness : 0
        let safe = Self.canvasFrame(in: bounds.size, rulersVisible: rulersVisible, obscured: obscured)
        let scroller = Self.scrollerWidth
        corner.frame = CGRect(x: safe.minX - ruler, y: 0, width: ruler, height: ruler)
        horizontalRuler.frame = CGRect(x: safe.minX, y: 0, width: safe.width, height: ruler)
        verticalRuler.frame = CGRect(x: safe.minX - ruler, y: safe.minY, width: ruler, height: safe.height)
        horizontalScroller.frame = CGRect(x: safe.minX, y: safe.maxY, width: safe.width, height: scroller)
        verticalScroller.frame = CGRect(x: safe.maxX, y: safe.minY, width: scroller, height: safe.height)
        scrollerCorner.frame = CGRect(x: safe.maxX, y: safe.maxY, width: scroller, height: scroller)
        if canvas.frame != bounds { canvas.frame = bounds }
        // The canvas is at the host's origin: a ruler's start is its canvas position.
        horizontalRuler.canvasOrigin = Double(safe.minX)
        verticalRuler.canvasOrigin = Double(safe.minY)
        canvas.safeInsets = Self.canvasInsets(in: bounds.size, rulersVisible: rulersVisible, obscured: obscured)
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
