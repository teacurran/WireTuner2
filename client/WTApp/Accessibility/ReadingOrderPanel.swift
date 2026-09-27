import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// menu:Object[Reading Order…] (names-notes.adoc, "Reading order"; OBJ-041): the current page's
/// objects in reading order, reordered by dragging rows or by clicking objects on the page in the
/// order they should be read (kbd:[Shift]-click moves one to the end); each gesture is one change
/// (`ArrangeReadingOrder`).  btn:[Use Stacking Order] discards the arrangement.  While it is open
/// every listed object shows a numbered badge on the canvas and canvas clicks go to it.
/// Deviation: a floating panel rather than a sheet, since a sheet would block the clicks on the
/// canvas the task asks for.
@MainActor
@Observable
final class ReadingOrderModel {
    struct Row: Equatable, Identifiable {
        let id: OpID
        let name: String
        let alt: String
    }

    /// Weak: the panel (kept by `ReadingOrderFeatures`) can outlive its window; with the window
    /// gone the list is empty and the gestures do nothing.
    @ObservationIgnored private(set) weak var window: DocumentWindowController?
    /// How many objects have been clicked on the canvas since the panel opened.
    private(set) var clicked = 0
    /// Moves with every change, so the list re-reads.
    private(set) var revision = 0

    init(window: DocumentWindowController) {
        self.window = window
    }

    var document: DocumentHandle? { window?.documentHandle }
    var page: Page? { document?.activePage }
    /// The page's name for the title ("" once the window went).
    var pageName: String { page?.name ?? "" }

    /// The page's objects in reading order.
    var order: [OpID] {
        _ = revision
        guard let document, let page else { return [] }
        let state = document.state
        return ReadingOrder.order(of: page, in: state, pages: PageList(state))
    }

    var rows: [Row] {
        guard let state = document?.state else { return [] }
        return order.map { node in Row(id: node, name: state.displayName(of: node), alt: state.accessibleDescription(of: node) ?? "") }
    }

    func refresh() { revision &+= 1 }

    @discardableResult
    func arrange(_ order: [OpID]) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        guard let window, let page else { return Task { nil } }
        let task = window.objectEditing.perform(ArrangeReadingOrder(page: page.id, order: order))
        return Task { @MainActor in
            let change = await task.value
            self.refresh()
            return change
        }
    }

    /// A row dragged (the list's move).
    @discardableResult
    func move(from source: IndexSet, to destination: Int) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        var order = order
        guard source.allSatisfy(order.indices.contains), destination <= order.count else { return arrange(order) }
        order.move(fromOffsets: source, toOffset: destination)
        return arrange(order)
    }

    /// A click on `node` on the canvas: it is read next after the ones clicked before it; with
    /// kbd:[Shift] it goes to the end.
    @discardableResult
    func click(_ node: OpID, toEnd: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        var order = order
        guard let from = order.firstIndex(of: node) else { return nil }
        order.remove(at: from)
        if toEnd {
            order.append(node)
        } else {
            order.insert(node, at: min(clicked, order.count))
            clicked += 1
        }
        return arrange(order)
    }

    @discardableResult
    func useStackingOrder() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        clicked = 0
        guard let window, let page else { return Task { nil } }
        let task = window.objectEditing.perform(ClearReadingOrder(page: page.id))
        return Task { @MainActor in
            let change = await task.value
            self.refresh()
            return change
        }
    }

    /// The object on the page under `point` (pasteboard): the topmost listed one.
    func object(at point: Point) -> OpID? {
        guard let state = document?.state else { return nil }
        return order.reversed().first { Objects.bounds(of: $0, in: state)?.contains(point) ?? false }
    }

    /// The badges: each listed object's number at its top-left (pasteboard).
    var badges: [(number: Int, at: Point)] {
        guard let state = document?.state else { return [] }
        return order.enumerated().compactMap { index, node in
            Objects.bounds(of: node, in: state).map { (index + 1, Point(x: $0.minX, y: $0.minY)) }
        }
    }
}

struct ReadingOrderView: View {
    @Bindable var model: ReadingOrderModel
    let done: () -> Void

    static func moving(_ model: ReadingOrderModel) -> (IndexSet, Int) -> Void {
        { model.move(from: $0, to: $1) }
    }

    static func stacking(_ model: ReadingOrderModel) -> () -> Void {
        { model.useStackingOrder() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading Order — \(model.pageName)").font(.headline)
            Text("Drag rows, or click objects on the page in the order they should be read. Shift-click moves one to the end.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    HStack {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(row.name)
                            if !row.alt.isEmpty { Text(row.alt).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .accessibilityIdentifier("readingOrder.row.\(index)")
                }
                .onMove(perform: Self.moving(model))
            }
            .frame(minHeight: 200)
            .accessibilityIdentifier("readingOrder.list")
            HStack {
                Button("Use Stacking Order", action: Self.stacking(model)).accessibilityIdentifier("readingOrder.stacking")
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction).accessibilityIdentifier("readingOrder.done")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// The canvas side while the panel is open: clicks order objects, badges number them.
@MainActor
final class ReadingOrderHandles: CanvasHandleLayer {
    weak var model: ReadingOrderModel?

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let model else { return false }
        if let node = model.object(at: e.pasteboardPoint) { model.click(node, toEnd: e.modifiers.contains(.shift)) }
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {}
    func release(_ e: CanvasEvent, context: ToolContext) {}
    func cancel(context: ToolContext) {}

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        guard let model else { return }
        for badge in model.badges {
            Self.drawBadge(badge.number, at: viewport.toView(badge.at), in: ctx)
        }
    }

    static func drawBadge(_ number: Int, at point: Point, in ctx: CGContext) {
        let text = "\(number)"
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        let width = max(CTLineGetTypographicBounds(line, nil, nil, nil) + 8, 16)
        let rect = CGRect(x: point.x - width / 2, y: point.y - 8, width: width, height: 16)
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: rect.minX + (width - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y: rect.maxY - 4)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// The panel per window, and the command.
@MainActor
enum ReadingOrderFeatures {
    static let id: CommandID = "object.readingOrder"
    /// Tests keep panels from ordering front.
    static var showsPanel = true
    private struct Entry {
        weak var window: DocumentWindowController?
        let panel: NSPanel
        let model: ReadingOrderModel
        let handles: ReadingOrderHandles
    }

    private static var open: [ObjectIdentifier: Entry] = [:]

    /// Panels left by windows that closed without btn:[Done] go.
    private static func prune() {
        for (key, entry) in open where entry.window == nil {
            entry.panel.orderOut(nil)
            open[key] = nil
        }
    }

    /// `window`'s open panel's model (an entry left by a window since gone does not count).
    static func model(of window: DocumentWindowController) -> ReadingOrderModel? {
        guard let entry = open[ObjectIdentifier(window)], entry.window === window else { return nil }
        return entry.model
    }

    /// Opens (or brings forward) `window`'s panel.
    @discardableResult
    static func show(on window: DocumentWindowController) -> ReadingOrderModel {
        if let existing = model(of: window) {
            if showsPanel { open[ObjectIdentifier(window)]?.panel.orderFront(nil) }
            return existing
        }
        prune()
        let model = ReadingOrderModel(window: window)
        let handles = ReadingOrderHandles()
        handles.model = model
        window.toolManager.handleLayers.insert(handles, at: 0)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier("reading-order")
        panel.title = "Reading Order"
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: ReadingOrderView(model: model) { [weak window] in
            if let window { close(window) }
        })
        open[ObjectIdentifier(window)] = Entry(window: window, panel: panel, model: model, handles: handles)
        window.canvas.setNeedsOverlayDisplay()
        if showsPanel { panel.makeKeyAndOrderFront(nil) }
        return model
    }

    /// btn:[Done]: the panel closes and the canvas is the tool's again.
    static func close(_ window: DocumentWindowController) {
        guard model(of: window) != nil, let entry = open.removeValue(forKey: ObjectIdentifier(window)) else { return }
        entry.panel.orderOut(nil)
        window.toolManager.handleLayers.removeAll { $0 === entry.handles }
        window.canvas.setNeedsOverlayDisplay()
    }

    static func command(window: @escaping @MainActor () -> DocumentWindowController?) -> Command {
        Command(id: id, title: "Reading Order…", menu: MenuPath(ContextMenuCatalog.Menu.object, section: 1), keywords: ["accessibility", "screen reader", "voiceover", "order"],
                validation: { window() == nil ? .disabled("Open a document") : .enabled },
                action: .perform { if let front = window() { show(on: front) } })
    }
}
