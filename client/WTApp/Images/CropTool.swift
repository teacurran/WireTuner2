import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Crop tool (cropping-bitmaps.adoc, "Cropping with the Crop tool"; IMG-025): eight handles on
/// the visible part of one image, the hidden part of the picture dimmed beyond them.  A handle drag
/// moves its edges (kbd:[Shift] keeps the proportions on a corner, kbd:[Option] moves the opposite
/// edge the same amount); a drag inside slides the picture behind the crop.  Each drag writes one
/// change at mouse-up ("Crop <name>", `CropImage`).  kbd:[Return] or kbd:[Esc] (with no drag to
/// abandon) hands back to the Pointer, as switching tools does.  The arithmetic is
/// `WTModel.ImageCropping`.
@MainActor
final class CropTool: Tool {
    static let id: ToolID = "crop"
    static let statusMessage = "Drag a handle to crop, or inside to slide the picture; Shift keeps proportions, Option crops symmetrically"
    static let handleRadius = 5.0
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// A drag in progress.
    struct Drag: Equatable {
        var node: OpID
        /// The handle dragged; nil slides the picture.
        var handle: ImageCropping.Handle?
        var start: Point
        /// The crop when the drag began, and now.
        var original: Rect
        var crop: Rect
        /// Sliding: the local translation that keeps the visible part in place.
        var slide = Vector(dx: 0, dy: 0)
    }

    private var context: ToolContext?
    /// The image being cropped.
    private(set) var target: OpID?
    private(set) var drag: Drag?

    init() {}

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        target = ImageResolutionHandles.image(context)
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        drag = nil
        target = nil
        context = nil
    }

    // MARK: Geometry

    /// An image's natural frame and its pasteboard transform.
    static func frame(of node: OpID, in state: EngineState) -> (natural: Rect, transform: WTGeometry.AffineTransform)? {
        guard case .image(let props)? = state.props(node).kind else { return nil }
        return (ImageNodes.naturalRect(props), Objects.pasteboardTransform(of: node, in: state))
    }

    /// The local rectangle a unit crop covers.
    static func local(_ crop: Rect, natural: Rect) -> Rect {
        Rect(x: natural.minX + crop.minX * natural.width, y: natural.minY + crop.minY * natural.height,
             width: crop.width * natural.width, height: crop.height * natural.height)
    }

    /// A handle's point on `crop`, pasteboard.
    static func point(_ handle: ImageCropping.Handle, crop: Rect, natural: Rect, transform: WTGeometry.AffineTransform) -> Point {
        let rect = local(crop, natural: natural)
        return transform.apply(Point(x: rect.minX + rect.width * handle.unit.x, y: rect.minY + rect.height * handle.unit.y))
    }

    /// The crop shown now: the drag's, else the image's.
    func crop(of node: OpID, in state: EngineState) -> Rect {
        if let drag, drag.node == node { return drag.crop }
        return ImageCropping.crop(of: node, in: state) ?? ImageCropping.full
    }

    /// The handle of `node` under `viewPoint`.
    func handle(at viewPoint: Point, node: OpID, context: ToolContext) -> ImageCropping.Handle? {
        guard let (natural, transform) = Self.frame(of: node, in: context.document.state) else { return nil }
        let crop = crop(of: node, in: context.document.state)
        return ImageCropping.Handle.allCases.first {
            context.viewport.toView(Self.point($0, crop: crop, natural: natural, transform: transform)).distance(to: viewPoint) <= Self.handleRadius
        }
    }

    /// Whether `point` (pasteboard) is inside `node`'s visible part.
    func isInside(_ point: Point, node: OpID, state: EngineState) -> Bool {
        guard let (natural, transform) = Self.frame(of: node, in: state), let inverse = transform.inverted() else { return false }
        return Self.local(crop(of: node, in: state), natural: natural).contains(inverse.apply(point))
    }

    /// The editable image under `e`, if any.
    static func image(at e: CanvasEvent, context: ToolContext) -> OpID? {
        let document = context.document
        let state = document.state
        for hit in context.selection.hitTester(viewport: context.viewport, subselect: true).hitTest(viewPoint: e.viewPoint) {
            guard let id = document.selectionID(atItemPath: hit.itemPath)?.opID else { continue }
            if state.nodeKind(id) == .image, !Objects.isEffectivelyLocked(id, in: state) { return id }
        }
        return nil
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        let state = context.document.state
        if let target, state.isLive(target) {
            if let handle = handle(at: e.viewPoint, node: target, context: context) {
                let crop = crop(of: target, in: state)
                drag = Drag(node: target, handle: handle, start: e.pasteboardPoint, original: crop, crop: crop)
                return
            }
            if isInside(e.pasteboardPoint, node: target, state: state) {
                let crop = crop(of: target, in: state)
                drag = Drag(node: target, handle: nil, start: e.pasteboardPoint, original: crop, crop: crop)
                return
            }
        }
        // A click on another image crops that one.
        target = Self.image(at: e, context: context)
        context.selection.model.set(Selection(target.map { [SelectionID($0)] } ?? []))
        context.host.setNeedsOverlayDisplay()
    }

    /// The drag's crop with the pointer at `e`.
    static func dragged(_ drag: Drag, to e: CanvasEvent, in state: EngineState) -> Drag {
        guard let (natural, transform) = frame(of: drag.node, in: state) else { return drag }
        let delta = ImageCropping.unitDelta(Vector(dx: e.pasteboardPoint.x - drag.start.x, dy: e.pasteboardPoint.y - drag.start.y),
                                            transform: transform, natural: natural)
        var next = drag
        if let handle = drag.handle {
            next.crop = ImageCropping.resize(drag.original, handle: handle, by: delta, proportional: e.modifiers.contains(.shift),
                                             symmetric: e.modifiers.contains(.option))
        } else {
            // The picture follows the pointer: the crop moves the other way over it, and the image
            // moves by as much, so the visible part stays where it is.
            next.crop = ImageCropping.slide(drag.original, by: Vector(dx: -delta.dx, dy: -delta.dy))
            next.slide = Vector(dx: (drag.original.minX - next.crop.minX) * natural.width, dy: (drag.original.minY - next.crop.minY) * natural.height)
        }
        return next
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let context, let drag else { return }
        self.drag = Self.dragged(drag, to: e, in: context.document.state)
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        guard let context, let current = drag else { return }
        let state = context.document.state
        let final = Self.dragged(current, to: e, in: state)
        drag = nil
        guard final.crop != final.original else { return }
        let name = state.displayName(of: final.node)
        context.commandSink.perform(CropImage([final.node], crop: final.crop, slide: final.handle == nil ? final.slide : nil, name: name))
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// kbd:[Return] finishes: the Pointer takes over.
    func keyDown(_ e: NSEvent) -> Bool {
        guard Self.returnKeyCodes.contains(e.keyCode), let context else { return false }
        finish(context)
        return true
    }

    func finish(_ context: ToolContext) {
        drag = nil
        context.selectTool(.pointer)
    }

    /// kbd:[Esc]: abandons a drag; with none, finishes.
    func cancel() {
        if drag != nil {
            drag = nil
            context?.host.setNeedsOverlayDisplay()
            return
        }
        if let context { finish(context) }
    }

    var hasSomethingToCancel: Bool { target != nil || drag != nil }

    // MARK: Overlay

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context, let target, let (natural, transform) = Self.frame(of: target, in: context.document.state) else { return }
        let crop = crop(of: target, in: context.document.state)
        func polygon(_ rect: Rect) -> [CGPoint] {
            [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
                .map { viewport.toView(transform.apply($0)).cgPoint }
        }
        let whole = polygon(natural)
        let visible = polygon(Self.local(crop, natural: natural))
        ctx.saveGState()
        // The hidden part of the picture, dimmed.
        let hidden = CGMutablePath()
        hidden.addLines(between: whole)
        hidden.closeSubpath()
        hidden.addLines(between: visible)
        hidden.closeSubpath()
        ctx.addPath(hidden)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.3))
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.addLines(between: whole + [whole[0]])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.addLines(between: visible + [visible[0]])
        ctx.strokePath()
        for handle in ImageCropping.Handle.allCases {
            let at = viewport.toView(Self.point(handle, crop: crop, natural: natural, transform: transform))
            ctx.fill(CGRect(x: at.x - 3.5, y: at.y - 3.5, width: 7, height: 7))
        }
        ctx.restoreGState()
    }
}

/// The Crop tool's registration and its commands: menu:Object[Image > Crop] chooses the tool,
/// menu:Modify[Remove Crop] removes the crop of the selected images.
@MainActor
enum CropFeatures {
    static let removeCropID: CommandID = "modify.removeCrop"

    /// The selected images that are cropped.
    static func croppedImages(_ window: DocumentWindowController?) -> [OpID] {
        guard let window else { return [] }
        let state = window.documentHandle.state
        return window.selection.selection.ids.map(\.opID).filter { ImageCropping.isCropped($0, in: state) }
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        [
            Command(id: removeCropID, title: "Remove Crop", menu: MenuPath(ContextMenuCatalog.Menu.modify, section: 3), contexts: [.bitmap],
                    keywords: ["crop", "image", "uncrop"],
                    validation: { croppedImages(window()).isEmpty ? .disabled("Select a cropped image") : .enabled },
                    action: .perform {
                        guard let window = window() else { return }
                        let images = croppedImages(window)
                        if !images.isEmpty { window.objectEditing.perform(CropImage(images, crop: nil)) }
                    }),
            Command(id: ContextMenuCatalog.ID.imageCrop, title: "Crop", menu: MenuPath(ContextMenuCatalog.Menu.object, "Image", section: 0), contexts: [.bitmap],
                    keywords: ["crop", "image", "trim"],
                    validation: { window() == nil ? .disabled("Open a document") : .enabled },
                    action: .perform { window()?.toolManager.select(CropTool.id) }),
        ]
    }
}
