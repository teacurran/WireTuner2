// Comment threads for PDF export (collaboration/comments.adoc, "Exporting"; COLLAB-033): the
// threads of `0:12` as WTModel resolves them -- pin in pasteboard points, author display names,
// wall times -- carried by the export snapshot so the PDF writer's *Comments as annotations*
// option can write them.  Only the PDF writer reads them; every other writer ignores
// `ExportScene.comments`, so a commented document exports byte-identically to an uncommented one.

import Foundation
import WTGeometry

/// One comment of a thread: its author's display name, its text and when it was written.
public struct ExportComment: Hashable, Sendable {
    public var author: String
    public var text: String
    /// `wall_time_ms` of the comment.
    public var wallTimeMs: Int64

    public init(author: String, text: String, wallTimeMs: Int64) {
        self.author = author
        self.text = text
        self.wallTimeMs = wallTimeMs
    }
}

/// One comment thread: where its pin is, whether it is resolved, and its comments (the opener
/// first, replies in order, deleted comments already left out by the caller).
public struct ExportCommentThread: Hashable, Sendable {
    /// The pin in pasteboard points (`CommentThread.pin`).
    public var pin: Point
    public var resolved: Bool
    public var comments: [ExportComment]

    public init(pin: Point, resolved: Bool = false, comments: [ExportComment]) {
        self.pin = pin
        self.resolved = resolved
        self.comments = comments
    }
}

extension ExportCommentThread {
    /// The threads the PDF writer annotates on a page with pasteboard bounds `bounds`: open,
    /// with at least one comment, pinned inside the page (edges included), in the given order.
    static func annotated(_ threads: [ExportCommentThread], on bounds: Rect) -> [ExportCommentThread] {
        threads.filter { thread in
            !thread.resolved && !thread.comments.isEmpty
                && thread.pin.x >= bounds.minX && thread.pin.x <= bounds.maxX && thread.pin.y >= bounds.minY && thread.pin.y <= bounds.maxY
        }
    }
}
