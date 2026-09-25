// The job as a PDF (printing.adoc: "The PDF contains exactly what the printer would have
// received -- marks, bleed, tiles and separations included").  macOS writes *Save as PDF* from
// the print view's drawing; this is the same drawing into a PDF context, one page per sheet, for
// the print corpus and for callers without a print operation.

import CoreGraphics
import Foundation

public enum PrintPDF {
    /// Every sheet of `plan` drawn by `renderer`, one paper-sized PDF page per sheet, titled
    /// `title`; a sheet that cannot be drawn (cancelled, out of memory) throws.
    public static func data(_ plan: PrintPlan, renderer: PrintSheetRenderer = PrintSheetRenderer(), title: String? = nil) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: plan.request.paper.size.width, height: plan.request.paper.size.height)
        let info = [kCGPDFContextTitle: title ?? plan.request.scene.name, kCGPDFContextCreator: "WireTuner"] as CFDictionary
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)!
        var vector = renderer
        vector.base = renderer.base.forVectorOutput()
        for index in plan.sheets.indices {
            context.beginPDFPage(nil)
            do {
                try vector.draw(sheet: index, of: plan, into: context)
            } catch {
                context.endPDFPage()
                context.closePDF()
                throw error
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
