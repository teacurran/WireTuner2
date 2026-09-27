import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// What a canvas draws between the document's tiles and the selection (grid-guides.adoc,
/// "Client"; pages.adoc, "Rendering"): the grid's dots, the ruler guides of every page (a child's
/// master's included, clipped to the bleed rectangle), the active page's emphasis, the dots of
/// collaborators viewing each page, and a guide being dragged.  All of it is pasteboard geometry
/// drawn through the view transform, so a rotated canvas turns it with the pages; none of it is in
/// the document's display list, so showing the grid or choosing another page repaints no tile.
@MainActor
final class CanvasFurniture {
    /// The colours: the *Grid color* and *Guide color* preferences.
    struct Style: Equatable {
        var grid = Color(white: 0.8)
        var guide = Color(red: 0, green: 1, blue: 1)
        var activePage = PageStyle().activeOutlineColor
    }

    let document: DocumentHandle
    /// menu:View[Grid > Show] (`view` table, per document).
    var showsGrid = false
    /// menu:View[Guides > Show].
    var showsGuides = true
    var style: @MainActor () -> Style = { Style() }
    /// The collaborators, for the page dots.
    var participants: @MainActor () -> [RemoteParticipant] = { [] }
    /// The guide being dragged (from the canvas or out of a ruler), drawn while it moves.
    var drag: GuideDrag?
    /// Redraws the layer the furniture is drawn in.
    var setNeedsDisplay: @MainActor () -> Void = {}

    init(document: DocumentHandle) {
        self.document = document
    }

    // MARK: Drawing

    /// Draws everything in view points (y down) for `viewport`.
    func draw(in ctx: CGContext, viewport: Viewport) {
        let pages = document.pageList
        let toView = viewport.pasteboardToView
        if showsGrid { drawGrid(pages, in: ctx, viewport: viewport) }
        if showsGuides {
            ctx.setStrokeColor(style().guide.cgColor)
            ctx.setLineWidth(1)
            for page in pages.pages where page.bleedRect.intersects(viewport.visiblePasteboardBounds) {
                let hidden = drag?.hides ?? []
                for guide in pages.guides(on: page) where hidden.isDisjoint(with: guide.ids) {
                    stroke(Self.line(guide, on: page), toView: toView, in: ctx)
                }
            }
        }
        if let drag, let line = drag.previewLine(in: pages) {
            ctx.setStrokeColor(style().guide.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 2])
            stroke(line, toView: toView, in: ctx)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if pages.pages.count > 1 {
            let active = document.activePage
            let path = CGMutablePath()
            SelectionOverlay.add(DisplayPath(rect: active.rect), transform: toView, to: path)
            ctx.addPath(path)
            ctx.setStrokeColor(style().activePage.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
        drawPresence(pages, in: ctx, toView: toView)
    }

    /// The grid dots in the visible area (`GridRendering`: thinned below 4 px spacing), from the
    /// active page's zero point.
    func drawGrid(_ pages: PageList, in ctx: CGContext, viewport: Viewport) {
        guard let item = GridRendering.item(GlyphCanvasUnits.grid(of: document), in: viewport.visiblePasteboardBounds, zoom: viewport.zoom,
                                            color: style().grid),
              case .fill(let fill) = item else { return }
        let path = CGMutablePath()
        SelectionOverlay.add(fill.path, transform: viewport.pasteboardToView, to: path)
        ctx.addPath(path)
        ctx.setFillColor(style().grid.cgColor)
        ctx.fillPath()
    }

    /// A dot at the top-left corner of the page each collaborator's view is mostly on.
    func drawPresence(_ pages: PageList, in ctx: CGContext, toView: WTGeometry.AffineTransform) {
        var seen: [OpID: Int] = [:]
        for participant in participants() {
            guard let page = Self.page(of: participant, in: pages) else { continue }
            let index = seen[page.id, default: 0]
            seen[page.id] = index + 1
            let corner = toView.apply(page.rect.origin)
            ctx.setFillColor(PresencePalette.color(at: participant.colorIndex).cgColor)
            ctx.fillEllipse(in: CGRect(x: corner.x + 3 + Double(index) * 9, y: corner.y + 3, width: 7, height: 7))
        }
    }

    /// The page a collaborator is on: the page their presence names, else the one under the
    /// centre of their view.
    nonisolated static func page(of participant: RemoteParticipant, in pages: PageList) -> Page? {
        if let id = participant.page?.opID, let page = pages[id] { return page }
        return participant.viewport.flatMap { visible in pages.page(containing: visible.center) }
    }

    private func stroke(_ line: (Point, Point), toView: WTGeometry.AffineTransform, in ctx: CGContext) {
        ctx.move(to: toView.apply(line.0).cgPoint)
        ctx.addLine(to: toView.apply(line.1).cgPoint)
        ctx.strokePath()
    }

    /// `guide` on `page` as a segment across the page's bleed rectangle (pasteboard space).
    nonisolated static func line(_ guide: PageGuide, on page: Page) -> (Point, Point) {
        let bleed = page.bleedRect
        switch guide.axis {
        case .horizontal:
            let y = page.origin.y + guide.position
            return (Point(x: bleed.minX, y: y), Point(x: bleed.maxX, y: y))
        case .vertical:
            let x = page.origin.x + guide.position
            return (Point(x: x, y: bleed.minY), Point(x: x, y: bleed.maxY))
        }
    }

    // MARK: Hit testing

    /// The page's own guide within `tolerance` view points of `viewPoint` (a master's guides
    /// show on its children but are edited on the master): the nearest, with its page.
    func guide(at viewPoint: Point, viewport: Viewport, tolerance: Double) -> (page: Page, guide: PageGuide)? {
        guard showsGuides else { return nil }
        let point = viewport.toPasteboard(viewPoint)
        let reach = tolerance / max(viewport.zoom, 1e-9)
        var best: (page: Page, guide: PageGuide, distance: Double)?
        for page in document.pageList.pages where page.bleedRect.insetBy(dx: -reach, dy: -reach).contains(point) {
            for guide in page.guides {
                let distance = guide.axis == .horizontal ? abs(point.y - page.origin.y - guide.position) : abs(point.x - page.origin.x - guide.position)
                if distance <= reach, distance < (best?.distance ?? .infinity) { best = (page, guide, distance) }
            }
        }
        return best.map { ($0.page, $0.guide) }
    }
}

/// A guide being dragged (grid-guides.adoc, "Adding guides by dragging", "Moving and removing
/// guides"): an existing guide moved with the Pointer tool, or a new one out of a ruler.  The
/// drag writes nothing until it ends; then it is one change.
struct GuideDrag: Equatable {
    enum Source: Equatable {
        /// A guide of `page` (every coincident element its row holds).
        case guide(page: OpID, ids: [OpID])
        /// A new guide out of the top ruler (horizontal) or the left ruler (vertical).
        case ruler
    }

    var source: Source
    var axis: PageGuide.Axis
    /// The pointer, pasteboard space.
    var point: Point
    /// kbd:[Shift]: the position snaps to the grid.
    var snapsToGrid = false
    /// kbd:[Option] from a ruler: the pages the pointer has crossed, in the order crossed.
    var crossed: [OpID] = []

    /// The elements the drag hides while it moves them.
    var hides: Set<OpID> {
        if case .guide(_, let ids) = source { return Set(ids) }
        return []
    }

    /// The page the guide belongs to: its own page, or the page under the pointer for a new one.
    func page(in pages: PageList) -> Page? {
        switch source {
        case .guide(let page, _): pages[page]
        case .ruler: pages.page(containing: point)
        }
    }

    /// The guide's position along its axis in pasteboard space, snapped to `pages`' grid (from
    /// the page's zero point) with kbd:[Shift].
    func position(in pages: PageList) -> Double {
        let raw = axis == .horizontal ? point.y : point.x
        guard snapsToGrid else { return raw }
        let grid = pages.grid(on: page(in: pages))
        let origin = axis == .horizontal ? grid.origin.y : grid.origin.x
        return origin + ((raw - origin) / grid.size).rounded() * grid.size
    }

    /// The preview across the page it would land on, or across the view's page when over the
    /// pasteboard (a drop there removes or cancels it).
    func previewLine(in pages: PageList) -> (Point, Point)? {
        guard let page = page(in: pages) else { return nil }
        let origin = axis == .horizontal ? page.origin.y : page.origin.x
        return CanvasFurniture.line(PageGuide(ids: [], axis: axis, position: position(in: pages) - origin), on: page)
    }

    /// The drag moved to `point`: kbd:[Option] from a ruler remembers the page it crossed.
    mutating func move(to point: Point, modifiers: KeyModifiers, pages: PageList) {
        self.point = point
        snapsToGrid = modifiers.contains(.shift)
        if case .ruler = source, modifiers.contains(.option), let page = pages.page(containing: point), !crossed.contains(page.id) {
            crossed.append(page.id)
        }
    }

    /// What releasing at the current point does: a moved guide (over its page) or a deleted one
    /// (over the pasteboard); a new guide on the page under the pointer -- with kbd:[Option] on
    /// every page crossed, at the same offset from each page's top-left corner -- or nothing over
    /// the pasteboard.
    func command(in pages: PageList, option: Bool) -> (any WTModel.Command)? {
        switch source {
        case .guide(let id, let ids):
            guard let page = pages[id] else { return nil }
            guard page.bleedRect.contains(point) else { return DeleteGuides(on: id, ids) }
            let origin = axis == .horizontal ? page.origin.y : page.origin.x
            return MoveGuide(on: id, ids, to: position(in: pages) - origin)
        case .ruler:
            guard let page = pages.page(containing: point) else { return nil }
            let origin = axis == .horizontal ? page.origin.y : page.origin.x
            let targets = option ? (crossed.contains(page.id) ? crossed : crossed + [page.id]) : [page.id]
            return AddGuides(on: targets, axis: axis, at: [position(in: pages) - origin])
        }
    }

    /// The position shown while dragging: from the page's zero point, in the document's unit.
    func readout(in pages: PageList, units: Units) -> String? {
        guard let page = page(in: pages) else { return nil }
        let position = position(in: pages)
        let value = axis == .horizontal ? page.zeroPoint.y - position : position - page.zeroPoint.x
        return units.format(value, suffix: true)
    }
}

/// Guide dragging with the Pointer and Subselect tools, pressed before the tool (a
/// `CanvasHandleLayer`): a press on a page's guide starts a drag unless the guides are locked;
/// releasing over the page moves it, over the pasteboard deletes it (grid-guides.adoc).  A
/// double-click opens the Guides sheet.  A guide someone else removes mid-drag ends the drag with
/// a message.
@MainActor
final class GuideHandles: CanvasHandleLayer {
    let furniture: CanvasFurniture
    /// Opens the Guides sheet on the page (a double-click on a guide).
    var editGuides: @MainActor (OpID) -> Void = { _ in }
    /// The last guide clicked: kbd:[Delete] removes it while nothing else is selected.
    private(set) var selected: (page: OpID, ids: [OpID])?

    init(furniture: CanvasFurniture) {
        self.furniture = furniture
    }

    static let lockedMessage = "Guides are locked; unlock them with View > Guides > Lock"
    static let removedMessage = "The guide you were dragging was removed by someone else"

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let hit = furniture.guide(at: e.viewPoint, viewport: context.viewport, tolerance: context.snapping.pickDistance()) else {
            selected = nil
            return false
        }
        selected = (hit.page.id, hit.guide.ids)
        if e.clickCount >= 2 {
            editGuides(hit.page.id)
            return true
        }
        guard !furniture.document.settings.guidesLocked else {
            context.host.showStatusMessage(Self.lockedMessage)
            return true
        }
        furniture.drag = GuideDrag(source: .guide(page: hit.page.id, ids: hit.guide.ids), axis: hit.guide.axis, point: e.pasteboardPoint)
        furniture.setNeedsDisplay()
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard var drag = furniture.drag else { return }
        guard stillExists(drag) else {
            end(context, message: Self.removedMessage)
            return
        }
        drag.move(to: e.pasteboardPoint, modifiers: e.modifiers, pages: furniture.document.pageList)
        furniture.drag = drag
        if let readout = drag.readout(in: furniture.document.pageList, units: furniture.document.unitConverter) {
            context.host.showStatusMessage(readout)
        }
        furniture.setNeedsDisplay()
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        guard var drag = furniture.drag else { return }
        guard stillExists(drag) else {
            end(context, message: Self.removedMessage)
            return
        }
        drag.move(to: e.pasteboardPoint, modifiers: e.modifiers, pages: furniture.document.pageList)
        if let command = drag.command(in: furniture.document.pageList, option: false) { context.commandSink.perform(command) }
        end(context, message: nil)
    }

    func cancel(context: ToolContext) {
        end(context, message: nil)
    }

    /// Guides are drawn by the furniture layer; nothing here.
    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {}

    /// kbd:[Delete] on the clicked guide: "Delete guide"; nil when no guide is selected or the
    /// guides are locked.
    func deletionCommand() -> DeleteGuides? {
        guard let selected, !furniture.document.settings.guidesLocked,
              let page = furniture.document.pageList[selected.page],
              let guide = page.guides.first(where: { !Set($0.ids).isDisjoint(with: selected.ids) }) else { return nil }
        return DeleteGuides(on: page.id, guide.ids)
    }

    func deselect() { selected = nil }

    private func stillExists(_ drag: GuideDrag) -> Bool {
        guard case .guide(let id, let ids) = drag.source else { return true }
        return furniture.document.pageList[id]?.guides.contains { !Set($0.ids).isDisjoint(with: ids) } ?? false
    }

    private func end(_ context: ToolContext, message: String?) {
        furniture.drag = nil
        furniture.setNeedsDisplay()
        if let message { context.host.showStatusMessage(message) }
    }
}

extension PreferenceColor {
    /// The colour for drawing.
    var color: Color { Color(red: red, green: green, blue: blue, alpha: alpha) }
}
