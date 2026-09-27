import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The document window's share of the DOC epic (DOC-008, DOC-014, DOC-018): the canvas
/// furniture (grid, guides, page emphasis), guide dragging on the canvas and out of the rulers,
/// the zero-point marker, the rulers' frame of reference, snapping sources, the two active-page
/// preferences, and the Grid, Guides and Units sheets.
extension DocumentWindowController {
    /// The preferences that change how the furniture draws.
    static let furniturePreferences: Set<String> = [PreferenceCatalog.Colors.gridColor.id, PreferenceCatalog.Colors.guideColor.id]

    /// Wires the furniture, rulers and preferences once the tool manager exists.
    func installDocumentSetup(manager: ToolManager) {
        let preferences = environment.preferences
        manager.handleLayers.append(guideHandles)
        furniture.style = {
            CanvasFurniture.Style(grid: preferences[PreferenceCatalog.Colors.gridColor].color, guide: preferences[PreferenceCatalog.Colors.guideColor].color)
        }
        furniture.participants = { [weak self] in self?.presence.participants ?? [] }
        furniture.setNeedsDisplay = { [weak canvas] in canvas?.setNeedsFurnitureDisplay() }
        canvas.furnitureDrawer = { [weak self] ctx in self?.drawFurniture(in: ctx) }
        guideHandles.editGuides = { [weak self] page in self?.presentGuidesSheet(page: page) }
        rulerHost.horizontalRuler.onDrag = { [weak self] phase, point, modifiers in self?.rulerDrag(.horizontal, phase, at: point, modifiers: modifiers) }
        rulerHost.verticalRuler.onDrag = { [weak self] phase, point, modifiers in self?.rulerDrag(.vertical, phase, at: point, modifiers: modifiers) }
        rulerHost.corner.onDrag = { [weak self] phase, point, modifiers in self?.zeroPointDragged(phase, at: point, modifiers: modifiers) }
        rulerHost.corner.onReset = { [weak self] in _ = self?.resetZeroPoint() }
        canvas.onPressAt = { [weak self] point in self?.toolPressed(at: point) }
        documentHandle.observePages { [weak self] change in self?.pagesChanged(change) }
        collaboration.banner.onAction = { [weak self] id in self?.performNotice(id) }
        collaboration.banner.onDismissAction = { [weak self] id in self?.dismissNotice(id) }
    }

    // MARK: Page notices

    /// The pages changed: someone else's change may have undone this person's (a notice).
    func pagesChanged(_ change: PageListChange) {
        let author = change.change.flatMap { collaboration.session?.author(of: $0.replica)?.name } ?? "Someone"
        guard pageNotices.pagesChanged(change, author: author, units: documentHandle.unitConverter, state: documentHandle.state) else { return }
        showNotices()
    }

    func showNotices() {
        collaboration.banner.actions = pageNotices.notices.map { BannerAction(id: $0.id, text: $0.text, button: $0.action) }
        bannerDidChange()
    }

    /// A notice's button: its command (one change), and the notice goes.
    func performNotice(_ id: UUID) {
        if let notice = pageNotices.notices.first(where: { $0.id == id }) { objectEditing.perform(notice.command) }
        dismissNotice(id)
    }

    func dismissNotice(_ id: UUID) {
        pageNotices.dismiss(id)
        showNotices()
    }

    /// The furniture, then the zero point being dragged as crosshairs across the view.
    func drawFurniture(in ctx: CGContext) {
        let viewport = canvas.viewport
        furniture.draw(in: ctx, viewport: viewport)
        guard let point = zeroPointDrag else { return }
        let view = viewport.toView(point)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: view.x, y: 0))
        ctx.addLine(to: CGPoint(x: view.x, y: viewport.size.height))
        ctx.move(to: CGPoint(x: 0, y: view.y))
        ctx.addLine(to: CGPoint(x: viewport.size.width, y: view.y))
        ctx.strokePath()
    }

    /// The rulers count from the active page's zero point in the document's units.
    func updateRulers() {
        let reference = GlyphCanvasUnits.rulerReference(of: documentHandle) ?? (units: documentHandle.unitConverter, zero: documentHandle.activePage.zeroPoint)
        rulerHost.horizontalRuler.frameOfReference = reference
        rulerHost.verticalRuler.frameOfReference = reference
    }

    /// The selection's bounds where the Pointer tool is dragging it (the rulers track its edges);
    /// nil when nothing is being moved.
    var draggedSelectionBounds: Rect? {
        guard let delta = (toolManager?.activeTool as? PointerTool)?.moveDelta, let bounds = selection.selectedBounds else { return nil }
        return bounds.offset(by: delta)
    }

    /// The pasteboard point under a window point.
    func pasteboardPoint(atWindowPoint point: NSPoint) -> Point {
        viewport.toPasteboard(canvas.viewPoint(fromAppKit: canvas.convert(point, from: nil)))
    }

    // MARK: Showing and locking

    /// menu:View[Grid > Show].
    var showsGrid: Bool {
        get { furniture.showsGrid }
        set {
            furniture.showsGrid = newValue
            canvas.setNeedsFurnitureDisplay()
            onViewStateChange?(self)
        }
    }

    /// menu:View[Guides > Show].
    var showsGuides: Bool {
        get { furniture.showsGuides }
        set {
            furniture.showsGuides = newValue
            canvas.setNeedsFurnitureDisplay()
            onViewStateChange?(self)
        }
    }

    /// menu:View[Guides > Lock]: shared, one change ("Lock guides" / "Unlock guides").
    @discardableResult
    func toggleGuidesLocked() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        objectEditing.perform(SetGuidesLocked(!documentHandle.settings.guidesLocked))
    }

    // MARK: Guides out of the rulers

    /// A drag out of the top ruler (a horizontal guide) or the left ruler (a vertical one): the
    /// guide follows the pointer and is added where it is released over a page -- with kbd:[Option]
    /// on every page crossed -- and nothing happens over the pasteboard.
    func rulerDrag(_ axis: PageGuide.Axis, _ phase: RulerStripView.DragPhase, at windowPoint: NSPoint, modifiers: KeyModifiers) {
        let point = pasteboardPoint(atWindowPoint: windowPoint)
        let pages = documentHandle.pageList
        switch phase {
        case .began:
            var drag = GuideDrag(source: .ruler, axis: axis, point: point)
            drag.move(to: point, modifiers: modifiers, pages: pages)
            furniture.drag = drag
        case .moved:
            furniture.drag?.move(to: point, modifiers: modifiers, pages: pages)
            if let readout = furniture.drag?.readout(in: pages, units: documentHandle.unitConverter) { statusBar.show(message: readout) }
        case .ended:
            guard var drag = furniture.drag else { return }
            drag.move(to: point, modifiers: modifiers, pages: pages)
            furniture.drag = nil
            if let command = drag.command(in: pages, option: modifiers.contains(.option)) { objectEditing.perform(command) }
        }
        canvas.setNeedsFurnitureDisplay()
    }

    // MARK: The zero point

    /// The zero-point marker dragged onto the pasteboard: crosshairs follow the pointer, snapped
    /// like any dragged point -- or with kbd:[Shift] to the active page's corners and centre -- and
    /// the release writes the active page's zero point (one change, "Move zero point").
    func zeroPointDragged(_ phase: RulerStripView.DragPhase, at windowPoint: NSPoint, modifiers: KeyModifiers) {
        let page = documentHandle.activePage
        let raw = pasteboardPoint(atWindowPoint: windowPoint)
        let point = modifiers.contains(.shift)
            ? ZeroPointDrop.point(raw, on: page, shift: true)
            : toolManager.context.snapping.snap(raw, viewport: viewport)
        switch phase {
        case .began, .moved:
            zeroPointDrag = point
        case .ended:
            zeroPointDrag = nil
            objectEditing.perform(ZeroPointDrop.command(point, on: page))
        }
    }

    /// A double-click on the marker: the active page's zero point goes back to its bottom-left
    /// corner ("Reset zero point").
    @discardableResult
    func resetZeroPoint() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        objectEditing.perform(SetRulerOrigin(documentHandle.activePage.id, to: nil))
    }

    // MARK: Snapping

    /// What the tools snap to now (DOC-016's `SnapSources`): the grid from the active page's zero
    /// point, every page's guides, the guide objects, and the drawn objects through the hit
    /// tester's R-tree with the selected ones left out, under the window's snap toggles.
    func snapSources() -> (sources: SnapSources, toggles: SnapToggles) {
        let document = documentHandle
        let list = document.displayList
        let pages = document.pageList
        let tester = selection.hitTester(viewport: viewport, subselect: false)
        let excluded = Set(selection.model.ids.compactMap { list.index(of: $0.node) })
        let sources = SnapSources(grid: GlyphCanvasUnits.grid(of: document), guides: pages.snapGuides + document.canvasSnapGuides, guideObjects: SnapSources.guideObjects(in: list),
                                  displayList: list, index: tester.index, excludedItems: excluded, smartGuides: smartGuideSnaps,
                                  gridLines: PerspectiveGridDrawing.snapLines(of: document))
        let toggles = SnapToggles(grid: snap.grid, guides: snap.guides, points: snap.point, objects: snap.object,
                                  smartGuides: environment.preferences[PreferenceCatalog.General.smartGuides])
        return (sources, toggles)
    }

    // MARK: The active page (pages.adoc, "Preferences that choose the active page")

    /// *Using tools sets the active page*: a press on a page with any tool makes it active.
    func toolPressed(at point: Point) {
        guard environment.preferences[PreferenceCatalog.Document.toolsSetPage],
              let page = documentHandle.pageList.page(containing: point) else { return }
        documentHandle.selectPage(id: page.id)
    }

    /// *Changing view sets the active page*: once the view has rested 200 ms, the page covering
    /// most of it becomes active -- unless the active page changed meanwhile (the page selector,
    /// the Document panel, Add Page, a remote deletion moving it to the nearest page): a page
    /// chosen after the view last moved is not taken back by that move.
    func viewDidMove() {
        viewPageTask?.cancel()
        guard environment.preferences[PreferenceCatalog.Document.viewSetsPage] else { return }
        let active = documentHandle.activePage.id
        viewPageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.documentHandle.activePage.id == active else { return }
            self.settleViewPage()
        }
    }

    /// Makes the page covering most of the view active.
    func settleViewPage() {
        guard let page = Self.page(coveringMostOf: viewport.visiblePasteboardBounds, in: documentHandle.pageList) else { return }
        documentHandle.selectPage(id: page.id)
    }

    /// The page with the largest area inside `rect`; nil when no page is in it.
    static func page(coveringMostOf rect: Rect, in pages: PageList) -> Page? {
        let covered = pages.pages.map { page -> (Page, Double) in
            let overlap = page.rect.intersection(rect)
            return (page, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = covered.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    // MARK: Sheets

    /// A SwiftUI sheet on this window, identified as `identifier`.
    @discardableResult
    func presentSheet<Content: View>(_ identifier: String, @ViewBuilder content: (@escaping @MainActor () -> Void) -> Content) -> NSWindow? {
        guard let window else { return nil }
        let holder = SheetHolder()
        let close: @MainActor () -> Void = { [weak window] in
            if let sheet = holder.sheet, let window { window.endSheet(sheet) }
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: content(close)))
        sheet.identifier = NSUserInterfaceItemIdentifier(identifier)
        sheet.isReleasedWhenClosed = false
        holder.sheet = sheet
        window.beginSheet(sheet)
        return sheet
    }

    /// Where the sheets' buttons perform: the window's object commands.
    var sheetPerform: @MainActor (any WTModel.Command) -> Void {
        { [weak self] in self?.objectEditing.perform($0) }
    }

    /// The layer released guides go on: the one picks are kept to.
    var sheetLayer: @MainActor () -> OpID? {
        { [weak self] in self?.pickingLayer }
    }

    /// menu:View[Grid > Edit…].
    @discardableResult
    func presentGridSheet() -> NSWindow? {
        let model = GridSheetModel(document: documentHandle, perform: sheetPerform)
        return presentSheet("sheet.grid") { close in GridSheet(model: model, close: close) }
    }

    /// menu:View[Guides > Edit…] or a double-click on a guide: the guides of `page` (the active
    /// page by default).
    @discardableResult
    func presentGuidesSheet(page: OpID? = nil) -> NSWindow? {
        let model = GuidesSheetModel(document: documentHandle, page: page ?? documentHandle.activePage.id,
                                     layer: sheetLayer,
                                     perform: sheetPerform)
        return presentSheet("sheet.guides") { close in GuidesSheet(model: model, close: close) }
    }

    /// menu:View[Page Rulers > Edit Units…].
    @discardableResult
    func presentUnitsSheet() -> NSWindow? {
        let model = UnitsSheetModel(document: documentHandle, perform: sheetPerform)
        return presentSheet("sheet.units") { close in UnitsSheet(model: model, close: close) }
    }
}

/// The sheet a SwiftUI sheet's close button ends.
@MainActor
final class SheetHolder {
    weak var sheet: NSWindow?
}
