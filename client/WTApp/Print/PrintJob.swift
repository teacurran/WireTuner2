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

/// One print job's sheets, composite only (printing.adoc, "Scaling"): each page -- or the output
/// area -- drawn as one sheet through the export pipeline's PDF writer, scaled by the document's
/// *Scale* settings and centred on the paper plus the *Offset*.  Tiling, marks and separations are
/// the print plan's (PRINT-003, PRINT-005, PRINT-006).
struct PrintJob {
    /// The document's pages (or the output area) as the export pipeline sees them.
    var scene: ExportScene
    var settings: DocumentPrintSettings
    /// The PDF of every sheet, one PDF page per sheet.
    var pdf: CGPDFDocument?

    init(scene: ExportScene, settings: DocumentPrintSettings, pdf: Data?) {
        self.scene = scene
        self.settings = settings
        self.pdf = pdf.flatMap { CGDataProvider(data: $0 as CFData) }.flatMap(CGPDFDocument.init)
    }

    /// The snapshot for `source`: every page, or the output area when there is one (nil otherwise).
    @MainActor
    static func scene(of window: DocumentWindowController, source: PrintSource, blobs: BlobPlacement) -> ExportScene? {
        let document = window.documentHandle
        let state = document.state
        let pages = document.pageList.exportPages
        let scope: ExportSnapshot.Scope
        switch source {
        case .pages:
            scope = .pages(Array(pages.indices))
        case .outputArea:
            guard let area = OutputArea.read(state) else { return nil }
            scope = .area(area)
        }
        let settings = DocumentPrintSettings(state)
        let request = ExportSnapshot.Request(name: document.title, pages: pages, scope: scope,
                                             includePageBoundary: source == .pages || settings.printPageBoundary,
                                             includeHidden: settings.includeHiddenLayers, pageColor: nil)
        var builder = DocumentDisplayListBuilder(canvas: CanvasID("print-\(document.id)"))
        builder.textLayout = TextSceneLayout(engine: document.textEngine)
        return ExportSnapshot.capture(state, request: request, builder: builder, blob: { blobs.cached($0) }).scene
    }

    /// The job for `window`: its scene written as a PDF, one page per sheet.
    @MainActor
    static func make(for window: DocumentWindowController, source: PrintSource, blobs: BlobPlacement) -> PrintJob? {
        guard let scene = scene(of: window, source: source, blobs: blobs) else { return nil }
        let data = try? PDFExporter().data(scene: scene, options: PDFOptions()).data
        return PrintJob(scene: scene, settings: DocumentPrintSettings(window.documentHandle.state), pdf: data)
    }

    var sheetCount: Int { pdf?.numberOfPages ?? 0 }

    /// The scale factors of a sheet of `size` on paper whose printable area is `imageable`.
    func scale(of size: Size, imageable: CGRect) -> (x: Double, y: Double) {
        switch settings.scaleMode {
        case .uniform:
            return (settings.scaleX / 100, settings.scaleX / 100)
        case .variable:
            return (settings.scaleX / 100, settings.scaleY / 100)
        case .fit:
            guard size.width > 0, size.height > 0 else { return (1, 1) }
            let fit = min(Double(imageable.width) / size.width, Double(imageable.height) / size.height)
            return (fit, fit)
        }
    }

    /// Where sheet `index`'s artwork goes on the paper (unflipped paper coordinates): centred on the
    /// printable area, moved by the offset (x right, y down as the document has it).
    func placement(ofSheet index: Int, imageable: CGRect) -> CGRect? {
        guard let page = pdf?.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let (sx, sy) = scale(of: Size(width: Double(box.width), height: Double(box.height)), imageable: imageable)
        let width = Double(box.width) * sx, height = Double(box.height) * sy
        let x = Double(imageable.midX) - width / 2 + settings.offset.x
        let y = Double(imageable.midY) - height / 2 - settings.offset.y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Draws sheet `index` into `context` (unflipped) on paper whose printable area is `imageable`.
    func draw(sheet index: Int, in context: CGContext, imageable: CGRect) {
        guard let page = pdf?.page(at: index + 1), let target = placement(ofSheet: index, imageable: imageable) else { return }
        let box = page.getBoxRect(.mediaBox)
        context.saveGState()
        if settings.flatness > 0 { context.setFlatness(CGFloat(settings.flatness)) }
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: target.width / box.width, y: target.height / box.height)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}

/// The view `NSPrintOperation` prints: one paper-sized stripe per sheet, stacked top to bottom,
/// so both the print loop and the panel's preview paginate by `rectForPage`.
@MainActor
final class PrintSheetsView: NSView {
    var job: PrintJob
    let paper: NSSize
    let imageable: CGRect

    init(job: PrintJob, printInfo: NSPrintInfo) {
        self.job = job
        paper = printInfo.paperSize
        imageable = printInfo.imageablePageBounds
        super.init(frame: NSRect(x: 0, y: 0, width: paper.width, height: paper.height * CGFloat(max(job.sheetCount, 1))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(job.sheetCount, 1))
        return true
    }

    /// Sheet `page` (1-based): the stripe from the top.
    override func rectForPage(_ page: Int) -> NSRect {
        let count = max(job.sheetCount, 1)
        let index = min(max(page, 1), count) - 1
        return NSRect(x: 0, y: paper.height * CGFloat(count - 1 - index), width: paper.width, height: paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawSheets(in: context, dirty: dirtyRect)
    }

    /// Draws every sheet whose stripe meets `dirty`.
    func drawSheets(in context: CGContext, dirty: CGRect) {
        for index in 0..<job.sheetCount {
            let stripe = rectForPage(index + 1)
            guard stripe.intersects(dirty) else { continue }
            context.saveGState()
            context.translateBy(x: stripe.minX, y: stripe.minY)
            job.draw(sheet: index, in: context, imageable: imageable)
            context.restoreGState()
        }
    }
}
