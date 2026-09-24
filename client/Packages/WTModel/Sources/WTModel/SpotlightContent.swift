import WTCRDT

/// What Spotlight indexes of a document (saving.adoc, "Quick Look and Spotlight" and "Client";
/// IO-035): Document Info's description and keywords (file-info.adoc) and the plain text of
/// every live text node in tree order, one block per line, capped at 1 MiB of UTF-8.  The title
/// is the document's name, which the library holds, not the document.
public struct SpotlightContent: Hashable, Sendable {
    /// `SettingsProps.info.keywords`.
    static let keywordsPath = RegisterPath([2, 130, 4])

    /// The cap on `text`, in UTF-8 bytes.
    public static let textLimit = 1 << 20

    public var description: String
    public var keywords: [String]
    public var text: String

    public init(description: String = "", keywords: [String] = [], text: String = "") {
        self.description = description
        self.keywords = keywords
        self.text = text
    }

    /// The content of `state`.
    public static func of(_ state: EngineState) -> SpotlightContent {
        let settings = state.props(WellKnown.settings).settings
        var blocks: [String] = []
        var bytes = 0
        func visit(_ node: OpID) {
            guard bytes < textLimit else { return }
            if let text = state.textNode(node)?.string, !text.isEmpty {
                blocks.append(text)
                bytes += text.utf8.count + 1
            }
            for child in state.liveChildren(node) { visit(child) }
        }
        visit(WellKnown.document)
        // The keywords are an add-wins SET, read from its members (a typed read holds none).
        let keywords = state.store.members(WellKnown.settings, keywordsPath).map { String(decoding: $0, as: UTF8.self) }.sorted()
        return SpotlightContent(description: settings.info.description_p, keywords: keywords,
                                text: capped(blocks.joined(separator: "\n"), limit: textLimit))
    }

    /// `text` cut to at most `limit` UTF-8 bytes on a character boundary.
    static func capped(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
