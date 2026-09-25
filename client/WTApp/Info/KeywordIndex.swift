import Foundation
import WTModel

/// Keeps the library cache's copy of each open document's keywords current (file-info.adoc,
/// *Keywords*: "what the library window's search matches"; IO-011), so the offline search finds a
/// document by them as the online one does.
@MainActor
final class DocumentKeywordIndex {
    private let document: DocumentHandle
    private let record: @MainActor (String, [String]) -> Void
    private(set) var last: [String]?

    init(document: DocumentHandle, record: @escaping @MainActor (String, [String]) -> Void) {
        self.document = document
        self.record = record
    }

    /// Follows `window`'s document from now on.
    @discardableResult
    static func attach(_ window: DocumentWindowController, record: @escaping @MainActor (String, [String]) -> Void) -> DocumentKeywordIndex {
        let index = DocumentKeywordIndex(document: window.documentHandle, record: record)
        window.documentHandle.observe { [index] _ in index.update() }
        index.update()
        return index
    }

    /// The keywords changed since last recorded: recorded again.
    func update() {
        let keywords = DocumentInfoValues(document.state).keywords
        guard keywords != last else { return }
        last = keywords
        record(document.id, keywords)
    }
}
