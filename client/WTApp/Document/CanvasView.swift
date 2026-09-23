import AppKit
import WTGeometry
import WTRender

/// The canvas: a layer-hosting view whose root layer holds the REND-001 tiled canvas and the
/// tool overlay above it (the Metal `WTCanvasView` of REND-006 takes the tiles' place).  It
/// owns the `Viewport`, pans on scroll, zooms on pinch and Option-scroll, and hands pointer
/// and key events to the `ToolManager`.  Thin by design: coordinate translation is
/// `CanvasEventTranslator`, zoom and scroll arithmetic `CanvasNavigation`.
///
/// Not flipped: the tile layers are laid out y-up (`TileLayout.layerFrame`), so neither this
/// view nor its layers may be geometry-flipped.  The orientation snapshot test checks that
/// pasteboard (0, 0) lands at the top-left.
@MainActor
final class CanvasView: NSView, CanvasHost {
    static let accessibilityIdentifier = "canvas"
    /// The pasteboard's colour behind the tiles (BASIC-003 draws page shadows on it).
    static let pasteboardColor = CGColor(gray: 0.86, alpha: 1)

    let document: DocumentHandle
    let tiles: TiledCanvasLayer
    let overlay = CanvasOverlayLayer()
    var navigation = CanvasNavigation()
    private(set) var viewport: Viewport
    var toolManager: ToolManager? {
        didSet { toolCursorDidChange() }
    }

    /// Called after every viewport change (the window updates scroll bars, status bar and
    /// saved state).
    var onViewportChange: (@MainActor (Viewport) -> Void)?
    var onStatusMessage: (@MainActor (String) -> Void)?
    private var documentObservation: DocumentHandle.ObservationToken?

    /// The window's selection, drawn under the tool overlay (APP-006).
    var selectionController: SelectionController? {
        didSet { selectionDidChange() }
    }
    /// The other participants whose selections are outlined.
    var presence: (any PresenceProviding)?
    /// *Show others' selections*.
    var showsRemoteSelections: @MainActor () -> Bool = { true }
    /// Extra state for UI tests, appended to the accessibility value (the socket audit's
    /// counts under `-WTSocketAudit`); nil adds nothing.
    var diagnostics: @MainActor () -> String? = { nil }

    init(document: DocumentHandle, cache: TileCache = TileCache(renderer: CoreGraphicsRenderer()), frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
        self.document = document
        tiles = TiledCanvasLayer(cache: cache, backingScale: 2)
        viewport = Viewport(size: Size(frame.size))
        super.init(frame: frame)

        let root = CALayer()
        root.backgroundColor = Self.pasteboardColor
        root.masksToBounds = true
        root.actions = ["sublayers": NSNull()]
        layer = root
        wantsLayer = true
        for sublayer in [tiles.layer, overlay] as [CALayer] {
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            root.addSublayer(sublayer)
        }
        overlay.drawer = { [weak self] ctx in self?.drawOverlay(in: ctx) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityIdentifier)
        setAccessibilityLabel("Canvas")

        documentObservation = document.observe { [weak self] dirty in self?.documentDidChange(dirty: dirty) }
        viewport = navigation.clamped(viewport)
        updateAccessibilityValue()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasView is built in code")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Viewport

    func setViewport(_ viewport: Viewport) {
        var next = navigation.clamped(viewport)
        next.size = Size(bounds.size)
        next = navigation.clamped(next)
        guard next != self.viewport else { return }
        self.viewport = next
        render()
        onViewportChange?(next)
    }

    /// Lays out and requests the visible tiles for the current viewport and display list.
    func render() {
        if let scale = window?.backingScaleFactor { tiles.backingScale = Double(scale) }
        tiles.update(displayList: document.displayList, viewport: viewport)
        overlay.bounds = CGRect(origin: .zero, size: bounds.size)
        overlay.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        var resized = viewport
        resized.size = Size(newSize)
        viewport = navigation.clamped(resized)
        render()
        onViewportChange?(viewport)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            overlay.contentsScale = scale
        }
        render()
    }

    private func documentDidChange(dirty: Rect?) {
        updateAccessibilityValue()
        render()
    }

    /// The selection or a collaborator's selection changed.
    func selectionDidChange() {
        updateAccessibilityValue()
        overlay.setNeedsDisplay()
    }

    // MARK: Accessibility

    /// The canvas's accessibility value, which UI tests read to observe the document without
    /// pixels: `"changes=<n> selected=<n>"`, then any diagnostics (TEST-002; testing.adoc, "UI").
    static func accessibilityStatus(changes: Int, selected: Int, diagnostics: String? = nil) -> String {
        ["changes=\(changes) selected=\(selected)", diagnostics].compactMap { $0 }.joined(separator: " ")
    }

    func updateAccessibilityValue() {
        setAccessibilityValue(Self.accessibilityStatus(
            changes: document.changeCount, selected: selectionController?.model.count ?? 0, diagnostics: diagnostics()
        ))
    }

    // MARK: CanvasHost

    func setNeedsOverlayDisplay() {
        overlay.setNeedsDisplay()
    }

    func toolCursorDidChange() {
        window?.invalidateCursorRects(for: self)
        if let cursor = toolManager?.cursor, window?.isKeyWindow == true { cursor.set() }
    }

    func showStatusMessage(_ message: String) {
        onStatusMessage?(message)
    }

    func drawOverlay(in ctx: CGContext) {
        if let selectionController {
            SelectionOverlay(document: document, viewport: viewport).draw(
                in: ctx, selection: selectionController.selection, participants: presence?.participants ?? [],
                showsRemote: showsRemoteSelections(), accent: NSColor.controlAccentColor.cgColor
            )
        }
        toolManager?.drawOverlay(in: ctx, viewport: viewport)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: toolManager?.cursor ?? .arrow)
    }

    // MARK: Events

    func canvasEvent(_ event: NSEvent) -> CanvasEvent {
        CanvasEventTranslator.event(
            appKitPoint: convert(event.locationInWindow, from: nil), viewHeight: Double(bounds.height), viewport: viewport,
            modifierFlags: event.modifierFlags, pressure: event.pressure, clickCount: event.clickCount,
            timestamp: event.timestamp, isTablet: event.subtype == .tabletPoint
        )
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        toolManager?.mouseDown(canvasEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        toolManager?.mouseDragged(canvasEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        toolManager?.mouseUp(canvasEvent(event))
    }

    override func flagsChanged(with event: NSEvent) {
        toolManager?.flagsChanged(KeyEquivalentResolver.modifiers(event.modifierFlags), timestamp: event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        if toolManager?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if toolManager?.keyUp(event) != true { super.keyUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        scroll(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, modifierFlags: event.modifierFlags,
            at: convert(event.locationInWindow, from: nil)
        )
    }

    /// Scroll-wheel handling: pan, or with Option zoom about the pointer.
    func scroll(deltaX: Double, deltaY: Double, precise: Bool, modifierFlags: NSEvent.ModifierFlags, at appKitPoint: CGPoint) {
        if modifierFlags.contains(.option) {
            let factor = CanvasEventTranslator.scrollZoomFactor(deltaY: deltaY, hasPreciseDeltas: precise)
            let pivot = CanvasEventTranslator.viewPoint(fromAppKit: appKitPoint, viewHeight: Double(bounds.height))
            setViewport(navigation.magnify(viewport, by: factor, about: pivot))
        } else {
            let delta = CanvasEventTranslator.scrollDelta(deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: precise, shift: modifierFlags.contains(.shift))
            setViewport(navigation.scroll(viewport, by: delta))
        }
    }

    override func magnify(with event: NSEvent) {
        magnify(by: Double(event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    /// Pinch: continuous zoom about the pointer.
    func magnify(by magnification: Double, at appKitPoint: CGPoint) {
        let pivot = CanvasEventTranslator.viewPoint(fromAppKit: appKitPoint, viewHeight: Double(bounds.height))
        setViewport(navigation.magnify(viewport, by: CanvasEventTranslator.pinchFactor(magnification: magnification), about: pivot))
    }

    // BASIC-034 hook: `rotate(with:)` accumulates the gesture's rotation about its centroid
    // through `Viewport.rotated(byDegrees:aboutViewPoint:)` while *Rotate canvas with
    // trackpad* is on.  The scroll model, navigation and translator already work rotated.
}
