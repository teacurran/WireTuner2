// Comment threads as PDF annotations (collaboration/comments.adoc, "Client"; COLLAB-033): each
// open thread pinned on the page is one `/Text` annotation at the pin -- a closed comment icon
// whose top-left corner is the pin -- with the opener's author as `/T`, its text as `/Contents`
// and its wall time as `/M` and `/CreationDate`; each reply is a `/Text` annotation over the same
// icon whose `/IRT` names the opener (`/RT /R`), which Preview and Acrobat show as a reply in the
// thread.  Resolved threads are left out; PDF/X turns the option off before anything is written.

import Foundation
import WTGeometry

extension PDFDocumentBuild {
    /// The annotations of the threads pinned on a page with pasteboard bounds `bounds`; `base`
    /// maps the pasteboard onto the page.
    func commentAnnotations(on bounds: Rect, base: AffineTransform) -> [PDFValue] {
        var annotations: [PDFValue] = []
        for thread in ExportCommentThread.annotated(scene.comments, on: bounds) {
            let corner = base.apply(thread.pin)
            let rect = PDFValue.rect(corner.x, corner.y - 20, corner.x + 20, corner.y)
            var opener: Int?
            for comment in thread.comments {
                let date = pdfDate(Date(timeIntervalSince1970: Double(comment.wallTimeMs) / 1000))
                var entries: [(String, PDFValue)] = [
                    ("Type", .name("Annot")), ("Subtype", .name("Text")), ("Rect", rect),
                    ("Contents", .string(comment.text)), ("T", .string(comment.author)),
                    ("M", .string(date)), ("CreationDate", .string(date)),
                    ("Name", .name("Comment")), ("Open", .bool(false)), ("F", .int(4)),
                ]
                if let opener {
                    entries += [("IRT", .reference(opener)), ("RT", .name("R"))]
                }
                let object = objects.add(.dictionary(entries))
                opener = opener ?? object
                annotations.append(.reference(object))
            }
        }
        return annotations
    }
}
