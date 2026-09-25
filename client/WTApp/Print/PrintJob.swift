import AppKit
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTRender

/// What a print job contains (printing.adoc, "Choosing what to print"): a job parameter, never
/// document state.
enum PrintSource: String, CaseIterable, Identifiable, Sendable {
    case pages
    case outputArea

    var id: String { rawValue }
    var title: String { self == .pages ? "Pages" : "Output area" }
}

/// One print job (PRINT-003): the document captured by `PrintSnapshot` into a `PrintRequest` --
/// every page, or the output area, on the queue's paper, with *Selected objects only* -- and the
/// `PrintPlan` of its sheets (pages × tiles × plates) that the print view draws.
enum PrintJob {
    /// The queue's paper: `NSPrintInfo`'s oriented paper size, its printable area flipped to the
    /// plan's top-left origin, and the printer's resolution when it reports one.
    @MainActor
    static func paper(_ info: NSPrintInfo) -> PrintPaper {
        let size = info.paperSize
        let bounds = info.imageablePageBounds
        let imageable = bounds.isEmpty ? nil : Rect(x: Double(bounds.minX), y: Double(size.height - bounds.maxY), width: Double(bounds.width), height: Double(bounds.height))
        let resolution = (info.printer.deviceDescription[.resolution] as? NSValue).map { Double($0.sizeValue.width) }
        return PrintPaper(size: Size(width: Double(size.width), height: Double(size.height)), imageable: imageable, resolution: resolution)
    }

    /// The request for `document`: `source` (the output area only while there is one), on `paper`,
    /// limited to `selection` when given.
    @MainActor
    static func request(_ document: DocumentHandle, source: PrintSource, paper: PrintPaper, selection: Set<NodeID>?, blobs: BlobPlacement) -> PrintRequest {
        let state = document.state
        let from: PrintSnapshot.Source
        if source == .outputArea, let area = OutputArea.read(state) {
            from = .outputArea(area)
        } else {
            from = .pages
        }
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("print-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        let request = PrintSnapshot.Request(name: document.title, source: from, paper: paper, selection: selection)
        return PrintSnapshot.capture(state, request: request, builder: builder, blob: { blobs.cached($0) })
    }

    /// The plan of the job for `document`.
    @MainActor
    static func plan(_ document: DocumentHandle, source: PrintSource, paper: PrintPaper, selection: Set<NodeID>?, blobs: BlobPlacement) -> PrintPlan {
        PrintPlan(request(document, source: source, paper: paper, selection: selection, blobs: blobs))
    }

    /// The sheet renderer drawing placed images from `store` (the window's `ImageStore`).
    static func renderer(imageStore store: ImageStore?) -> PrintSheetRenderer {
        var base = CoreGraphicsRenderer()
        base.imageStore = store
        return PrintSheetRenderer(base: base)
    }
}

/// The view `NSPrintOperation` prints (PRINT-003; printing.adoc and print-preview.adoc,
/// "Client"): one paper-sized stripe per sheet of the plan, stacked top to bottom, so the print
/// loop and the panel's preview both paginate by `rectForPage`.  Each stripe is drawn by
/// `PrintSheetRenderer`, and in the panel's preview the non-printing overlays follow.  When the
/// panel's paper changes, pagination reports it so the plan is made again for the new paper.
@MainActor
final class PrintPlanView: NSView {
    private(set) var plan: PrintPlan
    var renderer: PrintSheetRenderer
    /// The job title (the document's name).
    let title: String
    /// Whether the panel's preview is drawing (the panel is on screen); sheets for the spooled job
    /// never get the overlays.
    var isPreview: @MainActor () -> Bool = { false }
    /// The paper the running operation prints on, read at each pagination.
    var currentPaper: @MainActor () -> PrintPaper? = { NSPrintOperation.current.map { PrintJob.paper($0.printInfo) } }
    /// Called when pagination finds the paper changed (the session plans again and calls `show`).
    var onPaperChange: @MainActor (PrintPaper) -> Void = { _ in }
    /// Sheets that could not be drawn (out of memory), counted for the tests.
    private(set) var failedSheets = 0

    init(plan: PrintPlan, renderer: PrintSheetRenderer, title: String) {
        self.plan = plan
        self.renderer = renderer
        self.title = title
        super.init(frame: Self.frame(for: plan))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func frame(for plan: PrintPlan) -> NSRect {
        let paper = plan.request.paper.size
        return NSRect(x: 0, y: 0, width: paper.width, height: paper.height * Double(max(plan.count, 1)))
    }

    var paperSize: NSSize { NSSize(width: plan.request.paper.size.width, height: plan.request.paper.size.height) }

    /// Shows `plan`: resized to its sheets and redrawn.
    func show(_ plan: PrintPlan) {
        self.plan = plan
        setFrameSize(Self.frame(for: plan).size)
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override var printJobTitle: String { title }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let paper = currentPaper(), paper != plan.request.paper { onPaperChange(paper) }
        range.pointee = NSRange(location: 1, length: max(plan.count, 1))
        return true
    }

    /// Sheet `page` (1-based): the stripe from the top.
    override func rectForPage(_ page: Int) -> NSRect {
        let count = max(plan.count, 1)
        let index = min(max(page, 1), count) - 1
        let paper = paperSize
        return NSRect(x: 0, y: paper.height * CGFloat(count - 1 - index), width: paper.width, height: paper.height)
    }

    /// The name of sheet `page` (1-based): `Page 1, row 2 column 1, Magenta`.
    func sheetName(_ page: Int) -> String? {
        plan.sheets.indices.contains(page - 1) ? plan.sheets[page - 1].name : nil
    }

    /// The header AppKit prints when *Print header and footer* is on: the sheet's name.
    override var pageHeader: NSAttributedString {
        NSAttributedString(string: NSPrintOperation.current.flatMap { sheetName($0.currentPage) } ?? title)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawSheets(in: context, dirty: dirtyRect, preview: isPreview())
    }

    /// Draws every sheet whose stripe meets `dirty`, with the preview overlays when `preview`.
    func drawSheets(in context: CGContext, dirty: CGRect, preview: Bool) {
        for index in plan.sheets.indices {
            let stripe = rectForPage(index + 1)
            guard stripe.intersects(dirty) else { continue }
            context.saveGState()
            context.translateBy(x: stripe.minX, y: stripe.minY)
            do {
                try renderer.draw(sheet: index, of: plan, into: context)
            } catch {
                failedSheets += 1
            }
            if preview { PrintSheetRenderer.drawPreviewOverlays(sheet: index, of: plan, into: context) }
            context.restoreGState()
        }
    }
}
