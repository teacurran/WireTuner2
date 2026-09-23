import AppKit
import Metal
import WTGeometry
import WTModel
import WTRender

/// The canvas: a layer-hosting view whose root layer holds the REND-006 `MetalTileCanvas` (a
/// `CAMetalLayer` driven by a display link, or its Core Graphics tile layer when the fallback
/// has engaged) and the tool overlay above it.  It owns the `Viewport`, pans on scroll, zooms on
/// pinch and Option-scroll, turns on two-finger rotate, and hands pointer and key events to the
/// `ToolManager`.  Thin by design: coordinate translation is `CanvasEventTranslator`, zoom and
/// scroll arithmetic `CanvasNavigation`, gesture phases `CanvasGestureTracker`.
///
/// Not flipped: the tile layers are laid out y-up (`TileLayout.layerFrame`), so neither this
/// view nor its layers may be geometry-flipped.  The orientation snapshot test checks that
/// pasteboard (0, 0) lands at the top-left.
@MainActor
final class CanvasView: NSView, CanvasHost {
    static let accessibilityIdentifier = "canvas"
    /// The pasteboard's colour behind the tiles (BASIC-003 draws page shadows on it).
    static let pasteboardColor = CGColor(gray: 0.86, alpha: 1)
    static let pasteboardTileColor = Color(white: 0.86)

    /// A tile canvas on the system GPU: Metal on an Apple-family GPU, else the Core Graphics
    /// fallback (the canvas decides and logs why).
    static func makeTiles() -> MetalTileCanvas {
        MetalTileCanvas(pasteboardColor: pasteboardTileColor)
    }

    /// A tile canvas that draws with Core Graphics from the start (tests, snapshots).
    static func makeFallbackTiles() -> MetalTileCanvas {
        MetalTileCanvas(device: nil, pasteboardColor: pasteboardTileColor)
    }

    let document: DocumentHandle
    let tiles: MetalTileCanvas
    let overlay = CanvasOverlayLayer()
    /// Collaborators' cursors, selections and pulses (presence.adoc, "Client"): its own layer
    /// between the tiles and the tool overlay, so drawing it never repaints a document tile.
    let presenceLayer = CanvasOverlayLayer()
    /// Draws `presenceLayer` (the window's collaboration); nil draws nothing.
    var presenceDrawer: (@MainActor (CGContext) -> Void)?
    /// The pointer moved over the canvas (pasteboard points) or left it (nil): outgoing presence.
    var onPointer: (@MainActor (Point?) -> Void)?
    /// The user scrolled, zoomed or rotated the view: following ends.
    var onUserNavigation: (@MainActor () -> Void)?
    /// A mouse button went down (true) or up (false) on the canvas.
    var onPress: (@MainActor (Bool) -> Void)?
    var navigation = CanvasNavigation()
    private(set) var viewport: Viewport
    var toolManager: ToolManager? {
        didSet { toolCursorDidChange() }
    }

    /// Called after every viewport change (the window updates scroll bars, status bar and
    /// saved state).
    var onViewportChange: (@MainActor (Viewport) -> Void)?
    var onStatusMessage: (@MainActor (String) -> Void)?
    /// A secondary click: the window builds the context menu for the point (view points).
    var onContextMenu: (@MainActor (NSEvent, Point) -> NSMenu?)?
    private var documentObservation: DocumentHandle.ObservationToken?

    /// The window's selection, drawn under the tool overlay (APP-006).
    var selectionController: SelectionController? {
        didSet { selectionDidChange() }
    }
    /// The other participants whose selections are outlined.
    var presence: (any PresenceProviding)?
    /// *Show others' selections*.
    var showsRemoteSelections: @MainActor () -> Bool = { true }
    /// *Smaller handles* and *Show solid points* (the point glyphs).
    var glyphStyle: @MainActor () -> SelectionOverlay.GlyphStyle = { SelectionOverlay.GlyphStyle() }
    /// *Rotate canvas with trackpad*: gates the two-finger rotate gesture only.
    var rotatesWithTrackpad: @MainActor () -> Bool = { true }
    /// Extra state for UI tests, appended to the accessibility value (the socket audit's
    /// counts under `-WTSocketAudit`); nil adds nothing.
    var diagnostics: @MainActor () -> String? = { nil }

    /// Pinch, rotate, scroll and animations in progress (the renderer holds its tiles).
    private(set) var gestures = CanvasGestureTracker()
    /// The angle when the rotate gesture began and the rotation accumulated since.
    private(set) var rotationGesture: (start: Double, accumulated: Double)?
    private(set) var smartZoom = SmartZoomState()
    /// The running menu rotation or Reset, awaited by tests.
    private(set) var animation: Task<Void, Never>?
    /// How long a menu rotation animates; zero applies it at once (tests).
    var rotationAnimationDuration = CanvasRotation.animationDuration
    /// Animation preview (WEB-016): the one frame shown instead of the whole document, nil for
    /// everything.  Nothing is written to the document; the tiles draw the canvas list restricted
    /// to the frame's layers.
    var previewFrame: AnimationFrame? {
        didSet { if previewFrame != oldValue { previewFrameDidChange(from: oldValue) } }
    }
    /// Playback of the document's frames while previewing.
    private(set) var playback: CanvasPlayback?

    init(document: DocumentHandle, tiles: MetalTileCanvas = CanvasView.makeFallbackTiles(), frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
        self.document = document
        self.tiles = tiles
        viewport = Viewport(size: Size(frame.size))
        super.init(frame: frame)

        let root = CALayer()
        root.backgroundColor = Self.pasteboardColor
        root.masksToBounds = true
        root.actions = ["sublayers": NSNull()]
        layer = root
        wantsLayer = true
        for sublayer in [tiles.layer, presenceLayer, overlay] as [CALayer] {
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            root.addSublayer(sublayer)
        }
        overlay.drawer = { [weak self] ctx in self?.drawOverlay(in: ctx) }
        presenceLayer.drawer = { [weak self] ctx in self?.presenceDrawer?(ctx) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityIdentifier)
        setAccessibilityLabel("Canvas")

        document.invalidation.add(tiles)
        documentObservation = document.observe { [weak self] change in self?.documentDidChange(change) }
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

    /// Which renderer puts the canvas on screen.
    var backend: MetalTileCanvas.Backend { tiles.backend }

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
        tiles.update(displayList: shownDisplayList, viewport: viewport)
        overlay.bounds = CGRect(origin: .zero, size: bounds.size)
        overlay.setNeedsDisplay()
        presenceLayer.bounds = overlay.bounds
        presenceLayer.setNeedsDisplay()
    }

    /// Draws the canvas in `mode` (REND-005); the display list is not rebuilt.
    func setViewMode(_ mode: ViewMode) {
        tiles.setViewMode(mode)
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
            presenceLayer.contentsScale = scale
        }
        render()
    }

    /// The display link runs while the canvas is in a window: frames are drawn at the display's
    /// refresh only when something changed, and never by `nextDrawable()` from here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tiles.stopDisplayLink()
        } else {
            tiles.startDisplayLink()
            render()
        }
    }

    /// What one frame of the current view costs on the GPU path, drawn offscreen at the view's
    /// pixel size (the frame-budget harness; nil on the Core Graphics fallback).
    func measureFrame() -> FrameTiming? {
        guard backend == .metal, let device = tiles.metalLayer.device else { return nil }
        let scale = tiles.backingScale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(Int(viewport.size.width * scale), 1), height: max(Int(viewport.size.height * scale), 1), mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        return tiles.renderFrame(into: texture)
    }

    /// The document changed: the tiles were already told through the document's invalidation
    /// batcher; the overlay (selection, glyphs) and the accessibility value follow.
    private func documentDidChange(_ change: ContentChange) {
        if let previewFrame {
            // Out of the invalidation batcher while previewing: the next frame shows the change.
            tiles.update(displayList: FrameComposer.displayList(change.after, for: previewFrame), viewport: viewport, changes: change.summary)
        }
        updateAccessibilityValue()
        overlay.setNeedsDisplay()
        presenceLayer.setNeedsDisplay()
    }

    /// The selection or a collaborator's selection changed.
    func selectionDidChange() {
        updateAccessibilityValue()
        overlay.setNeedsDisplay()
        presenceLayer.setNeedsDisplay()
    }

    /// Presence changed (a cursor moved, a pulse started or ended): only the presence layer redraws.
    func setNeedsPresenceDisplay() {
        presenceLayer.setNeedsDisplay()
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

    /// The Zoom tool's Shift-drag; the window shows the New View sheet.
    var onNamedViewRequest: (@MainActor (Viewport) -> Void)?

    func requestNamedView(_ target: Viewport) {
        onNamedViewRequest?(target)
    }

    // MARK: HUD

    /// How long the "coming soon" HUD stays.
    static let hudDuration: Duration = .milliseconds(1500)

    /// A rounded label over the canvas, bottom centre (a text layer: this view hosts layers,
    /// not subviews).
    let hud: CATextLayer = {
        let layer = CATextLayer()
        layer.fontSize = 13
        layer.alignmentMode = .center
        layer.foregroundColor = CGColor(gray: 1, alpha: 1)
        layer.backgroundColor = CGColor(gray: 0.1, alpha: 0.8)
        layer.cornerRadius = 8
        layer.isHidden = true
        layer.actions = ["contents": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }()
    private(set) var hudMessage: String?
    private var hudHide: Task<Void, Never>?

    /// Shows `message` over the canvas for `hudDuration`, and in the status bar.
    func showHUD(_ message: String) {
        showStatusMessage(message)
        hudMessage = message
        if hud.superlayer == nil { layer?.addSublayer(hud) }
        hud.string = message
        hud.contentsScale = window?.backingScaleFactor ?? 2
        let width = min(max(CGFloat(message.count) * 7.5 + 24, 120), max(bounds.width - 20, 120))
        hud.frame = CGRect(x: (bounds.width - width) / 2, y: 24, width: width, height: 26)
        hud.isHidden = false
        hudHide?.cancel()
        hudHide = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.hudDuration)
            } catch {
                return
            }
            self?.hideHUD()
        }
    }

    func hideHUD() {
        hud.isHidden = true
        hudMessage = nil
    }

    func drawOverlay(in ctx: CGContext) {
        if let selectionController {
            SelectionOverlay(document: document, viewport: viewport, glyphs: glyphStyle()).draw(
                in: ctx, selection: selectionController.selection, participants: presence?.participants ?? [],
                showsRemote: presenceDrawer == nil && showsRemoteSelections(), accent: NSColor.controlAccentColor.cgColor
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

    /// The view point (y down) of an AppKit point in this view.
    func viewPoint(fromAppKit point: CGPoint) -> Point {
        CanvasEventTranslator.viewPoint(fromAppKit: point, viewHeight: Double(bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if previewFrame != nil {
            // Clicking the canvas ends preview mode (animation.adoc, "Client").
            endPreview()
        }
        if event.modifierFlags.contains(.control), toolManager?.activeToolID != .zoom, let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        stopAutoscroll()
        toolManager?.mouseDown(canvasEvent(event))
        onPress?(true)
    }

    /// The Info toolbar follows the pointer (BASIC-011).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let translated = canvasEvent(event)
        toolManager?.pointerMoved(translated)
        onPointer?(translated.pasteboardPoint)
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let translated = canvasEvent(event)
        toolManager?.mouseDragged(translated)
        updateAutoscroll(translated)
        onPointer?(translated.pasteboardPoint)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        toolManager?.mouseUp(canvasEvent(event))
        onPress?(false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu(for: event)
    }

    /// The context menu for the point of `event`, from the window (BASIC-018).
    func contextMenu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event, viewPoint(fromAppKit: convert(event.locationInWindow, from: nil)))
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
        gesture(.scroll, phase: event.phase, momentumPhase: event.momentumPhase)
        scroll(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas, modifierFlags: event.modifierFlags,
            at: convert(event.locationInWindow, from: nil)
        )
    }

    /// Scroll-wheel handling: pan, or with Option zoom about the pointer.
    func scroll(deltaX: Double, deltaY: Double, precise: Bool, modifierFlags: NSEvent.ModifierFlags, at appKitPoint: CGPoint) {
        smartZoom.reset()
        onUserNavigation?()
        if modifierFlags.contains(.option) {
            let factor = CanvasEventTranslator.scrollZoomFactor(deltaY: deltaY, hasPreciseDeltas: precise)
            setViewport(navigation.magnify(viewport, by: factor, about: viewPoint(fromAppKit: appKitPoint)))
        } else {
            let delta = CanvasEventTranslator.scrollDelta(deltaX: deltaX, deltaY: deltaY, hasPreciseDeltas: precise, shift: modifierFlags.contains(.shift))
            setViewport(navigation.scroll(viewport, by: delta))
        }
    }

    override func magnify(with event: NSEvent) {
        gesture(.magnify, phase: event.phase)
        magnify(by: Double(event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    /// Pinch: continuous zoom about the pointer.
    func magnify(by magnification: Double, at appKitPoint: CGPoint) {
        smartZoom.reset()
        onUserNavigation?()
        setViewport(navigation.magnify(viewport, by: CanvasEventTranslator.pinchFactor(magnification: magnification), about: viewPoint(fromAppKit: appKitPoint)))
    }

    /// Folds an event's phases into the gesture state and tells the renderer when a span of
    /// continuous input begins or settles.
    func gesture(_ source: CanvasGestureTracker.Source, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase = []) {
        apply(gestures.update(source, phase: phase, momentumPhase: momentumPhase))
    }

    private func apply(_ edge: CanvasGestureTracker.Edge?) {
        switch edge {
        case .began?: tiles.beginGesture()
        case .ended?: tiles.endGesture()
        case nil: break
        }
    }

    // MARK: Rotation (BASIC-034)

    override func rotate(with event: NSEvent) {
        guard rotatesWithTrackpad() else { return }
        gesture(.rotate, phase: event.phase)
        rotate(
            byGestureDegrees: Double(event.rotation), phase: event.phase, snapping: event.modifierFlags.contains(.shift),
            at: convert(event.locationInWindow, from: nil)
        )
    }

    /// One step of the two-finger rotate: the gesture's rotation so far (counter-clockwise
    /// positive) turns the canvas about the point between the fingers; Shift snaps the total
    /// to 15°.  `phase` ends the gesture on `.ended`/`.cancelled`.
    func rotate(byGestureDegrees delta: Double, phase: NSEvent.Phase = .changed, snapping: Bool, at appKitPoint: CGPoint) {
        guard rotatesWithTrackpad() else { return }
        smartZoom.reset()
        onUserNavigation?()
        var state = rotationGesture ?? (start: viewport.rotationDegrees, accumulated: 0)
        state.accumulated += delta
        let angle = CanvasRotation.gestureAngle(start: state.start, accumulated: state.accumulated, snapping: snapping)
        setViewport(viewport.rotated(toDegrees: angle, aboutViewPoint: viewPoint(fromAppKit: appKitPoint)))
        rotationGesture = CanvasGestureTracker.isStopping(phase) ? nil : state
    }

    /// Turns the canvas to `degrees` about the view centre, animated over 150 ms (the menu
    /// commands and the compass).  Tiles are drawn through the turn and the settled angle is
    /// rasterised once at the end.
    @discardableResult
    func animateRotation(toDegrees degrees: Double) -> Task<Void, Never>? {
        animation?.cancel()
        smartZoom.reset()
        let start = viewport
        let duration = rotationAnimationDuration
        guard duration > 0 else {
            setViewport(start.rotated(toDegrees: degrees))
            animation = nil
            return nil
        }
        apply(gestures.set(.animation, running: true))
        let task = Task { [weak self] in
            let began = CACurrentMediaTime()
            var fraction = 0.0
            while fraction < 1, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                fraction = min((CACurrentMediaTime() - began) / duration, 1)
                self?.setViewport(CanvasRotation.interpolated(start, toDegrees: degrees, fraction: fraction))
            }
            self?.finishAnimation()
        }
        animation = task
        return task
    }

    private func finishAnimation() {
        apply(gestures.set(.animation, running: false))
    }

    // MARK: Smart zoom and Force click

    override func smartMagnify(with event: NSEvent) {
        smartMagnify(at: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double-tap: fit the object under the pointer, else the page under it; again
    /// to go back.
    func smartMagnify(at appKitPoint: CGPoint) {
        onUserNavigation?()
        let point = viewPoint(fromAppKit: appKitPoint)
        let target = smartZoomTarget(at: point)
        var state = smartZoom
        let next = state.toggle(from: viewport, target: target, navigation: navigation)
        setViewport(next)
        smartZoom = state
    }

    /// The object (REND-003 hit) or page under `viewPoint`.
    func smartZoomTarget(at viewPoint: Point) -> Rect? {
        if let hit = selectionController?.pick(at: viewPoint, viewport: viewport, subselect: false),
            let bounds = document.item(for: hit.id)?.bounds
        {
            return bounds
        }
        let point = viewport.toPasteboard(viewPoint)
        return document.pages.first { $0.contains(point) }
    }

    override func pressureChange(with event: NSEvent) {
        pressureChanged(stage: event.stage, event: canvasEvent(event))
    }

    /// Stage 2 of a Force Touch press is a Force click for the active tool (the Pointer
    /// subselects, as Option-click does).
    func pressureChanged(stage: Int, event: CanvasEvent) {
        guard stage == 2 else { return }
        toolManager?.forceClick(event)
    }

    // MARK: Auto-scroll

    /// While a drag holds the pointer near or past the canvas edge, the view scrolls toward it
    /// and the tool hears the drag again at the pointer's new pasteboard position.
    private(set) var autoscrollEvent: CanvasEvent?
    private var autoscrollTask: Task<Void, Never>?
    /// Whether auto-scroll may run for the current tool (the Hand scrolls by itself).
    var autoscrolls: @MainActor () -> Bool = { true }

    private func updateAutoscroll(_ event: CanvasEvent) {
        guard autoscrolls(), CanvasAutoscroll.delta(viewPoint: event.viewPoint, size: viewport.size) != nil else {
            stopAutoscroll()
            return
        }
        autoscrollEvent = event
        guard autoscrollTask == nil else { return }
        autoscrollTask = Task { [weak self] in
            while !Task.isCancelled, self?.autoscrollStep() == true {
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// One auto-scroll step; returns whether the pointer is still at the edge.
    @discardableResult
    func autoscrollStep() -> Bool {
        guard let event = autoscrollEvent, let delta = CanvasAutoscroll.delta(viewPoint: event.viewPoint, size: viewport.size) else {
            return false
        }
        setViewport(navigation.scroll(viewport, by: delta))
        let moved = CanvasEvent(
            pasteboardPoint: viewport.toPasteboard(event.viewPoint), viewPoint: event.viewPoint, modifiers: event.modifiers,
            pressure: event.pressure, clickCount: event.clickCount, timestamp: event.timestamp
        )
        autoscrollEvent = moved
        toolManager?.mouseDragged(moved)
        return true
    }

    func stopAutoscroll() {
        autoscrollTask?.cancel()
        autoscrollTask = nil
        autoscrollEvent = nil
    }
}

/// How fast the view scrolls when a drag reaches the canvas edge.
enum CanvasAutoscroll {
    /// The band inside the edge, in view points, where scrolling starts.
    static let edge = 8.0
    /// View points per step at the edge; further out scrolls faster, up to `maximumStep`.
    static let step = 8.0
    static let maximumStep = 48.0

    /// The scroll for a pointer at `viewPoint` in a view of `size`; nil well inside it.
    static func delta(viewPoint: Point, size: Size) -> Vector? {
        let dx = axis(viewPoint.x, length: size.width)
        let dy = axis(viewPoint.y, length: size.height)
        return dx == 0 && dy == 0 ? nil : Vector(dx: dx, dy: dy)
    }

    static func axis(_ value: Double, length: Double) -> Double {
        if value < edge { return -min(step + (edge - value), maximumStep) }
        if value > length - edge { return min(step + (value - (length - edge)), maximumStep) }
        return 0
    }
}

// MARK: - Animation preview and playback (WEB-016)

extension CanvasView {
    /// What the tiles show: the document, or only the preview frame's layers.
    var shownDisplayList: DisplayList {
        previewFrame.map { FrameComposer.displayList(document.displayList, for: $0) } ?? document.displayList
    }

    /// Plays the document's frames (`AnimationInfo`: its source, fps, loop and layer holds, over
    /// the window's pages) in preview mode from the first, driven by `ticker` -- the canvas's
    /// display link by default.  Nil when the document has no frames.
    @discardableResult
    func startPlayback(ticker: PlaybackTicker? = nil) -> CanvasPlayback? {
        endPreview()
        let info = AnimationInfo(document.state)
        let frames = info.frames(pages: document.pages)
        guard !frames.isEmpty else { return nil }
        let playback = CanvasPlayback(canvas: self, frames: frames, timeline: AnimationTimeline(frames: frames, fps: info.fps, loop: info.loop),
                                      ticker: ticker ?? DisplayLinkTicker(view: self))
        self.playback = playback
        previewFrame = frames[0]
        playback.player.play()
        return playback
    }

    /// Leaves preview mode: playback stops and the whole document shows again.
    func endPreview() {
        playback?.player.stop()
        playback = nil
        previewFrame = nil
    }

    /// Switches the tiles between frames: only the objects on layers that appear or disappear
    /// repaint.  While previewing the canvas takes document changes itself (the batcher would
    /// show the whole list).
    fileprivate func previewFrameDidChange(from old: AnimationFrame?) {
        if old == nil {
            document.invalidation.remove(tiles)
        } else if previewFrame == nil {
            document.invalidation.add(tiles)
        }
        let full = document.displayList
        let everything = Set(full.layers.map(\.layer.id))
        let changed = (old.map { Set($0.layers) } ?? everything).symmetricDifference(previewFrame.map { Set($0.layers) } ?? everything)
        var summary = ChangeSummary(origin: .local)
        for span in full.layers where changed.contains(span.layer.id) {
            for node in full.nodeIDs.isEmpty ? [] : full.nodeIDs[span.range] {
                if let node { summary.touch(node) }
            }
        }
        tiles.update(displayList: shownDisplayList, viewport: viewport, changes: summary)
        overlay.setNeedsDisplay()
    }
}

/// Canvas playback over a frame list: the player's frame becomes the canvas's preview frame.
@MainActor
final class CanvasPlayback {
    let frames: [AnimationFrame]
    let player: AnimationPlayer

    init(canvas: CanvasView, frames: [AnimationFrame], timeline: AnimationTimeline, ticker: PlaybackTicker) {
        self.frames = frames
        player = AnimationPlayer(timeline: timeline, ticker: ticker)
        player.onFrame = { [weak canvas] index in
            canvas?.previewFrame = frames[index]
        }
    }
}

/// A `PlaybackTicker` on the canvas's display refresh (`NSView.displayLink`; `CVDisplayLink` is
/// deprecated on macOS 15), reporting the frame's timestamp in seconds.
@MainActor
final class DisplayLinkTicker: NSObject, PlaybackTicker {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var tick: (@MainActor (Double) -> Void)?

    init(view: NSView) {
        self.view = view
    }

    var isRunning: Bool { link != nil }

    func start(_ tick: @escaping @MainActor (Double) -> Void) {
        stop()
        guard let view else { return }
        self.tick = tick
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        fire(at: link.timestamp)
    }

    /// One refresh at `time` (what the display link calls; tests call it directly).
    func fire(at time: Double) {
        tick?(time)
    }
}
