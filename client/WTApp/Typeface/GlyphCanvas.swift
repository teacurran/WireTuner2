import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

// A glyph canvas (typeface-documents.adoc, "Client"; FONT-003, FONT-011): a document handle whose
// builder draws the glyph's objects (`canvasNode`), whose background is the glyph's metric lines
// and em box (`GlyphCanvasRendering`) and whose commands put what they create on the glyph.

/// A command performed on a glyph canvas: the command, then `CommonProps.canvas` = the glyph on
/// every top-level object it created, in the same change (so undo removes both at once).
struct CanvasPlacedCommand: WTModel.Command {
    let base: any WTModel.Command
    let canvas: OpID

    var label: String { base.label }
    var coalescing: UndoCoalescing { base.coalescing }
    var recordsUndo: Bool { base.recordsUndo }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let start = builder.ops.count
        try base.execute(&builder, state: state)
        var counter = builder.startCounter
        var created: [(id: OpID, kind: NodeKind, props: Wiretuner_Doc_V1_NodeProps)] = []
        // Layers the change itself creates (the first object of an empty document makes one).
        var layers: Set<OpID> = []
        for (index, op) in builder.ops.enumerated() {
            let id = OpID(counter: counter, replica: builder.replica)
            if case .create(let create) = op.op {
                if case .layer? = create.props.kind { layers.insert(id) }
                let parent = OpID(create.parent)
                if index >= start, layers.contains(parent) || state.nodeKind(parent) == .layer,
                   let value = GlyphCanvas.canvasValue(create.props, canvas: canvas) {
                    created.append((id, value.kind, value.props))
                }
            }
            counter &+= EngineState.counters(op)
        }
        for (id, kind, props) in created {
            builder.append(Ops.set(id, [RegisterPath([kind.rawValue, 1, 5])], values: props))
        }
    }
}

enum GlyphCanvas {
    /// `command` as performed on `canvas` (unchanged on the pasteboard).
    static func placing(_ command: any WTModel.Command, on canvas: OpID?) -> any WTModel.Command {
        guard let canvas, !(command is CanvasPlacedCommand) else { return command }
        return CanvasPlacedCommand(base: command, canvas: canvas)
    }

    /// Props of the same kind as `props` holding only `CommonProps.canvas` = `canvas`; nil for a
    /// kind a glyph cannot hold.
    static func canvasValue(_ props: Wiretuner_Doc_V1_NodeProps, canvas: OpID) -> (kind: NodeKind, props: Wiretuner_Doc_V1_NodeProps)? {
        var common = Wiretuner_Doc_V1_CommonProps()
        common.canvas.id = canvas.proto
        var value = Wiretuner_Doc_V1_NodeProps()
        switch props.kind {
        case .path?: value.path.common = common
        case .rect?: value.rect.common = common
        case .ellipse?: value.ellipse.common = common
        case .polygon?: value.polygon.common = common
        case .group?: value.group.common = common
        case .text?: value.text.common = common
        default: return nil
        }
        return (kind(of: value), value)
    }

    /// The node kind of props `canvasValue` made (each kind's message sits at its kind's number).
    private static func kind(of props: Wiretuner_Doc_V1_NodeProps) -> NodeKind {
        switch props.kind {
        case .path?: .path
        case .rect?: .rect
        case .ellipse?: .ellipse
        case .polygon?: .polygon
        case .group?: .group
        default: .text
        }
    }

    // MARK: Decoration

    /// The decoration of `glyph`'s canvas from the font's metrics and guide settings; nil when the
    /// glyph is not live.
    static func frame(for glyph: OpID, in state: EngineState) -> GlyphCanvasFrame? {
        guard state.isLive(glyph), let props = GlyphIndex(state)[glyph] else { return nil }
        let font = WTModel.FontInfo(state)
        let metrics = font.metrics
        let guides = font.guides
        var frame = GlyphCanvasFrame(
            advanceWidth: props.advanceWidth, unitsPerEm: Double(metrics.upm), ascender: metrics.ascender, descender: metrics.descender,
            xHeight: metrics.xHeight, capHeight: metrics.capHeight, italicAngle: metrics.italicAngle,
            extraLines: guides.extraLines.map { GlyphMetricLine(role: .extra, label: $0.name, y: $0.y) }
        )
        apply(guides, to: &frame)
        return frame
    }

    /// The Guides pane's switches and colours on `frame`.
    static func apply(_ guides: WTModel.FontInfo.Guides, to frame: inout GlyphCanvasFrame) {
        frame.showBaseline = guides.showBaseline
        frame.showXHeight = guides.showXHeight
        frame.showCapHeight = guides.showCapHeight
        frame.showAscender = guides.showAscender
        frame.showDescender = guides.showDescender
        frame.showSideBearings = guides.showSideBearings
        frame.showEmBox = guides.showEmBox
        frame.baselineColor = guides.baselineColor ?? frame.baselineColor
        frame.metricColor = guides.metricColor ?? frame.metricColor
        frame.bearingColor = guides.bearingColor ?? frame.bearingColor
    }

    /// Where a glyph canvas scrolls: an em beyond the advance on either side, half an em above
    /// the ascender and below the descender (stored space, y down).
    static func scrollBounds(_ frame: GlyphCanvasFrame) -> Rect {
        let (minX, maxX) = frame.extent
        let margin = frame.unitsPerEm / 2
        let top = -max(frame.ascender, frame.unitsPerEm) - margin
        let bottom = -min(frame.descender, 0) + margin
        return Rect(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    /// The glyph's em box: advance wide, descender to ascender (Fit Glyph).
    static func emBox(_ frame: GlyphCanvasFrame) -> Rect {
        Rect(x: 0, y: -frame.ascender, width: max(frame.advanceWidth, frame.unitsPerEm / 4), height: frame.ascender - frame.descender)
    }

    /// The canvas background of `glyph`: a white ground over the scroll area, then the metric
    /// lines, side bearings and em box; nothing once the glyph is gone.
    static func background(of glyph: OpID, in state: EngineState) -> [DisplayItem] {
        guard let frame = frame(for: glyph, in: state) else { return [] }
        let ground = DisplayItem.fill(FillItem(path: DisplayPath(rect: scrollBounds(frame)), paint: .solid(Color(white: 1))))
        return [.group(GroupItem(children: [ground] + GlyphCanvasRendering.items(frame)))]
    }

    /// A handle drawing live `glyph`'s canvas over `document`'s model (open, since the glyph was
    /// read from it).
    @MainActor
    static func handle(for glyph: Glyph, of document: DocumentHandle) -> DocumentHandle {
        let handle = DocumentHandle(id: tabID(document: document.id, glyph: glyph.id), title: glyph.name,
                                    replicaID: document.replicaID, model: document.model!, canvasNode: glyph.id)
        let glyph = glyph.id
        handle.canvasBackground = { state in background(of: glyph, in: state) }
        handle.refreshBackground()
        return handle
    }

    /// The id a glyph tab's handle goes by: its document's, the glyph's.
    static func tabID(document: String, glyph: OpID) -> String { "\(document)#glyph-\(glyph)" }

    /// The document id a glyph tab's (or a master tab's, `MasterCanvas`) handle id names.
    static func documentID(ofTab id: String) -> String {
        (id.range(of: "#glyph-") ?? id.range(of: MasterCanvas.marker)).map { String(id[..<$0.lowerBound]) } ?? id
    }
}

extension DocumentHandle {
    /// The metric lines and side bearings of a glyph canvas as snap targets (*Snap to metric
    /// lines*); none on the pasteboard.
    var canvasSnapGuides: [SnapGuide] {
        guard let canvasNode, let frame = GlyphCanvas.frame(for: canvasNode, in: state) else { return [] }
        return GlyphCanvasRendering.snapGuides(frame)
    }
}
