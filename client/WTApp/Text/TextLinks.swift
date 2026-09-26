import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Linking text blocks on the canvas (text-blocks.adoc, "Linking text blocks"; TYPE-007): a drag
/// from a selected block's link box onto an empty text block or a path links the block's overflow
/// there (`LinkTextBlocks`); the same drag from a linked block onto an empty spot breaks its link
/// (`UnlinkTextBlocks`), onto another block relinks.  While a linked block is selected a thin link
/// line runs from each block of its chain's link box to the next block's top-left corner.
@MainActor
final class TextLinkDrag {
    static let invalidTarget = "Link to an empty text block or a path"
    /// How far (view points) the pointer must move before a press on the link box is a drag.
    static let threshold = 3.0

    /// The drag in progress: the block and where the pointer is (pasteboard).
    private(set) var dragging: (frame: TextBlockFrame, start: Point, point: Point)?

    func begin(_ frame: TextBlockFrame, at e: CanvasEvent) {
        dragging = (frame, e.viewPoint, e.pasteboardPoint)
    }

    func move(_ e: CanvasEvent, context: ToolContext) {
        guard dragging != nil else { return }
        dragging?.point = e.pasteboardPoint
        context.host.setNeedsOverlayDisplay()
    }

    func cancel() { dragging = nil }

    /// Ends the drag: links, relinks or unlinks; nothing when the pointer barely moved.
    @discardableResult
    func end(_ e: CanvasEvent, context: ToolContext) -> (any WTModel.Command)? {
        defer { dragging = nil }
        guard let dragging, dragging.start.distance(to: e.viewPoint) >= Self.threshold else { return nil }
        let state = context.document.state
        let source = dragging.frame.node
        let command: (any WTModel.Command)?
        if let target = Self.target(at: e, excluding: source, context: context) {
            guard LinkTextBlocks.canLink(from: source, to: target, in: state) else {
                context.host.showStatusMessage(Self.invalidTarget)
                return nil
            }
            command = LinkTextBlocks(from: source, to: target)
        } else {
            command = UnlinkTextBlocks.canUnlink(source, in: state) ? UnlinkTextBlocks(source) : nil
        }
        if let command { context.commandSink.perform(command) }
        return command
    }

    /// What the pointer is over: the top-most text block whose frame holds the point (an empty
    /// block draws nothing to hit), else the top-most path; nil over an empty spot.
    static func target(at e: CanvasEvent, excluding source: OpID, context: ToolContext) -> OpID? {
        let document = context.document
        let blocks = TextBlockFeatures.textNodes(under: WellKnown.layers, in: document.state).reversed()
        for node in blocks where node != source {
            guard let frame = TextBlockFrame(node, document: document) else { continue }
            if frame.local.contains(frame.toLocal(e.pasteboardPoint)) { return node }
        }
        guard let hit = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: true)?.id.opID,
              hit != source else { return nil }
        return hit
    }

    // MARK: Drawing

    /// The link lines of the chains of `frames` and the line of a drag in progress, in view points.
    func draw(_ frames: [TextBlockFrame], in ctx: CGContext, viewport: Viewport, document: DocumentHandle) {
        var drawn: Set<OpID> = []
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        for frame in frames where TextChains.isLinked(frame.node, in: document.state) {
            let chain = TextChains.chain(of: frame.node, in: document.state)
            guard drawn.insert(chain[0]).inserted else { continue }
            for (from, to) in zip(chain, chain.dropFirst()) {
                guard let start = TextLinkDrag.anchor(from, document: document, viewport: viewport),
                      let end = TextLinkDrag.entry(to, document: document, viewport: viewport) else { continue }
                ctx.move(to: CGPoint(x: start.x, y: start.y))
                ctx.addLine(to: CGPoint(x: end.x, y: end.y))
            }
        }
        ctx.strokePath()
        if let dragging {
            let start = viewport.toView(dragging.frame.transform.apply(dragging.frame.linkBoxCenter(zoom: viewport.zoom)))
            let end = viewport.toView(dragging.point)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: start.x, y: start.y))
            ctx.addLine(to: CGPoint(x: end.x, y: end.y))
            ctx.strokePath()
        }
    }

    /// Where a link line leaves `node`: its link box (view points).
    static func anchor(_ node: OpID, document: DocumentHandle, viewport: Viewport) -> Point? {
        TextBlockFrame(node, document: document).map { viewport.toView($0.transform.apply($0.linkBoxCenter(zoom: viewport.zoom))) }
    }

    /// Where a link line reaches `node`: its top-left corner, or for text in a path the path's
    /// first point (view points).
    static func entry(_ node: OpID, document: DocumentHandle, viewport: Viewport) -> Point? {
        if let frame = TextBlockFrame(node, document: document) { return viewport.toView(frame.point(.topLeft)) }
        let state = document.state
        guard let text = TextNode(node, in: state), let path = TextLayoutReading.path(of: text, in: state),
              let start = Objects.localPath(path, in: state)?.contours.first?.points.first?.anchor else { return nil }
        return viewport.toView(Objects.pasteboardTransform(of: path, in: state).apply(start))
    }
}
