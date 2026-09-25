import AppKit
import Observation
import SwiftUI
import WebKit

/// One page of the bundled guide (panels.adoc, "The Help panel"; BASIC-007).
struct HelpPage: Hashable, Sendable, Identifiable {
    let slug: String
    let title: String
    let group: String
    let summary: String
    let headings: [String]
    let keywords: [String]
    var id: String { slug }
}

/// The bundled guide: its pages, the search over them, and each page as HTML.  The pages ship in
/// the app (`HelpCatalog.pages`, generated from the guide), so help works offline; a Help Book
/// folder in the bundle, when the docs render job provides one, is shown instead of the generated
/// page.
enum HelpCatalog {
    /// The pages matching `query`, best first: every word of the query must appear in the title,
    /// a heading, the summary or the keywords; a title match counts most, then headings, then
    /// keywords, then the summary.
    static func search(_ query: String, in pages: [HelpPage] = HelpCatalog.pages) -> [HelpPage] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let scored = pages.compactMap { page -> (HelpPage, Int)? in
            var total = 0
            for word in words {
                var score = 0
                if page.title.lowercased().contains(word) { score += 100 }
                if page.headings.contains(where: { $0.lowercased().contains(word) }) { score += 30 }
                if let rank = page.keywords.firstIndex(where: { $0.hasPrefix(word) }) { score += 20 - min(rank / 2, 19) }
                if page.summary.lowercased().contains(word) { score += 5 }
                guard score > 0 else { return nil }
                total += score
            }
            return (page, total)
        }
        return scored.sorted { ($0.1, $1.0.title) > ($1.1, $0.0.title) }.map(\.0)
    }

    static func page(_ slug: String, in pages: [HelpPage] = HelpCatalog.pages) -> HelpPage? {
        pages.first { $0.slug == slug }
    }

    /// The pages by group, in guide order.
    static var contents: [(group: String, pages: [HelpPage])] {
        var order: [String] = []
        var groups: [String: [HelpPage]] = [:]
        for page in pages {
            if groups[page.group] == nil { order.append(page.group) }
            groups[page.group, default: []].append(page)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// The HTML the panel shows for `page`.
    static func html(_ page: HelpPage) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let sections = page.headings.map { "<li>\(escape($0))</li>" }.joined()
        return """
        <html><head><meta charset="utf-8"><style>body{font:13px -apple-system;margin:12px;color:CanvasText;background:Canvas}h1{font-size:17px}</style></head>
        <body><h1>\(escape(page.title))</h1><p>\(escape(page.summary))</p>\(sections.isEmpty ? "" : "<h2>On this page</h2><ul>\(sections)</ul>")</body></html>
        """
    }

    /// A bundled Help Book page for `slug`, when the app carries one.
    static func bookURL(_ slug: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: slug, withExtension: "html", subdirectory: "HelpBook")
    }

    /// What's New in this version.
    static let whatsNew: [(title: String, slug: String)] = [
        ("The Text Editor window", "editing-text"), ("Find and Replace Text and spelling", "editing-text"), ("The text ruler", "tabs-indents"),
        ("The Paragraph section", "paragraphs"), ("Flow Around Selection", "text-effects"), ("The Calligraphic Pen", "freeform"),
        ("The Eraser", "editing-paths"), ("The Chart tool", "charts"), ("Quick Export and drag export", "exporting"),
        ("Alt text and Decorative", "names-notes"),
    ]
}

/// The Help panel's state: the search, the page shown, *What's here* and *What's New*.
@MainActor
@Observable
final class HelpBrowserModel {
    enum Mode: Equatable {
        case contents
        case results
        case page(String)
        case whatsNew
    }

    var query = "" {
        didSet { mode = query.trimmingCharacters(in: .whitespaces).isEmpty ? .contents : .results }
    }
    private(set) var mode = Mode.contents
    /// What the pointer rests on (*What's here*): a name and its page.
    private(set) var hover: (title: String, slug: String)?

    init() {}

    var results: [HelpPage] { HelpCatalog.search(query) }

    var page: HelpPage? {
        if case .page(let slug) = mode { return HelpCatalog.page(slug) }
        return nil
    }

    func open(_ slug: String) {
        mode = .page(slug)
    }

    func showContents() {
        query = ""
        mode = .contents
    }

    func showWhatsNew() {
        mode = .whatsNew
    }

    func setHover(_ title: String, slug: String) {
        hover = (title, slug)
    }

    /// *Help for <panel>*: the panel model's page, when it names one.
    func follow(_ help: HelpPanelModel) {
        if let slug = help.slug, !slug.isEmpty, HelpCatalog.page(slug) != nil { mode = .page(slug) }
    }
}

/// The page view: the Help Book's page when bundled, else the generated one.
struct HelpPageView: NSViewRepresentable {
    let page: HelpPage

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setAccessibilityIdentifier("help.page")
        load(page, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(page, in: view)
    }

    func load(_ page: HelpPage, in view: WKWebView) {
        if let url = HelpCatalog.bookURL(page.slug) {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.loadHTMLString(HelpCatalog.html(page), baseURL: nil)
        }
    }
}

/// The Help panel: the search field, the contents or results or page, *What's here*, and
/// btn:[What's New].
struct HelpBrowserView: View {
    @Bindable var model: HelpBrowserModel
    let help: HelpPanelModel

    static func opening(_ slug: String, _ model: HelpBrowserModel) -> () -> Void {
        { model.open(slug) }
    }

    static func following(_ model: HelpBrowserModel, _ help: HelpPanelModel) -> (String?, String?) -> Void {
        { _, _ in model.follow(help) }
    }

    @ViewBuilder
    func link(_ page: HelpPage) -> some View {
        Button(page.title, action: Self.opening(page.slug, model)).buttonStyle(.link).accessibilityIdentifier("help.link.\(page.slug)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search Help", text: $model.query).textFieldStyle(.roundedBorder).accessibilityIdentifier("help.search")
                Button("Contents", action: model.showContents)
                Button("What's New", action: model.showWhatsNew).accessibilityIdentifier("help.whatsNew")
            }
            if let hover = model.hover {
                HStack {
                    Text("What's here: \(hover.title)").font(.caption)
                    Button("Open", action: Self.opening(hover.slug, model)).buttonStyle(.link).font(.caption)
                }
                .accessibilityIdentifier("help.whatsHere")
            }
            switch model.mode {
            case .contents:
                List(HelpCatalog.contents, id: \.group) { section in
                    Section(section.group.isEmpty ? "Guide" : section.group) { ForEach(section.pages) { link($0) } }
                }
            case .results:
                List(model.results) { page in
                    VStack(alignment: .leading) {
                        link(page)
                        Text(page.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .accessibilityIdentifier("help.results")
            case .page:
                if let page = model.page { HelpPageView(page: page) }
            case .whatsNew:
                List(HelpCatalog.whatsNew, id: \.title) { item in
                    Button(item.title, action: Self.opening(item.slug, model)).buttonStyle(.link)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: help.slug, Self.following(model, help))
        .onAppear { model.follow(help) }
    }
}
