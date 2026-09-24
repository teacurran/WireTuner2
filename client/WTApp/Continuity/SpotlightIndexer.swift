import CoreSpotlight
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WTModel

/// Where Spotlight items go: the app's default `CSSearchableIndex`, or a fake in tests.
protocol SpotlightIndexing: Sendable {
    func index(_ items: [CSSearchableItem]) async throws
    func delete(_ identifiers: [String]) async throws
}

/// No index (unit-test launches, which must not write the Mac's Spotlight index).
struct NoSpotlightIndex: SpotlightIndexing {
    func index(_ items: [CSSearchableItem]) async throws {}
    func delete(_ identifiers: [String]) async throws {}
}

/// The app's default index.
struct DefaultSpotlightIndex: SpotlightIndexing {
    func index(_ items: [CSSearchableItem]) async throws {
        try await CSSearchableIndex.default().indexSearchableItems(items)
    }

    func delete(_ identifiers: [String]) async throws {
        try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers)
    }
}

/// Spotlight for the documents on this Mac (saving.adoc, "Quick Look and Spotlight"; IO-035): one
/// `CSSearchableItem` per document that has been open here -- id the document id, in the
/// `com.villagecompute.wiretuner.document` domain, with the document's name as the title, Document
/// Info's description and keywords, the text of every text block (`SpotlightContent`), the library
/// thumbnail and the modification time.  The item is rebuilt when a window of the document closes,
/// and only when what it would index changed since the last build (a digest of it per document,
/// the page's `spotlight_index`); it is removed when the document is trashed or its local copy
/// removed.  Indexing is local and needs no connection.
@MainActor
final class SpotlightIndexer {
    static let domain = "com.villagecompute.wiretuner.document"
    static let fileName = "SpotlightIndex.json"

    let index: any SpotlightIndexing
    /// Where the digests are kept; nil keeps them in memory (tests).
    let url: URL?
    /// The library thumbnail of a document, PNG.
    var thumbnail: @MainActor (String) -> Data? = { _ in nil }
    var now: @MainActor () -> Date = { Date() }
    /// The digest each document was last indexed with.
    private(set) var digests: [String: String] = [:]
    /// Items built (tests and the reindex-once rule).
    private(set) var builds = 0

    init(index: any SpotlightIndexing = DefaultSpotlightIndex(), url: URL? = nil) {
        self.index = index
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            digests = stored
        }
    }

    static var defaultURL: URL {
        PanelLayoutStore.defaultURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The item of document `id` named `title` holding `content`.
    func item(id: String, title: String, content: SpotlightContent, thumbnail: Data?) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: PackageController.contentType)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = content.description.isEmpty ? nil : content.description
        attributes.keywords = content.keywords
        attributes.textContent = content.text
        attributes.thumbnailData = thumbnail
        attributes.contentModificationDate = now()
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: Self.domain, attributeSet: attributes)
    }

    /// The digest of what an item would index.
    static func digest(title: String, content: SpotlightContent, thumbnail: Data?) -> String {
        var hash = SHA256()
        for part in [title, content.description, content.keywords.joined(separator: "\u{1F}"), content.text] {
            hash.update(data: Data(part.utf8))
            hash.update(data: Data([0]))
        }
        hash.update(data: thumbnail ?? Data())
        return Data(hash.finalize()).hexString
    }

    /// A window of `document` closed: its item is rebuilt when what it indexes changed.  Returns
    /// whether it was.
    @discardableResult
    func documentDidClose(_ document: DocumentHandle) async -> Bool {
        guard document.model != nil else { return false }
        let content = SpotlightContent.of(document.state)
        let thumbnail = thumbnail(document.id)
        let digest = Self.digest(title: document.title, content: content, thumbnail: thumbnail)
        guard digests[document.id] != digest else { return false }
        builds += 1
        do {
            try await index.index([item(id: document.id, title: document.title, content: content, thumbnail: thumbnail)])
        } catch {
            return false
        }
        digests[document.id] = digest
        save()
        return true
    }

    /// The document was trashed or its local copy removed: out of the index.
    func remove(_ id: String) async {
        try? await index.delete([id])
        digests[id] = nil
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(digests) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The document id a Spotlight result's activity opens; nil for any other activity.
    static func documentID(of activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}
