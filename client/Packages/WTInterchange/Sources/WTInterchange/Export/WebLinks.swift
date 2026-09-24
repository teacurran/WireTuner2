// Links in exported files (web/urls.adoc "How links survive export", web/interactivity.adoc "Links
// in exported files"; WEB-005, WEB-023): the link facts a snapshot carries beside the artwork,
// the scheme completion every exporter applies, and the anchor an object's click resolves to --
// a page link wins over a URL (interactivity.adoc, "the precedence rule").

import Foundation
import WTGeometry
import WTRender

/// Where a link opens in HTML and SVG output (`NavigationProps.target`).  PDF ignores it.
public enum ExportLinkTarget: String, Hashable, Sendable, Codable {
    case sameWindow
    case newTab
}

/// A text-range link (`link` mark) as laid out: its URL, the link's alt text and one rectangle
/// per line of the range, in pasteboard space.
public struct ExportTextLink: Hashable, Sendable {
    public var url: String
    public var alt: String?
    public var rects: [Rect]

    public init(url: String, alt: String? = nil, rects: [Rect]) {
        self.url = url
        self.alt = alt
        self.rects = rects
    }
}

/// What clicking an object does in an exported file.
public enum ExportLinkAction: Hashable, Sendable {
    /// Open the URL (already completed by `WebLinks.href`).
    case uri(String)
    /// Go to the document page with this number (1-based).
    case page(Int)
}

/// Scheme completion and validity of link addresses, and the resolved click of an object.
public enum WebLinks {
    /// File extensions that make a scheme-less address a relative link, not a host name
    /// (`page-2.html`, `logo.svg`).
    static let fileExtensions: Set<String> = [
        "html", "htm", "xhtml", "svg", "svgz", "png", "jpg", "jpeg", "gif", "webp", "avif", "pdf", "css", "js", "json", "xml", "txt", "php",
        "asp", "aspx", "jsp", "md", "mp4", "mov", "zip",
    ]

    /// The address written for `url` (urls.adoc, "Attaching a link"): stored exactly as typed,
    /// `https://` added when the link has no scheme and looks like a host name; `mailto:` and
    /// other schemes, and relative links (`page-2.html`, `#top`, `/about`), pass through
    /// unchanged.  Nil when the address cannot be made valid (listed by the output warnings).
    public static func href(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = hasScheme(trimmed) || !looksLikeHost(trimmed) ? trimmed : "https://" + trimmed
        return isValid(candidate) ? candidate : nil
    }

    /// Whether `url` starts with an RFC 3986 scheme (`letter *( letter / digit / "+" / "-" / "." ) ":"`).
    static func hasScheme(_ url: String) -> Bool {
        guard let colon = url.firstIndex(of: ":") else { return false }
        let scheme = url[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        // "localhost:8080" and "example.com:443/x" are host names with ports, not schemes.
        if scheme.contains(".") || url[url.index(after: colon)...].first?.isNumber == true { return false }
        return scheme.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) }
    }

    /// Whether a scheme-less address looks like a host name: its first segment holds a dot, its
    /// last label is letters (a top-level domain) and is not a file extension.
    static func looksLikeHost(_ url: String) -> Bool {
        guard let first = url.first, !"./#?".contains(first) else { return false }
        let host = url.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? url
        let name = host.split(separator: ":").first.map(String.init) ?? host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last else { return false }
        guard tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else { return false }
        return !fileExtensions.contains(tld.lowercased())
    }

    /// Whether `url` parses as a URL once characters browsers percent-encode are encoded.
    static func isValid(_ url: String) -> Bool {
        guard !url.contains(where: { $0.isNewline || $0 == "\t" }), !url.contains(" ") || url.hasPrefix("mailto:") else { return false }
        let allowed = CharacterSet.urlFragmentAllowed.union(.urlQueryAllowed).union(.urlPathAllowed).union(CharacterSet(charactersIn: "#%:@"))
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed), let parsed = URL(string: encoded) else { return false }
        if let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return parsed.host?.isEmpty == false
        }
        return true
    }

    /// What clicking the object `info` describes does: its page link when that page is among
    /// `pages` (the document page numbers the output holds), else its URL made valid; nil for
    /// nothing (no link, an invalid address, or a page link to a page left out).
    public static func action(_ info: ExportNodeInfo?, pages: Set<Int>) -> ExportLinkAction? {
        guard let info else { return nil }
        if let page = info.pageLink, pages.contains(page) { return .page(page) }
        if info.pageLink != nil, info.url == nil { return nil }
        return info.url.flatMap(href).map(ExportLinkAction.uri)
    }

    /// The document page numbers of `scene`'s pages (`ExportPage.number`, else position + 1).
    public static func pageNumbers(_ scene: ExportScene) -> [Int] {
        scene.pages.enumerated().map { $0.element.number ?? $0.offset + 1 }
    }

    /// The warnings the links of `scene` raise (WEB-010): each address that cannot be made valid,
    /// each object whose page link overrides its URL (the unused link), each page link to a page
    /// the output leaves out, and each link on a stroke-only path when `strokeOnlyNodes` names it
    /// (image maps respond on the stroke only).  Stable order: by node id.
    public static func warnings(_ scene: ExportScene, strokeOnlyNodes: Set<NodeID> = []) -> [ExportWarning] {
        let pages = Set(pageNumbers(scene))
        var result: [ExportWarning] = []
        for node in scene.nodes.keys.sorted() {
            let info = scene.nodes[node]!
            if let url = info.url {
                if info.pageLink != nil {
                    result.append(ExportWarning(.unusedLink, node: node, "The link \(url) is not used: the object goes to page \(info.pageLink!) when clicked."))
                } else if href(url) == nil {
                    result.append(ExportWarning(.invalidLink, node: node, "The link \(url) is not a valid address."))
                } else if strokeOnlyNodes.contains(node) {
                    result.append(ExportWarning(.strokeOnlyLink, node: node, "A link on a path with a stroke and no fill responds only on the stroke in image maps."))
                }
            }
            if let page = info.pageLink, !pages.contains(page) {
                result.append(ExportWarning(.missingPage, node: node, "The link to page \(page) is left out: that page is not in the output."))
            }
        }
        for node in scene.textLinks.keys.sorted() {
            for link in scene.textLinks[node]! where href(link.url) == nil {
                result.append(ExportWarning(.invalidLink, node: node, "The link \(link.url) is not a valid address."))
            }
        }
        return result
    }
}
