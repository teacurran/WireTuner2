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
    /// The grid, guides and page emphasis (`CanvasFurniture`): the layer right above the tiles.
    let furnitureLayer = CanvasOverlayLayer()
    /// Draws `furnitureLayer`; nil draws nothing.
    var furnitureDrawer: (@MainActor (CGContext) -> Void)?
    /// Draws `presenceLayer` (the window's collaboration); nil draws nothing.
    var presenceDrawer: (@MainActor (CGContext) -> Void)?
    /// The pointer moved over the canvas (pasteboard points) or left it (nil): outgoing presence.
    var onPointer: (@MainActor (Point?) -> Void)?
    /// The user scrolled, zoomed or rotated the view: following ends.
    var onUserNavigation: (@MainActor () -> Void)?
    /// A mouse button went down (true) or up (false) on the canvas.
    var onPress: (@MainActor (Bool) -> Void)?
    /// A press on the canvas at a pasteboard point, before the tool sees it (*Using tools sets
    /// the active page*).
    var onPressAt: (@MainActor (Point) -> Void)?
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
    /// Files dropped on the canvas, with the drop point in pasteboard space (importing.adoc,
    /// "Dragging files from the Finder"); answers whether any was taken.  Nil refuses drops.
    var onFileDrop: (@MainActor ([URL], Point) -> Bool)?
    /// Colours dragged over the canvas (applying-color.adoc, "Applying color to unselected
    /// objects"); nil refuses them.
    var colorDrop: CanvasColorDrop?
    /// A colour dropped on text (TYPE-030): answers whether it took the drop, before `colorDrop`.
    var textColorDrop: (@MainActor (NSPasteboard, Point) -> Bool)?
    /// Text dragged in from another application (TYPE-009): into a block or as a new one.
    var textDrop: CanvasTextDrop?
    /// More overlay drawing after the tool's (the spelling underlines, TYPE-014), in view points.
    var overlayExtras: [@MainActor (CGContext, Viewport) -> Void] = []
    /// Objects dragged in from a document window (OBJ-013): pasted at the drop point; nil
    /// refuses them.
    var objectDrop: ObjectDragging?
    /// Graphic styles dragged from the Styles panel (styles.adoc, "Applying styles"): the object
    /// under the pointer takes the style; nil refuses them.
    var styleDrop: StyleCanvasDrop?
    /// Keys taken before the tool and the menus while text is typed (TYPE-012: special
    /// characters and smart quotes); answers whether it took the key.
    var textKeys: (@MainActor (NSEvent) -> Bool)?
    /// A secondary click's menu before the window's (TYPE-014: spelling suggestions); nil defers.
    var textContextMenu: (@MainActor (NSEvent, Point) -> NSMenu?)?
    /// Services in the app menu (IO-037): the requestor for a send and return type, or nil.
    var servicesRequestor: (@MainActor (NSPasteboard.PasteboardType?, NSPasteboard.PasteboardType?) -> Any?)?
    /// A drag that left the window (OBJ-013): the Pointer's move becomes a dragging session when
    /// this answers true.
    var onDragOut: (@MainActor (NSEvent) -> Bool)?
    /// A drag that left the canvas (not necessarily the window): the Eyedropper's colour becomes a
    /// dragging session to the panels' wells when this answers true (COLOR-012).
    var onLeaveCanvas: (@MainActor (NSEvent) -> Bool)?
    /// The modifiers held during a drag (kbd:[Shift], kbd:[Cmd], kbd:[Option] choose what a colour
    /// drop colours); replaceable in tests.
    var dragModifiers: @MainActor () -> KeyModifiers = { KeyEquivalentResolver.modifiers(NSEvent.modifierFlags) }

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
        for sublayer in [tiles.layer, furnitureLayer, presenceLayer, overlay] as [CALayer] {
            sublayer.anchorPoint = .zero
            sublayer.position = .zero
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            root.addSublayer(sublayer)
        }
        overlay.drawer = { [weak self] ctx in self?.drawOverlay(in: ctx) }
        presenceLayer.drawer = { [weak self] ctx in self?.presenceDrawer?(ctx) }
        furnitureLayer.drawer = { [weak self] ctx in self?.furnitureDrawer?(ctx) }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(Self.accessibilityIdentifier)
        setAccessibilityLabel("Canvas")
        registerForDraggedTypes([.fileURL, ColorDrag.type, .color, ObjectDragging.type, SystemObjectPasteboard.legacyType, StyleDrag.type, TeamLibraryDrag.type]
                                + TextPasting.dropTypes)

        document.invalidation.add(tiles)
        documentObservation = document.observe { [weak self] change in self?.documentDidChange(change) }
        navigation.scroller.extent = documentExtent
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

    // MARK: Dropping files and colours

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !FileDrop.urls(from: sender.draggingPasteboard).isEmpty { return onFileDrop != nil ? .copy : [] }
        if ObjectDragging.carriesObjects(sender.draggingPasteboard) { return objectDrop != nil ? .copy : [] }
        if StyleCanvasDrop.carriesStyle(sender.draggingPasteboard) { return styleDrop != nil ? .copy : [] }
        if TeamLibraryDrag.carries(sender.draggingPasteboard) { return TeamLibraryDrag.drop != nil ? .copy : [] }
        if ColorDrag.read(from: sender.draggingPasteboard, defaultSpace: .sRGB) == nil, let textDrop, textDrop.update(sender.draggingPasteboard, at: dropPoint(sender), viewport: viewport) {
            overlay.setNeedsDisplay()
            return .copy
        }
        guard let colorDrop else { return [] }
        let over = colorDrop.update(sender.draggingPasteboard, at: dropPoint(sender), viewport: viewport, modifiers: dragModifiers())
        overlay.setNeedsDisplay()
        return over ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        colorDrop?.exit()
        textDrop?.exit()
        overlay.setNeedsDisplay()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = FileDrop.urls(from: sender.draggingPasteboard)
        if !urls.isEmpty {
            guard let onFileDrop else { return false }
            return onFileDrop(urls, viewport.toPasteboard(dropPoint(sender)))
        }
        if ObjectDragging.carriesObjects(sender.draggingPasteboard) {
            return objectDrop?.drop(sender.draggingPasteboard, at: viewport.toPasteboard(dropPoint(sender))) != nil
        }
        if StyleCanvasDrop.carriesStyle(sender.draggingPasteboard) {
            return styleDrop?.drop(sender.draggingPasteboard, at: dropPoint(sender), viewport: viewport) != nil
        }
        if TeamLibraryDrag.carries(sender.draggingPasteboard) {
            return TeamLibraryDrag.perform(sender.draggingPasteboard, at: viewport.toPasteboard(dropPoint(sender)), in: document)
        }
        defer { overlay.setNeedsDisplay() }
        if ColorDrag.read(from: sender.draggingPasteboard, defaultSpace: .sRGB) == nil,
           textDrop?.drop(sender.draggingPasteboard, at: dropPoint(sender), viewport: viewport, plain: dragModifiers().contains(.option)) != nil {
            return true
        }
        if let textColorDrop, textColorDrop(sender.draggingPasteboard, dropPoint(sender)) { return true }
        return colorDrop?.drop(sender.draggingPasteboard, at: dropPoint(sender), viewport: viewport, modifiers: dragModifiers()) != nil
    }

    /// Where a drag is, view points.
    private func dropPoint(_ sender: any NSDraggingInfo) -> Point {
        viewPoint(fromAppKit: convert(sender.draggingLocation, from: nil))
    }

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
        furnitureLayer.bounds = overlay.bounds
        furnitureLayer.setNeedsDisplay()
    }

    /// The window closed for good: the tiles and the overlay layers' drawings are dropped, so a
    /// closed window that something still references holds no pixels.
    func discardContents() {
        tiles.discardTiles()
        for layer in [overlay, presenceLayer, furnitureLayer] as [CALayer] { layer.contents = nil }
    }

    /// The grid, guides or page emphasis changed: only their layer redraws.
    func setNeedsFurnitureDisplay() {
        furnitureLayer.setNeedsDisplay()
    }

    /// Only the parts of the furniture layer under `rects` (view points, y down, as the drawers
    /// draw) redraw: a link change repaints its object's area of the Show Links overlay (WEB-004).
    func setNeedsFurnitureDisplay(in rects: [CGRect]) {
        let height = furnitureLayer.bounds.height
        for rect in rects where !rect.isNull && !rect.isEmpty {
            furnitureLayer.setNeedsDisplay(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
        }
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
            furnitureLayer.contentsScale = scale
        }
        render()
    }

    /// The display link runs while the canvas is in a window: frames are drawn at the display's
    /// refresh only when something changed, and never by `nextDrawable()` from here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFocus()
        if window == nil {
            releaseLostPress()
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
        refreshExtent()
        if let previewFrame {
            // Out of the invalidation batcher while previewing: the next frame shows the change.
            tiles.update(displayList: FrameComposer.displayList(change.after, for: previewFrame), viewport: viewport, changes: change.summary)
        }
        updateAccessibilityValue()
        overlay.setNeedsDisplay()
        presenceLayer.setNeedsDisplay()
        furnitureLayer.setNeedsDisplay()
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

    func whenTilesCatchUp(_ body: @escaping @MainActor () -> Void) {
        let tiles = tiles
        Task { @MainActor in
            await tiles.settle()
            body()
        }
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
        // Centred in the safe area, above the scroll bar (AppKit coordinates: y up).
        let safe = appKitSafeRect
        hud.frame = CGRect(x: safe.midX - width / 2, y: safe.minY + 24, width: width, height: 26)
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
        colorDrop?.drawHighlight(in: ctx, viewport: viewport)
        toolManager?.drawOverlay(in: ctx, viewport: viewport)
        for extra in overlayExtras { extra(ctx, viewport) }
    }

    override func resetCursorRects() {
        // Only the safe area: the dock, rulers and scroll bars over the canvas keep their cursors.
        addCursorRect(appKitSafeRect, cursor: toolManager?.cursor ?? .arrow)
    }

    // MARK: Scroll extent (D-093)

    /// Whether the scroll extent follows the document (`CanvasExtent`: the pages with their
    /// margins and any artwork beyond them).  A glyph canvas sets its own extent and turns this off.
    var derivesExtent = true

    /// The extent the document asks for now: its pages' union with the margins, widened to the
    /// drawn objects (one pass over the display list's item bounds).
    var documentExtent: Rect {
        CanvasExtent.extent(pages: document.allPagesBounds, artwork: CanvasExtent.artworkBounds(of: document.displayList))
    }

    /// After a document change: the extent follows the pages and artwork, and the view is
    /// clamped into it (a page moved away, artwork deleted) with the scroll bars updated.
    func refreshExtent() {
        guard derivesExtent else { return }
        let extent = documentExtent
        guard extent != navigation.scroller.extent else { return }
        navigation.scroller.extent = extent
        let clamped = navigation.clamped(viewport)
        if clamped != viewport {
            viewport = clamped
            render()
        }
        onViewportChange?(viewport)
    }

    // MARK: Safe area (D-077)

    /// The canvas's covered edges (the docks, rulers and scroll bars laid over it), view points.
    /// Fits, centring, the scroll bars, auto-scroll, the cursor and pointer tracking use what is
    /// left; the tiles are drawn under the covered parts too.
    var safeInsets: CanvasInsets {
        get { navigation.insets }
        set {
            guard newValue != navigation.insets else { return }
            navigation.insets = newValue
            let clamped = navigation.clamped(viewport)
            if clamped != viewport {
                viewport = clamped
                render()
            }
            onViewportChange?(viewport)
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }
    }

    /// The unobscured part of the canvas, view points (y down).
    var safeRect: Rect { navigation.safeRect(viewport) }

    /// The unobscured part of the canvas in this view's AppKit coordinates (y up).
    var appKitSafeRect: CGRect {
        let safe = navigation.insets.safeRect(in: Size(bounds.size))
        return CGRect(x: safe.minX, y: Double(bounds.height) - safe.maxY, width: safe.width, height: safe.height).intersection(bounds)
    }

    /// The pasteboard point at the centre of the safe area (where Paste and Import land).
    var visibleCenter: Point { viewport.toPasteboard(navigation.safeCenter(viewport)) }

    /// The pasteboard rectangle the safe area shows (its bounding box when the canvas is rotated).
    var visiblePasteboardBounds: Rect {
        let safe = safeRect
        let corners = [Point(x: safe.minX, y: safe.minY), Point(x: safe.maxX, y: safe.minY), Point(x: safe.minX, y: safe.maxY), Point(x: safe.maxX, y: safe.maxY)]
            .map(viewport.toPasteboard)
        return Rect(minX: corners.map(\.x).min()!, minY: corners.map(\.y).min()!, maxX: corners.map(\.x).max()!, maxY: corners.map(\.y).max()!)
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
        guard owns(event) else { return }
        window?.makeFirstResponder(self)
        if previewFrame != nil {
            // Clicking the canvas ends preview mode (animation.adoc, "Client").
            endPreview()
        }
        if event.modifierFlags.contains(.control), toolManager?.activeToolID != .zoom, !cyclesSelection(event), let menu = contextMenu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // A press whose mouse-up never came ends where it was before this one begins.
        if toolManager?.isPressed == true { releaseLostPress() }
        stopAutoscroll()
        let translated = canvasEvent(event)
        onPressAt?(translated.pasteboardPoint)
        toolManager?.mouseDown(translated)
        onPress?(true)
        watchForRelease()
    }

    /// Whether `event` is the canvas's: not from another window, and not at a point where the
    /// window shows something laid over the canvas -- a dock, a panel, a dock handle, the status
    /// bar (`PanelEventBarrierView`).  AppKit passes an event those leave unhandled to the view
    /// underneath, which is the canvas (found in use, 2026-10-02: a click on a tool in the Tools
    /// panel pressed the canvas and left it pressed); the barriers stop them, and this keeps any
    /// that get by from starting anything.  An event with no window (tests) or a canvas outside a
    /// window is the canvas's.
    func owns(_ event: NSEvent) -> Bool {
        guard let window else { return true }
        if let other = event.window, other !== window { return false }
        guard let frame = window.contentView?.superview ?? window.contentView else { return true }
        // `hitTest` takes a point in the superview's space; the frame view's is the window's.
        let point = frame.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = frame.hitTest(point)
        while let current = view {
            if current is PanelEventBarrierView { return false }
            view = current.superview
        }
        return true
    }

    /// Whether a scroll or gesture `event` is the canvas's: its first event decides for the
    /// rest of the gesture and its momentum; a wheel's clicks are decided one by one.
    func ownsGesture(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            gestureIsOwned = owns(event)
            return gestureIsOwned
        }
        if event.phase.isEmpty && event.momentumPhase.isEmpty { return owns(event) }
        return gestureIsOwned
    }

    /// Whether the scroll or gesture in progress began over the canvas.
    private(set) var gestureIsOwned = true

    /// Whether `event` lies outside the window's content (a drag out of the window, OBJ-013).
    func leftWindow(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return false }
        return !content.bounds.contains(content.convert(event.locationInWindow, from: nil))
    }

    /// Whether `event` lies outside the canvas's bounds.
    func leftCanvas(_ event: NSEvent) -> Bool {
        !bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// kbd:[Control+Option]-click with the Pointer or Subselect tool cycles through stacked objects
    /// (OBJ-007) instead of opening the context menu.
    func cyclesSelection(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option), let tool = toolManager?.activeToolID else { return false }
        return tool == PointerTool.id || tool == PointerTool.subselectID
    }

    /// The Info toolbar follows the pointer (BASIC-011).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        // The safe area only: a pointer over the dock or the rulers is not over the canvas.
        addTrackingArea(NSTrackingArea(rect: appKitSafeRect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        // The pointer moves with the button up: a press still in progress lost its mouse-up.
        if toolManager?.isPressed == true, !mouseButtonIsDown() { releaseLostPress() }
        guard appKitSafeRect.contains(convert(event.locationInWindow, from: nil)) else {
            // Tracking areas hear the mouse through the views laid over the canvas.
            onPointer?(nil)
            return
        }
        let translated = canvasEvent(event)
        toolManager?.pointerMoved(translated)
        onPointer?(translated.pasteboardPoint)
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        if leftWindow(event), onDragOut?(event) == true {
            stopAutoscroll()
            onPress?(false)
            return
        }
        if leftCanvas(event), onLeaveCanvas?(event) == true {
            stopAutoscroll()
            onPress?(false)
            return
        }
        let translated = canvasEvent(event)
        toolManager?.mouseDragged(translated)
        updateAutoscroll(translated)
        onPointer?(translated.pasteboardPoint)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        stopWatchingForRelease()
        toolManager?.mouseUp(canvasEvent(event))
        onPress?(false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard owns(event) else { return nil }
        return contextMenu(for: event)
    }

    /// The context menu for the point of `event`, from the window (BASIC-018).
    func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = viewPoint(fromAppKit: convert(event.locationInWindow, from: nil))
        if let menu = textContextMenu?(event, point) { return menu }
        return onContextMenu?(event, point)
    }

    override func flagsChanged(with event: NSEvent) {
        toolManager?.flagsChanged(KeyEquivalentResolver.modifiers(event.modifierFlags), timestamp: event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        // kbd:[Esc] ends a drag (the tool manager cancels it): auto-scroll stops with it.
        if event.keyCode == CanvasEventTranslator.escapeKeyCode { stopAutoscroll() }
        if textKeys?(event) == true { return }
        if toolManager?.keyDown(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, textKeys?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        servicesRequestor?(sendType, returnType) ?? super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func keyUp(with event: NSEvent) {
        if toolManager?.keyUp(event) != true { super.keyUp(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard ownsGesture(event) else { return }
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
        guard ownsGesture(event) else { return }
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
        guard rotatesWithTrackpad(), ownsGesture(event) else { return }
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
        guard owns(event) else { return }
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
        return document.pageList.page(containing: point)?.rect
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
    /// Whether the mouse button is down right now (replaceable in tests, which have no mouse).
    /// Auto-scroll runs only while it is: a press whose mouse-up went elsewhere is released.
    var mouseButtonIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// Hears every mouse-up the app dispatches while a press is in progress (`watchForRelease`).
    private var releaseMonitor: Any?
    /// The window resigning key and the app resigning active (`observeFocus`).
    private var focusObservers: [NSObjectProtocol] = []

    private func updateAutoscroll(_ event: CanvasEvent) {
        guard autoscrolls(), CanvasAutoscroll.delta(viewPoint: event.viewPoint, in: safeRect) != nil else {
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
        guard let event = autoscrollEvent, let delta = CanvasAutoscroll.delta(viewPoint: event.viewPoint, in: safeRect) else {
            return false
        }
        guard mouseButtonIsDown() else {
            // The button came up and the canvas never heard it: no scrolling without a press.
            releaseLostPress()
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

    /// The press in progress lost its mouse-up -- the button is up, or the mouse-up went to
    /// another view or window: auto-scroll stops and the tool's drag ends where the pointer last
    /// was, as that mouse-up would have ended it (`ToolManager.finishDrag`).  Nothing happens
    /// between presses.
    func releaseLostPress() {
        stopAutoscroll()
        stopWatchingForRelease()
        guard let toolManager, toolManager.isPressed else { return }
        toolManager.finishDrag()
        onPress?(false)
    }

    /// While a press is in progress, every mouse-up the app dispatches is heard: one that does
    /// not reach the canvas releases the press (`mouseUpWasDispatched`).
    private func watchForRelease() {
        guard releaseMonitor == nil else { return }
        releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.heardMouseUp()
            return event
        }
    }

    private func stopWatchingForRelease() {
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
        releaseMonitor = nil
    }

    /// A mouse-up is about to be dispatched: once AppKit has delivered it, a press still in
    /// progress did not get it.
    func heardMouseUp() {
        Task { @MainActor [weak self] in self?.mouseUpWasDispatched() }
    }

    /// After a mouse-up was dispatched: the press that missed it is released.
    func mouseUpWasDispatched() {
        guard toolManager?.isPressed == true else {
            stopWatchingForRelease()
            return
        }
        if !mouseButtonIsDown() { releaseLostPress() }
    }

    /// The window stopped being key or the app stopped being active: auto-scroll stops, and a
    /// press whose button is already up is released (its mouse-up went to another window or app).
    func focusDidLeave() {
        stopAutoscroll()
        if toolManager?.isPressed == true, !mouseButtonIsDown() { releaseLostPress() }
    }

    /// Hears the window resign key and the app resign active (`focusDidLeave`).
    private func observeFocus() {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let leave: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.focusDidLeave() }
        }
        focusObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil, using: leave),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil, using: leave),
        ]
    }

    isolated deinit {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        if let releaseMonitor { NSEvent.removeMonitor(releaseMonitor) }
    }
}

/// How fast the view scrolls when a drag reaches the canvas edge.
enum CanvasAutoscroll {
    /// The band inside the edge, in view points, where scrolling starts.
    static let edge = 8.0
    /// View points per step at the edge; further out scrolls faster, up to `maximumStep`.
    static let step = 8.0
    /// Capped (found in use, 2026-10-02): over a dock the pointer is far past the edge, and 48
    /// points a step ran the artboard out of sight before a person could react.
    static let maximumStep = 24.0

    /// The scroll for a pointer at `viewPoint` in a view of `size`; nil well inside it.
    static func delta(viewPoint: Point, size: Size) -> Vector? {
        delta(viewPoint: viewPoint, in: Rect(x: 0, y: 0, width: size.width, height: size.height))
    }

    /// The scroll for a pointer at `viewPoint` near the edges of `area` (the canvas's safe area,
    /// view points: a drag reaching the dock scrolls as a drag reaching the window's edge does).
    static func delta(viewPoint: Point, in area: Rect) -> Vector? {
        let dx = axis(viewPoint.x - area.minX, length: area.width)
        let dy = axis(viewPoint.y - area.minY, length: area.height)
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
