import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Graphic Hose tool (graphic-hose.adoc, "Spraying"; DRAW-039): the press places the first
/// object and the drag feeds `HoseSprayer` its samples, which places the next objects by the set's
/// order, spacing (speed-dependent unless on a grid), scale and rotation; kbd:[Left] / kbd:[Right]
/// tighten or loosen the spacing and kbd:[Up] / kbd:[Down] shrink or enlarge the objects for the
/// rest of the stroke.  The placements are previewed in the overlay (`HosePreview`) and written on
/// mouse-up in one undo group: a library hose the document has no copy of is copied in first
/// (`ImportHoseSet`), then the stroke (`SprayHose.strokes`, split at the op limit); the sprayed
/// objects are selected as a set.  kbd:[Esc] abandons the stroke.
@MainActor
final class GraphicHoseTool: Tool {
    static let id: ToolID = "graphicHose"
    static let status = "Drag to spray; click to place one object; arrow keys change spacing and size"

    let model: GraphicHoseModel
    private(set) var context: ToolContext?
    /// The stroke in progress.
    private(set) var sprayer: HoseSprayer?
    private(set) var source: GraphicHoseModel.Source?
    /// The last stroke's writing (tests await it).
    private(set) var writing: Task<Void, Never>?

    init(model: GraphicHoseModel) {
        self.model = model
    }

    var cursor: NSCursor { .crosshair }
    var hasSomethingToCancel: Bool { sprayer != nil }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.status)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        cancel()
        switch model.source() {
        case .failure(let error):
            context?.host.showHUD(error.message)
        case .success(let source):
            self.source = source
            var sprayer = HoseSprayer(options: source.set.options, objectCount: source.set.objects.count,
                                      extent: HoseSets.extent(of: source.set, in: source.state), seed: model.seed())
            sprayer.begin(at: e.pasteboardPoint, time: e.timestamp)
            self.sprayer = sprayer
            context?.host.setNeedsOverlayDisplay()
        }
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard sprayer != nil else { return }
        sprayer?.drag(to: e.pasteboardPoint, time: e.timestamp)
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let sprayer, let source, !sprayer.placements.isEmpty else { return }
        writing = Self.spray(sprayer.placements, from: source, layer: context.objectEditing?.activeLayer, document: context.document,
                             sink: context.commandSink, selection: context.selection)
    }

    /// Writes a stroke: the library copy (when needed) and the spray, in one undo group, then
    /// selects what was sprayed.
    static func spray(_ placements: [HosePlacement], from source: GraphicHoseModel.Source, layer: OpID?, document: DocumentHandle,
                      sink: any CommandSink, selection: SelectionController) -> Task<Void, Never> {
        document.beginGroup()
        // The copy is part of the stroke's undo step and carries its label, so the step reads as the spray.
        let label = SprayHose(source.set.id, placements: placements).label
        let copying = source.bundle.map { sink.perform(CommandBatch(label, [ImportHoseSet($0)])) }
        return Task { @MainActor in
            defer { document.endGroup() }
            _ = await copying?.value
            let state = document.state
            let set: OpID? = if let id = source.bundle?.libraryID { HoseSets.set(libraryID: id, in: state)?.id } else { source.set.id }
            guard let set, let strokes = try? SprayHose.strokes(set, placements: placements, layer: layer, in: state) else { return }
            var created: [OpID] = []
            for stroke in strokes {
                created += await sink.perform(stroke).value?.createdRoots ?? []
            }
            if !created.isEmpty { selection.model.set(Selection(created.map { SelectionID($0) })) }
        }
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// The arrow keys while spraying.
    func keyDown(_ e: NSEvent) -> Bool {
        guard sprayer != nil else { return false }
        switch e.keyCode {
        case 123: sprayer?.tighten()
        case 124: sprayer?.loosen()
        case 126: sprayer?.shrink()
        case 125: sprayer?.enlarge()
        default: return false
        }
        return true
    }

    /// The stroke's objects so far, half transparent.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let sprayer, let source else { return }
        let items = HosePreview.items(source.set, placements: sprayer.placements, in: source.state)
        ctx.saveGState()
        ctx.setAlpha(0.6)
        CoreGraphicsRenderer(background: nil).render(DisplayList(canvas: "hose-preview", items: items), viewport: viewport, into: ctx)
        ctx.restoreGState()
    }

    func cancel() {
        sprayer = nil
        source = nil
        context?.host.setNeedsOverlayDisplay()
    }
}
