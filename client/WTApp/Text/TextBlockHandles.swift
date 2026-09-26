import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText

/// Where a text block's handles are (text-blocks.adoc, "Reading the handles"; TYPE-005): its laid
/// out rectangle in its own space and the transform that places it.
@MainActor
struct TextBlockFrame {
    enum Handle: Equatable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// The handle's place on the unit square (y down).
        var unit: (x: Double, y: Double) {
            switch self {
            case .topLeft: (0, 0)
            case .top: (0.5, 0)
            case .topRight: (1, 0)
            case .right: (1, 0.5)
            case .bottomRight: (1, 1)
            case .bottom: (0.5, 1)
            case .bottomLeft: (0, 1)
            case .left: (0, 0.5)
            }
        }

        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        var isSide: Bool { self == .left || self == .right }

        /// The corner across from a corner.
        var opposite: Handle {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomRight: .topLeft
            case .bottomLeft: .topRight
            case .top: .bottom
            case .bottom: .top
            case .left: .right
            case .right: .left
            }
        }
    }

    let node: OpID
    let text: TextNode
    /// The laid-out rectangle, block space.
    let local: Rect
    /// Block space → pasteboard.
    let transform: WTGeometry.AffineTransform
    let overflows: Bool

    /// The frame of text block `node`, nil for anything else (text on a path has no handles).
    init?(_ node: OpID, document: DocumentHandle) {
        let state = document.state
        guard let text = state.textNode(node), TextLayoutReading.path(of: text, in: state) == nil, let layout = document.textLayout(for: node) else { return nil }
        self.node = node
        self.text = text
        local = TextFrames.frame(of: layout)
        transform = Objects.pasteboardTransform(of: node, in: state)
        overflows = layout.overflows
    }

    var block: Wiretuner_Doc_V1_TextBlockProps { text.props.block }
    var isLinked: Bool { text.props.hasNextLink }

    /// A handle's point, block space.
    func localPoint(_ handle: Handle) -> Point {
        Point(x: local.minX + local.width * handle.unit.x, y: local.minY + local.height * handle.unit.y)
    }

    func point(_ handle: Handle) -> Point { transform.apply(localPoint(handle)) }

    /// Whether a handle is drawn hollow: the side handles of an auto width, the top and bottom
    /// ones of an auto height.
    func isHollow(_ handle: Handle) -> Bool {
        switch handle {
        case .left, .right: block.autoWidth
        case .top, .bottom: block.autoHeight
        default: false
        }
    }

    /// The link box's centre, block space: just past the lower-right corner.
    func linkBoxCenter(zoom: Double) -> Point {
        let offset = TextBlockHandles.linkBoxOffset / max(zoom, 0.0001)
        return Point(x: local.maxX + offset, y: local.maxY + offset)
    }

    /// Pasteboard → block space.
    func toLocal(_ point: Point) -> Point { (transform.inverted() ?? .identity).apply(point) }
}

/// A corner drag's result (text-blocks.adoc, "Moving, resizing and deleting"): kbd:[Shift] keeps
/// the proportions, kbd:[Option] scales the type size with the block, both do both.  The corner
/// across stays where it is; one change writes the width and height (fixing an auto dimension),
/// the block's new placement when its top-left moved, and with kbd:[Option] a `size` mark per run
/// scaled by the vertical factor (the uniform one with kbd:[Shift]).
@MainActor
enum TextBlockResize {
    struct Result: Equatable {
        var width: Double
        var height: Double
        /// The new top-left, block space (the old one is the origin).
        var origin: Point
        /// The factor the type scales by (1 without kbd:[Option]).
        var typeScale: Double
    }

    static func result(_ frame: TextBlockFrame, corner: TextBlockFrame.Handle, to point: Point, shift: Bool, option: Bool) -> Result? {
        guard corner.isCorner, frame.local.width > 0, frame.local.height > 0 else { return nil }
        let fixed = frame.localPoint(corner.opposite)
        let start = frame.localPoint(corner)
        var dragged = frame.toLocal(point)
        // The frame is at least 1 point each way, so the factors are finite.
        let sx0 = (dragged.x - fixed.x) / (start.x - fixed.x)
        let sy0 = (dragged.y - fixed.y) / (start.y - fixed.y)
        var sx = sx0
        var sy = sy0
        if shift {
            let s = max(abs(sx0), abs(sy0))
            sx = s
            sy = s
            dragged = Point(x: fixed.x + (start.x - fixed.x) * sx, y: fixed.y + (start.y - fixed.y) * sy)
        }
        let rect = Rect(fixed, dragged)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let typeScale = option ? abs(shift ? sx : sy) : 1
        return Result(width: rect.width.rounded(toPlaces: 2), height: rect.height.rounded(toPlaces: 2),
                      origin: Point(x: rect.minX - frame.local.minX, y: rect.minY - frame.local.minY), typeScale: typeScale)
    }

    /// The change a resize writes.
    static func command(_ frame: TextBlockFrame, _ result: Result, state: EngineState) -> any WTModel.Command {
        var commands: [any WTModel.Command] = []
        var block = Wiretuner_Doc_V1_TextBlockProps()
        block.width = result.width
        block.height = result.height
        var fields: [[UInt32]] = [[3], [4]]
        if frame.block.autoWidth { fields.append([1]) }
        if frame.block.autoHeight { fields.append([2]) }
        commands.append(SetTextBlock(node: frame.node, block: block, fields: fields, label: "Resize"))
        if result.origin != .zero {
            let current = Objects.transform(of: frame.node, in: state)
            commands.append(SetTransforms([(frame.node, WTGeometry.AffineTransform.translation(Vector(dx: result.origin.x, dy: result.origin.y)).concatenating(current))], label: "Resize"))
        }
        if result.typeScale != 1 { commands += sizeMarks(frame.text, node: frame.node, scale: result.typeScale) }
        return CommandBatch(result.typeScale != 1 ? "Scale Text Block" : "Resize", commands)
    }

    /// A `size` mark per run of `text` (one over the whole text when it has one size), scaled.
    static func sizeMarks(_ text: TextNode, node: OpID, scale: Double) -> [any WTModel.Command] {
        guard text.length > 0 else { return [] }
        var spans: [(range: Range<Int>, size: Double)] = []
        for run in text.runs {
            let size = min(max(ObjectPanelModel.size(run.values) * scale, 0.1), 10_000).rounded(toPlaces: 2)
            if let last = spans.last, last.size == size, last.range.upperBound == run.range.lowerBound {
                spans[spans.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                spans.append((run.range, size))
            }
        }
        return spans.map { span in
            ApplyMark(node: node, from: text.anchor(at: span.range.lowerBound), to: text.anchor(at: span.range.upperBound), value: .with { $0.size = span.size })
        }
    }

    /// A side handle's double-click: auto width on, or off at the width laid out now.
    static func toggleWidth(_ frame: TextBlockFrame) -> any WTModel.Command {
        let on = !frame.block.autoWidth
        return SetTextBlock(node: frame.node, block: .with {
            $0.autoWidth = on
            $0.width = frame.local.width
        }, fields: on ? [[1]] : [[1], [3]], label: on ? "Auto Width" : "Fixed Width")
    }

    /// The bottom handle's double-click: auto height on, or off at the height laid out now.
    static func toggleHeight(_ frame: TextBlockFrame) -> any WTModel.Command {
        let on = !frame.block.autoHeight
        return SetTextBlock(node: frame.node, block: .with {
            $0.autoHeight = on
            $0.height = frame.local.height
        }, fields: on ? [[2]] : [[2], [4]], label: on ? "Auto Height" : "Fixed Height")
    }

    /// The link box's double-click: the block shrinks (or grows) to its text -- the height all of
    /// it needs at the current width, the width of its longest line when narrower.
    static func fit(_ frame: TextBlockFrame, document: DocumentHandle) -> (any WTModel.Command)? {
        guard case .block(var block) = TextLayoutReading.container(frame.text) else { return nil }
        let content = TextLayoutReading.content(frame.text, colors: ColorResolver(document.state))
        block.autoHeight = true
        let tall = document.textEngine.layout(content, in: [.block(block)]).sizes[0]
        block.autoWidth = true
        let natural = document.textEngine.layout(content, in: [.block(block)]).sizes[0]
        let width = min(frame.block.autoWidth ? natural.width : frame.local.width, natural.width).rounded(toPlaces: 2)
        let height = (width < frame.local.width ? natural.height : tall.height).rounded(toPlaces: 2)
        guard width > 0, height > 0 else { return nil }
        return SetTextBlock(node: frame.node, block: .with {
            $0.width = width
            $0.height = height
        }, fields: [[1], [2], [3], [4]], label: "Fit Text Block")
    }
}

/// The text block handles (TYPE-005): solid or hollow side and bottom handles and the link box on
/// each selected text block, for the Pointer and Subselect tools.  A corner drag resizes (one change
/// at mouse-up); a double-click on a side handle toggles auto width, on the top or bottom handle
/// auto height, on the link box fits the block to its text.  A single press on a side or bottom
/// handle is taken and does nothing yet (the kerning and leading drags are TYPE-018's).
@MainActor
final class TextBlockHandles: CanvasHandleLayer {
    static let radius = 5.0
    static let size = 7.0
    static let linkBoxOffset = 8.0
    static let linkBoxSize = 8.0

    private(set) var dragging: (frame: TextBlockFrame, corner: TextBlockFrame.Handle)?
    /// The drag's current result (the overlay's preview).
    private(set) var preview: TextBlockResize.Result?

    init() {}

    func frames(_ context: ToolContext) -> [TextBlockFrame] {
        context.selection.selection.ids.compactMap { TextBlockFrame($0.opID, document: context.document) }
    }

    /// What a press at `viewPoint` hits.
    enum Hit: Equatable {
        case handle(TextBlockFrame.Handle)
        case linkBox
    }

    static func hit(_ frame: TextBlockFrame, at viewPoint: Point, viewport: Viewport) -> Hit? {
        let box = viewport.toView(frame.transform.apply(frame.linkBoxCenter(zoom: viewport.zoom)))
        if box.distance(to: viewPoint) <= linkBoxSize / 2 + 1 { return .linkBox }
        return TextBlockFrame.Handle.allCases.first { viewport.toView(frame.point($0)).distance(to: viewPoint) <= radius }.map(Hit.handle)
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        for frame in frames(context) {
            guard let hit = Self.hit(frame, at: e.viewPoint, viewport: context.viewport) else { continue }
            switch hit {
            case .linkBox:
                if e.clickCount == 2, let command = TextBlockResize.fit(frame, document: context.document) { context.commandSink.perform(command) }
            case .handle(let handle) where handle.isCorner:
                dragging = (frame, handle)
                preview = nil
            case .handle(let handle):
                guard e.clickCount == 2 else { return true }
                context.commandSink.perform(handle.isSide ? TextBlockResize.toggleWidth(frame) : TextBlockResize.toggleHeight(frame))
            }
            return true
        }
        return false
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let dragging else { return }
        preview = TextBlockResize.result(dragging.frame, corner: dragging.corner, to: e.pasteboardPoint,
                                         shift: e.modifiers.contains(.shift), option: e.modifiers.contains(.option))
        context.host.setNeedsOverlayDisplay()
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        defer {
            dragging = nil
            preview = nil
        }
        guard let dragging, let result = TextBlockResize.result(dragging.frame, corner: dragging.corner, to: e.pasteboardPoint,
                                                                 shift: e.modifiers.contains(.shift), option: e.modifiers.contains(.option)) else { return }
        context.commandSink.perform(TextBlockResize.command(dragging.frame, result, state: context.document.state))
    }

    func cancel(context: ToolContext) {
        dragging = nil
        preview = nil
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        for frame in frames(context) {
            for handle in TextBlockFrame.Handle.allCases {
                let point = viewport.toView(frame.point(handle))
                let rect = CGRect(x: point.x - Self.size / 2, y: point.y - Self.size / 2, width: Self.size, height: Self.size)
                if frame.isHollow(handle) {
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(rect)
                    ctx.stroke(rect)
                    ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                } else {
                    ctx.fill(rect)
                }
            }
            drawLinkBox(frame, in: ctx, viewport: viewport)
        }
        if let dragging, let preview {
            let corners = [Point(x: 0, y: 0), Point(x: preview.width, y: 0), Point(x: preview.width, y: preview.height), Point(x: 0, y: preview.height)]
            let origin = Point(x: dragging.frame.local.minX + preview.origin.x, y: dragging.frame.local.minY + preview.origin.y)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.addPath(TextTool.polygon(corners.map { viewport.toView(dragging.frame.transform.apply(Point(x: origin.x + $0.x, y: origin.y + $0.y))) }))
            ctx.strokePath()
        }
    }

    /// The link box: a square with a dot for overflow or an arrow for a link.
    func drawLinkBox(_ frame: TextBlockFrame, in ctx: CGContext, viewport: Viewport) {
        let center = viewport.toView(frame.transform.apply(frame.linkBoxCenter(zoom: viewport.zoom)))
        let half = Self.linkBoxSize / 2
        let rect = CGRect(x: center.x - half, y: center.y - half, width: Self.linkBoxSize, height: Self.linkBoxSize)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.stroke(rect)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        if frame.isLinked {
            ctx.move(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
            ctx.addLine(to: CGPoint(x: rect.maxX - 2, y: center.y))
            ctx.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
            ctx.closePath()
            ctx.fillPath()
        } else if frame.overflows {
            ctx.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
        }
    }
}

/// menu:Text[Remove Transforms], menu:Extensions[Delete > Empty Text Blocks] and the empty
/// auto-expanding block that deletes itself when deselected (TYPE-005).
@MainActor
enum TextBlockFeatures {
    static let removeTransformsID: CommandID = "text.removeTransforms"
    static let emptyBlocksID = "deleteEmptyTextBlocks"

    static func selectedBlocks(_ window: DocumentWindowController?) -> [OpID] {
        guard let window else { return [] }
        let state = window.documentHandle.state
        return window.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .text }
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        [Command(id: removeTransformsID, title: "Remove Transforms", menu: MenuPath(ContextMenuCatalog.Menu.text, section: 2), contexts: [.text],
                 keywords: ["rotation", "skew", "scale", "unrotate"],
                 validation: { selectedBlocks(window()).isEmpty ? .disabled("Select a text block") : .enabled },
                 action: .perform {
                     guard let window = window(), let command = removeTransforms(selectedBlocks(window), in: window.documentHandle.state) else { return }
                     window.objectEditing.perform(command)
                 })]
    }

    /// Each block placed by its position alone: rotation, skew and scaling dropped, the top-left
    /// kept.  Nil when no block has any.
    static func removeTransforms(_ nodes: [OpID], in state: EngineState) -> (any WTModel.Command)? {
        let transforms = nodes.compactMap { node -> (node: OpID, transform: WTGeometry.AffineTransform)? in
            let current = Objects.transform(of: node, in: state)
            let origin = current.apply(Point.zero)
            let plain = WTGeometry.AffineTransform.translation(Vector(dx: origin.x, dy: origin.y))
            return plain == current ? nil : (node, plain)
        }
        return transforms.isEmpty ? nil : SetTransforms(transforms, label: "Remove Transforms")
    }

    /// The document's empty text blocks: no characters, not in a linked chain, not open in a
    /// Text Editor.
    static func emptyBlocks(_ document: DocumentHandle, editors: TextEditorFeatures = .shared) -> [OpID] {
        let state = document.state
        return textNodes(under: WellKnown.layers, in: state).filter { node in
            guard let text = state.textNode(node), text.length == 0, !text.props.hasNextLink, !text.props.hasPrevLink else { return false }
            return editors.controller(for: node, in: document) == nil
        }.sorted()
    }

    /// The live text nodes under `node`, through layers and groups.
    static func textNodes(under node: OpID, in state: EngineState) -> [OpID] {
        state.liveChildren(node).flatMap { child -> [OpID] in
            state.nodeKind(child) == .text ? [child] : textNodes(under: child, in: state)
        }
    }

    static func extensions(existing: ExtensionRegistry, window: @escaping @MainActor () -> DocumentWindowController?) -> [ExtensionDescriptor] {
        guard var descriptor = existing.descriptor(for: emptyBlocksID) else { return [] }
        descriptor.validate = { window() == nil ? .disabled("Open a document") : .enabled }
        descriptor.run = { _ in
            if let window = window() { deleteEmptyBlocks(in: window) }
            return nil
        }
        return [descriptor]
    }

    @discardableResult
    static func deleteEmptyBlocks(in window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = emptyBlocks(window.documentHandle)
        guard !nodes.isEmpty else { return nil }
        return window.objectEditing.perform(CommandBatch("Delete Empty Text Blocks", [DeleteNodes(nodes)]))
    }

    /// Watches `window`'s selection: an empty auto-expanding block that leaves it is deleted.
    static func watchDeselection(_ window: DocumentWindowController) -> SelectionModel.ObservationToken {
        var previous = window.selection.selection
        return window.selection.model.observe { [weak window] selection in
            defer { previous = selection }
            guard let window else { return }
            let left = Set(previous.ids.map(\.opID)).subtracting(selection.ids.map(\.opID))
            deleteIfEmpty(Array(left), in: window)
        }
    }

    /// Deletes the empty auto-expanding blocks among `nodes` (one change), unless the Text tool
    /// or a Text Editor is on one.
    @discardableResult
    static func deleteIfEmpty(_ nodes: [OpID], in window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let document = window.documentHandle
        let empty = Set(emptyBlocks(document))
        let state = document.state
        let editing = window.objectEditing.textSession?.node
        let doomed = nodes.filter { node in
            guard empty.contains(node), node != editing, let block = state.textNode(node)?.props.block else { return false }
            return block.autoWidth || block.autoHeight
        }
        guard !doomed.isEmpty else { return nil }
        return window.objectEditing.perform(DeleteNodes(doomed))
    }
}

fileprivate extension Double {
    /// Rounded to `places` decimals.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
