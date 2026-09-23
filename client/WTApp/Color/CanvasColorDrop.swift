import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Colours dropped on the canvas (applying-color.adoc, "Applying color to unselected objects";
/// COLOR-011): the object under the pointer highlights as a colour passes over its fill or its
/// stroke, and the drop colours that paint -- kbd:[Shift] the fill whatever is under the pointer,
/// kbd:[Cmd] the stroke.  A group takes the colour on every object in it; kbd:[Option] colours only
/// the member under the pointer.  Dropping on empty pasteboard does nothing.  The drop is one
/// change (`ApplyColor`); a swatch dragged from another document is created here first
/// (`ColorDrop`).
@MainActor
final class CanvasColorDrop {
    /// What a drop at the pointer colours.
    struct Target: Equatable {
        let node: OpID
        let target: ColorTarget
        /// The object's bounds, pasteboard space (the highlight).
        let bounds: Rect
    }

    let document: DocumentHandle
    let selection: SelectionController
    /// *Default color space for new colors*, for a plain `NSColor` from another application.
    var defaultSpace: @MainActor () -> RenderColor.Space = { .displayP3 }
    /// The target under the drag, highlighted on the canvas.
    private(set) var highlight: Target?

    init(document: DocumentHandle, selection: SelectionController) {
        self.document = document
        self.selection = selection
    }

    /// Which paint a drop on `kind` colours: kbd:[Shift] the fill, kbd:[Cmd] the stroke, else the
    /// part under the pointer (a stroke or a path's own line colours the stroke; a fill, text or
    /// an image the fill).
    static func paint(for kind: HitKind, modifiers: KeyModifiers) -> ColorTarget {
        if modifiers.contains(.shift) { return .fill }
        if modifiers.contains(.command) { return .stroke }
        switch kind {
        case .stroke, .segment, .point, .handle: return .stroke
        case .fill, .text, .image: return .fill
        }
    }

    /// The object and paint under `viewPoint`: the top-level object, or with kbd:[Option] the
    /// member of a group that was hit.  Nil over empty pasteboard.
    func target(at viewPoint: Point, viewport: Viewport, modifiers: KeyModifiers) -> Target? {
        let hits = selection.hitTester(viewport: viewport, subselect: modifiers.contains(.option)).hitTest(viewPoint: viewPoint)
        for hit in hits {
            guard let id = document.selectionID(atItemPath: hit.itemPath), let bounds = document.object(for: id)?.bounds else { continue }
            return Target(node: id.opID, target: Self.paint(for: hit.kind, modifiers: modifiers), bounds: bounds)
        }
        return nil
    }

    /// The drag moved to `viewPoint`: the highlight follows.  Whether a drop here would colour
    /// something (the pasteboard carries a colour and an object is under the pointer).
    @discardableResult
    func update(_ pasteboard: NSPasteboard, at viewPoint: Point, viewport: Viewport, modifiers: KeyModifiers) -> Bool {
        highlight = ColorDrag.read(from: pasteboard, defaultSpace: defaultSpace()) == nil ? nil : target(at: viewPoint, viewport: viewport, modifiers: modifiers)
        return highlight != nil
    }

    /// The drag left the canvas or ended.
    func exit() {
        highlight = nil
    }

    /// The drop at `viewPoint`: the colour applied to the target as one change.  Nil when the
    /// pasteboard carries no colour or nothing is under the pointer.
    @discardableResult
    func drop(_ pasteboard: NSPasteboard, at viewPoint: Point, viewport: Viewport, modifiers: KeyModifiers) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        defer { highlight = nil }
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: defaultSpace()),
              let target = target(at: viewPoint, viewport: viewport, modifiers: modifiers) else { return nil }
        let document = document
        return Task { @MainActor in
            let ref = await ColorDrop.reference(for: payload, in: document)
            return await document.perform(ApplyColor([target.node], target: target.target, color: ref, name: payload.name)).value
        }
    }

    /// The highlight: the target's bounds outlined, a solid line for a fill and a dashed one
    /// for a stroke.
    func drawHighlight(in ctx: CGContext, viewport: Viewport) {
        guard let highlight else { return }
        let b = highlight.bounds
        let corners = [Point(x: b.minX, y: b.minY), Point(x: b.maxX, y: b.minY), Point(x: b.maxX, y: b.maxY), Point(x: b.minX, y: b.maxY)]
            .map { viewport.toView($0).cgPoint }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        if highlight.target == .stroke { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
        ctx.restoreGState()
    }
}
