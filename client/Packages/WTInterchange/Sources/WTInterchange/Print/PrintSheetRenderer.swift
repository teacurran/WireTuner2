// Drawing one sheet of a print plan (PRINT-003, PRINT-006, PRINT-008, PRINT-009's `screen_in_app`
// wiring; docs/_includes/printing/printing.adoc and output-devices.adoc, "Client").  The print
// view's `draw` and *Save as PDF* both come here, so the sheets are the same wherever they go.
// A sheet is drawn in paper space (y down): mirrored for *Emulsion down*, clipped to the page
// plus bleed, the artwork drawn through WTRender in Preview -- composite, one plate in grays, or
// that plate screened to one bit by WTRender's `Screener` -- or as one image when *Rasterize
// output* is on, then the marks and labels in registration colour, unscaled, and finally the
// whole sheet inverted for *Negative*.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

/// Draws sheets.
public struct PrintSheetRenderer: Sendable {
    /// The composite renderer (image store, colour management, raster effect settings).  Sheets
    /// always draw in Preview.
    public var base: CoreGraphicsRenderer
    /// *Print text as outlines* (PRINT-014): the list with every glyph run converted to paths.
    /// Nil uses `PrintTextOutlines.outline`.
    public var textOutliner: (@Sendable (DisplayList) -> DisplayList)?
    /// Polled between bands of screened and rasterized sheets.
    public var isCancelled: @Sendable () -> Bool
    /// The resolution plates are screened at when the queue gives none and *Rasterize output* is
    /// off: 300 dpi.
    public static let fallbackResolution = 300.0
    /// Rows rendered at a time for a rasterized sheet (4096-px bands bound the memory).
    public var bandHeight = 4096

    public init(base: CoreGraphicsRenderer = CoreGraphicsRenderer(), textOutliner: (@Sendable (DisplayList) -> DisplayList)? = nil,
                isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.base = base
        self.textOutliner = textOutliner
        self.isCancelled = isCancelled
    }

    /// Why a sheet could not be drawn.
    public enum SheetError: Error, Equatable {
        /// A band's bitmap could not be allocated.
        case outOfMemory
    }

    /// The device resolution screened or rasterized sheets use: the queue's, else *Rasterize
    /// output*'s, else `fallbackResolution`.
    public static func resolution(_ plan: PrintPlan) -> Double {
        plan.request.paper.resolution ?? (plan.request.options.rasterizeDPI > 0 ? plan.request.options.rasterizeDPI : fallbackResolution)
    }

    /// The renderer the artwork of `plan` draws with: Preview, the job's flatness.
    func renderer(for plan: PrintPlan) -> CoreGraphicsRenderer {
        var renderer = base.with(viewMode: .preview).with(overprintPreview: false)
        let flatness = plan.request.options.flatness
        renderer.outputFlatness = flatness > 0 ? flatness : nil
        return renderer
    }

    /// The per-object flatness of `page`: each path's own, by its item path.
    static func flatnessOverrides(_ page: ExportPage, _ flatness: [NodeID: Double]) -> [[Int]: Double] {
        guard !flatness.isEmpty else { return [:] }
        var result: [[Int]: Double] = [:]
        for (index, node) in page.displayList.nodeIDs.enumerated() {
            if let node, let value = flatness[node] { result[[index]] = value }
        }
        for (path, node) in page.nestedNodeIDs {
            if let value = flatness[node] { result[path] = value }
        }
        return result
    }

    /// Sheet `index` of `plan` into `context`, a y-up context whose user space is the paper in
    /// points (a print or PDF page, or a bitmap scaled to it).
    public func draw(sheet index: Int, of plan: PrintPlan, into context: CGContext) throws {
        let sheet = plan.sheets[index]
        let options = plan.request.options
        let paper = plan.request.paper.size
        context.saveGState()
        defer { context.restoreGState() }
        // Paper space: origin top-left, y down.
        context.translateBy(x: 0, y: paper.height)
        context.scaleBy(x: 1, y: -1)
        if options.emulsionDown {
            context.translateBy(x: paper.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        if options.negative {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: paper.width, height: paper.height))
        }
        if !sheet.clip.isEmpty {
            context.saveGState()
            context.clip(to: sheet.clip.cgRect)
            try drawArtwork(sheet, of: plan, into: context)
            context.restoreGState()
        }
        PrinterMarks.draw(sheet.marks, labels: sheet.labels, into: context)
        if options.negative {
            context.setBlendMode(.difference)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: paper.width, height: paper.height))
        }
    }

    /// The page's list as printed: text outlined when asked.
    func list(_ page: ExportPage, options: PrintOptions) -> DisplayList {
        guard options.textAsOutlines else { return page.displayList }
        return (textOutliner ?? PrintTextOutlines.outline)(page.displayList)
    }

    func drawArtwork(_ sheet: OutputSheet, of plan: PrintPlan, into context: CGContext) throws {
        let options = plan.request.options
        let page = plan.pages[sheet.page]
        let list = list(page, options: options)
        var renderer = renderer(for: plan)
        renderer.flatnessOverrides = Self.flatnessOverrides(page, plan.request.pathFlatness)
        if case .separation(let plate) = sheet.plate, options.screenInApp {
            try drawScreened(list, page: page, plate: plate, sheet: sheet, plan: plan, renderer: renderer, into: context)
        } else if options.rasterizeDPI > 0 {
            try drawRasterized(list, sheet: sheet, plan: plan, renderer: renderer, into: context)
        } else {
            drawVector(list, sheet: sheet, plan: plan, renderer: renderer, into: context)
        }
        if case .outputArea(let outlines) = plan.request.source, options.printPageBoundary {
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(PrinterMarks.lineWidth)
            for outline in outlines {
                context.stroke(outline.applying(sheet.transform).cgRect)
            }
        }
    }

    /// The artwork as vectors: WTRender's list drawn straight into the sheet.  WTRender flips a
    /// y-up context about its surface, so the sheet transform is conjugated with that flip.
    func drawVector(_ list: DisplayList, sheet: OutputSheet, plan: PrintPlan, renderer: CoreGraphicsRenderer, into context: CGContext) {
        let region = sheet.region
        let viewport = Viewport(scrollOrigin: region.origin, size: Size(width: region.width, height: region.height))
        let flip = AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: region.height)
        let conjugate = flip.concatenating(.translation(x: region.minX, y: region.minY)).concatenating(sheet.transform)
        context.saveGState()
        context.concatenate(conjugate.cgTransform)
        if let ink = sheet.plate.ink {
            PlateRenderer(base: renderer, spotAsProcess: plan.request.options.spotAsProcess).drawPlate(list, plate: ink, viewport: viewport, into: context)
        } else {
            renderer.render(list, viewport: viewport, into: context)
        }
        context.restoreGState()
    }

    /// `list` placed on the paper: every item moved by the sheet transform, so a render over paper
    /// space at the device resolution is the sheet's pixels.
    static func paperList(_ list: DisplayList, transform: AffineTransform) -> DisplayList {
        DisplayList(canvas: list.canvas, items: list.items.map { $0.transformed(by: transform) }, nodeIDs: list.nodeIDs, layers: list.layers)
    }

    /// The pixel rectangle of `rect` (paper points) at `scale` pixels per point, snapped outward.
    static func pixelRect(_ rect: Rect, scale: Double) -> (x: Int, y: Int, width: Int, height: Int) {
        let x0 = Int((rect.minX * scale).rounded(.down)), y0 = Int((rect.minY * scale).rounded(.down))
        let x1 = Int((rect.maxX * scale).rounded(.up)), y1 = Int((rect.maxY * scale).rounded(.up))
        return (x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
    }

    /// Draws `image` (row 0 at the top) over the paper rectangle `rect` in y-down paper space.
    static func place(_ image: CGImage, in rect: Rect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    /// The plate screened in the app (PRINT-008/009): the plate rasterized at the device
    /// resolution over the printed area and thresholded against the plate's screen and every
    /// object screen (resolved for this plate), then placed as a 1-bit image.
    func drawScreened(_ list: DisplayList, page: ExportPage, plate: PrintPlate, sheet: OutputSheet, plan: PrintPlan, renderer: CoreGraphicsRenderer,
                      into context: CGContext) throws {
        let options = plan.request.options
        let resolution = Self.resolution(plan)
        let scale = resolution / 72
        // A non-empty clip covers at least one pixel.
        let pixels = Self.pixelRect(sheet.clip, scale: scale)
        let area = Rect(x: Double(pixels.x) / scale, y: Double(pixels.y) / scale, width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)
        let plateScreen = plate.screen(default: options.defaultScreen)
        var screens: [NodeID: HalftoneScreen] = [:]
        for (node, screen) in plan.request.objectScreens {
            screens[node] = screen.resolved(on: plateScreen)
        }
        var flat = renderer
        flat.flatnessOverrides = [:]
        let bits = try Screener(resolution: resolution).screenPlate(
            Self.paperList(list, transform: sheet.transform), plate: plate.ink,
            renderer: PlateRenderer(base: flat, spotAsProcess: options.spotAsProcess), page: area, plateScreen: plateScreen,
            objectScreens: screens, nestedNodeIDs: page.nestedNodeIDs, ignoreObjectScreens: options.ignoreObjectHalftones, isCancelled: isCancelled
        )
        Self.place(bits.makeImage(), in: area, context: context)
    }

    /// *Rasterize output*: the artwork rendered at `rasterize_dpi` in bands -- RGB for a
    /// composite, gray for a plate -- each band placed as one image.
    func drawRasterized(_ list: DisplayList, sheet: OutputSheet, plan: PrintPlan, renderer: CoreGraphicsRenderer, into context: CGContext) throws {
        let options = plan.request.options
        let scale = options.rasterizeDPI / 72
        let pixels = Self.pixelRect(sheet.clip, scale: scale)
        let placed = Self.paperList(list, transform: sheet.transform)
        var flat = renderer
        flat.flatnessOverrides = [:]
        let drawer = sheet.plate.ink.map { PlateRenderer(base: flat, spotAsProcess: options.spotAsProcess).renderer(for: $0) } ?? flat
        var row = 0
        while row < pixels.height {
            if isCancelled() { throw CancellationError() }
            let rows = min(bandHeight, pixels.height - row)
            let band = Rect(x: Double(pixels.x) / scale, y: Double(pixels.y + row) / scale, width: Double(pixels.width) / scale, height: Double(rows) / scale)
            guard let surface = BitmapSurface(width: pixels.width, height: rows, colorSpace: drawer.colorManagement.colorSpace) else {
                throw SheetError.outOfMemory
            }
            surface.context.setFillColor(CGColor(gray: 1, alpha: 1))
            surface.context.fill(CGRect(x: 0, y: 0, width: pixels.width, height: rows))
            surface.context.scaleBy(x: scale, y: scale)
            drawer.render(placed, viewport: Viewport(scrollOrigin: band.origin, size: Size(width: band.width, height: band.height)), into: surface.context)
            Self.place(surface.makeImage()!, in: band, context: context)
            row += rows
        }
    }

    // MARK: Preview

    /// The print panel's non-printing overlays for sheet `index` (print-preview.adoc, "Reading the
    /// preview"), drawn after the sheet into the same y-up paper context: the paper outline, the
    /// printable area dotted, the page outline, the bleed band and, when tiling, the tile grid
    /// with this sheet's tile highlighted and the overlaps hatched.  Never drawn to a spooled job.
    public static func drawPreviewOverlays(sheet index: Int, of plan: PrintPlan, into context: CGContext) {
        let sheet = plan.sheets[index]
        let paper = plan.request.paper
        let options = plan.request.options
        let gray = CGColor(gray: 0.6, alpha: 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: paper.size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(gray)
        context.setLineWidth(0.5)
        context.stroke(paper.bounds.cgRect)
        context.saveGState()
        context.setLineDash(phase: 0, lengths: [1, 2])
        context.stroke(paper.imageable.cgRect)
        context.restoreGState()
        context.stroke(sheet.trim.cgRect)
        if options.bleed > 0 {
            let bleed = plan.pages[sheet.page].bounds.expanded(by: options.bleed).applying(sheet.transform)
            context.setFillColor(CGColor(gray: 0.6, alpha: 0.2))
            context.addRect(bleed.cgRect)
            context.addRect(sheet.trim.cgRect)
            context.fillPath(using: .evenOdd)
        }
        guard let tile = sheet.tile, !tile.isManual else { return }
        let siblings = plan.sheets.filter { $0.page == sheet.page && $0.plate == sheet.plate }.compactMap(\.tile)
        for other in siblings {
            context.stroke(other.rect.applying(sheet.transform).cgRect)
        }
        context.setFillColor(CGColor(gray: 0.6, alpha: 0.15))
        for other in siblings where other != tile {
            let overlap = other.rect.intersection(tile.rect)
            if !overlap.isEmpty { context.fill(overlap.applying(sheet.transform).cgRect) }
        }
        context.setStrokeColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
        context.setLineWidth(1)
        context.stroke(tile.rect.applying(sheet.transform).cgRect)
    }
}

extension Rect {
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

extension AffineTransform {
    var cgTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}
