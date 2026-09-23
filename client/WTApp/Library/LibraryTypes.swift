import Foundation

/// A space the library can show: the account's own (Personal) or one team
/// (creating-opening.adoc, "Search covers the space you are looking at").  The personal space's
/// id is the account id (server.adoc, "a space is the caller's own account or a team").
struct LibrarySpace: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case personal, team
    }

    static let personalName = "Personal"

    var id: String
    var name: String
    var kind: Kind

    static func personal(id: String) -> LibrarySpace {
        LibrarySpace(id: id, name: personalName, kind: .personal)
    }
}

/// A document as the library lists it: the `docs.v1.Document` fields the window shows, plus
/// the local flags the cache keeps.
struct LibraryDocument: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The caller's role, shown in *Shared with me*.
    enum Role: String, Codable, Sendable {
        case owner, editor, commenter, viewer

        var title: String { rawValue.capitalized }
    }

    var id: String
    var spaceID: String
    /// nil: the space's top level.
    var folderID: String?
    var name: String
    var role: Role?
    var updatedAt: Date?
    /// Hex sha256 of the thumbnail blob; nil when none was uploaded yet.
    var thumbnail: String?
    var thumbnailAt: Date?
    var isTrashed: Bool
    /// Created on this Mac while offline: `DocumentService.Create` has not run yet (the
    /// *Waiting to upload* badge).
    var isPendingUpload: Bool
    /// Listed under *Shared with me*.
    var isSharedWithMe: Bool

    init(
        id: String, spaceID: String, folderID: String? = nil, name: String, role: Role? = .owner, updatedAt: Date? = nil,
        thumbnail: String? = nil, thumbnailAt: Date? = nil, isTrashed: Bool = false, isPendingUpload: Bool = false,
        isSharedWithMe: Bool = false
    ) {
        self.id = id
        self.spaceID = spaceID
        self.folderID = folderID
        self.name = name
        self.role = role
        self.updatedAt = updatedAt
        self.thumbnail = thumbnail
        self.thumbnailAt = thumbnailAt
        self.isTrashed = isTrashed
        self.isPendingUpload = isPendingUpload
        self.isSharedWithMe = isSharedWithMe
    }
}

/// A folder in a space.
struct LibraryFolder: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var spaceID: String
    /// nil: at the space's top level.
    var parentID: String?
    var name: String
}

/// What `DocumentService.List` is asked for.
struct LibraryListRequest: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        /// A folder of the space; nil is the top level.
        case folder(String?)
        case sharedWithMe
    }

    static let pageSize = 100

    var spaceID: String?
    var scope: Scope
    var cursor: String?
}

/// One page of `List`.
struct LibraryPage: Equatable, Sendable {
    var documents: [LibraryDocument]
    var folders: [LibraryFolder]
    /// nil when there are no more pages.
    var nextCursor: String?

    /// The page of a *Shared with me* listing.
    var markedShared: LibraryPage {
        var page = self
        for index in page.documents.indices { page.documents[index].isSharedWithMe = true }
        return page
    }
}

/// The field a search match was found in (`docs.v1.SearchField`).
enum LibrarySearchField: String, Equatable, Sendable, CaseIterable {
    case documentName, objectName, text, note, swatch, style, symbol, keyword, page, other

    /// Shown before the snippet: "Text: Spring **Sale** starts".
    var title: String {
        switch self {
        case .documentName: "Name"
        case .objectName: "Object name"
        case .text: "Text"
        case .note: "Note"
        case .swatch: "Swatch"
        case .style: "Style"
        case .symbol: "Symbol"
        case .keyword: "Keyword"
        case .page: "Page"
        case .other: "Match"
        }
    }
}

/// A run of snippet text, highlighted when it is (part of) the match.
struct HighlightSegment: Equatable, Sendable {
    var text: String
    var isMatch: Bool
}

/// The matching text of one search match, split at the server's `<b>`...`</b>` markers
/// (`docs.v1.SearchMatch.highlighted`: "no other markup").
struct SearchSnippet: Equatable, Sendable {
    var field: LibrarySearchField
    var segments: [HighlightSegment]

    init(field: LibrarySearchField, segments: [HighlightSegment]) {
        self.field = field
        self.segments = segments
    }

    init(field: LibrarySearchField, highlighted: String) {
        self.init(field: field, segments: Self.parse(highlighted))
    }

    var plainText: String { segments.map(\.text).joined() }

    /// Splits `text` at `<b>` and `</b>`; an unclosed `<b>` highlights to the end.  Empty runs
    /// are dropped.
    static func parse(_ text: String) -> [HighlightSegment] {
        var segments: [HighlightSegment] = []
        var rest = Substring(text)
        var inMatch = false
        while !rest.isEmpty {
            let marker = inMatch ? "</b>" : "<b>"
            guard let range = rest.range(of: marker) else {
                segments.append(HighlightSegment(text: String(rest), isMatch: inMatch))
                break
            }
            let run = rest[rest.startIndex..<range.lowerBound]
            if !run.isEmpty { segments.append(HighlightSegment(text: String(run), isMatch: inMatch)) }
            rest = rest[range.upperBound...]
            inMatch.toggle()
        }
        return segments
    }
}

/// One `SearchHit`.
struct LibrarySearchHit: Equatable, Sendable {
    var documentID: String
    var snippets: [SearchSnippet]

    /// The snippet shown under the name: the first match inside the document, else the name
    /// match.
    var displaySnippet: SearchSnippet? {
        snippets.first { $0.field != .documentName } ?? snippets.first
    }
}

struct LibrarySearchPage: Equatable, Sendable {
    var hits: [LibrarySearchHit]
    var nextCursor: String?
}

/// A row of the library's grid: a document and, in search results, its matching text.
struct LibraryRow: Identifiable, Equatable, Sendable {
    var document: LibraryDocument
    var snippet: SearchSnippet?

    var id: String { document.id }
}

/// Client-generated document ids: UUIDv7 (RFC 9562), which `CreateRequest.document_id`
/// requires -- 48 bits of Unix milliseconds, version 7, the variant, 74 random bits.
enum UUIDv7 {
    static func make(
        milliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
        random: [UInt8] = (0..<10).map { _ in UInt8.random(in: .min ... .max) }
    ) -> String {
        precondition(random.count >= 10, "UUIDv7 needs 10 random bytes")
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * UInt64(5 - index))) }
        bytes[6] = 0x70 | (random[0] & 0x0F)
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3F)
        for index in 9..<16 { bytes[index] = random[index - 6] }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

extension Data {
    /// Lower-case hex, the form thumbnails are keyed by.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Parses lower- or upper-case hex; nil for anything else.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
