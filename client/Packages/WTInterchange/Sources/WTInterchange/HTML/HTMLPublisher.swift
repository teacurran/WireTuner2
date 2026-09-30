// The HTML bundle writer (web/publish-html.adoc, "What the folder contains" and "Client"; WEB-008):
// a folder holding `index.html` (and `page-N.html` with *Separate files*), `style.css`, one SVG or
// PNG per page under `pages/` (or one file per top-level object under `objects/` with *Positioned
// objects*), from an `ExportScene` and an HTML setting.  Output is deterministic for a given
// scene and setting -- pages are named by number, objects by page and stacking position -- so
// republishing over a folder rewrites only files whose bytes changed.
//
// Page links become `#page-N` (Stacked) or `page-N.html` (Separate files); object links live
// inside SVG pages as `<a>` (so a page with links is embedded with `<object>`, which follows
// anchors, rather than `<img>`), and in PNG pages as an image map.

import Foundation
import WTGeometry
import WTRender

/// A published bundle: its files by relative path and the output warnings.
public struct HTMLBundle: Sendable {
    /// Relative paths (normalized, no "..") to contents, in a stable order.
    public var files: [(path: String, data: Data)]
    public var warnings: ExportWarnings

    /// The file at `path`.
    public func file(_ path: String) -> Data? {
        files.first { $0.path == path }?.data
    }

    /// The file at `path` as UTF-8 text.
    public func text(_ path: String) -> String? {
        file(path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Writes the bundle into `folder`, creating it; a file whose bytes are already there is not
    /// rewritten.  Returns the paths written.
    @discardableResult
    public func write(to folder: URL) throws -> [String] {
        var written: [String] = []
        do {
            for (path, data) in files {
                let url = folder.appendingPathComponent(path)
                if let existing = try? Data(contentsOf: url), existing == data { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                written.append(path)
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return written
    }
}

/// Builds HTML bundles.
public struct HTMLPublisher: Sendable {
    public var settings: HTMLPublishSettings

    public init(settings: HTMLPublishSettings = .defaults) {
        self.settings = settings
    }

    /// The largest PNG page side in pixels; larger pages are clamped and listed.
    public static let maxPixels = 16_384.0

    /// The bundle of `scene`'s pages.  `progress` is told the pages done and the page count after
    /// each page; between pages the current task's cancellation is checked, so a cancelled publish
    /// stops with `CancellationError`.
    public func publish(_ scene: ExportScene, progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> HTMLBundle {
        try settings.validate()
        guard !scene.pages.isEmpty else { throw ExportError.nothingToExport }
        let numbers = WebLinks.pageNumbers(scene)
        var pageHrefs: [Int: String] = [:]
        for number in numbers {
            pageHrefs[number] = settings.pageMode == .stacked ? "#page-\(number)" : (number == numbers[0] ? "index.html" : "page-\(number).html")
        }
        // An SVG page sits in `pages/` or `objects/` inside an `<object>`: its page links name the
        // HTML file from there and open in the top window (`SVGWriter.sameTabTarget`).
        let svgPageHrefs = pageHrefs.mapValues { $0.hasPrefix("#") ? "../index.html" + $0 : "../" + $0 }
        var files: [(String, Data)] = []
        var warnings = ExportWarnings()
        var bodies: [String] = []
        let svgOptions = SVGOptions(precision: 2, text: textMode, ids: .fromNames, styling: .presentationAttributes, responsive: true,
                                    pageBackground: false, minify: true, includeDocumentInfo: false)
        let flattener = SVGExporter.flattener(options: svgOptions, scene: scene)
        let animated = animatedPages(scene, options: svgOptions, pageHrefs: svgPageHrefs)
        var animationRules: [String]?
        for index in scene.pages.indices {
            try Task.checkCancellation()
            let number = numbers[index]
            let overlay = HTMLAnimations.overlay(scene.pages[index], number: number, scene: scene, settings: settings)
            let page = overlay.page
            files += overlay.files
            warnings.append(contentsOf: overlay.warnings)
            if !overlay.elements.isEmpty { animationRules = (animationRules ?? []) + overlay.rules }
            let flat = flattener.flatten(page, scene: scene)
            for note in flat.report.notes where note.contains("rasteriz") {
                warnings.append(ExportWarning(.rasterizedEffect, page: number, "Page \(number): \(note)."))
            }
            let size = page.bounds.size
            let body: String
            switch settings.layout {
            case .wholePages:
                body = try wholePage(page, flat: flat.page, number: number, scene: scene, svgOptions: svgOptions, pageHrefs: pageHrefs,
                                     svgPageHrefs: svgPageHrefs, animated: animated?[index], files: &files, warnings: &warnings)
            case .positionedObjects:
                body = try positionedObjects(page, number: number, scene: scene, svgOptions: svgOptions, pageHrefs: pageHrefs, svgPageHrefs: svgPageHrefs,
                                             files: &files, warnings: &warnings)
            }
            bodies.append("<section id=\"page-\(number)\" class=\"page\" style=\"width:\(HTMLText.number(size.width))px;height:\(HTMLText.number(size.height))px\">\(body)\(overlay.elements.joined())</section>")
            progress?(index + 1, scene.pages.count)
        }
        var links = WebLinks.warnings(scene)
        if settings.vectorFormat == .png {
            let strokeOnly = scene.pages.reduce(into: Set<NodeID>()) { $0.formUnion(HTMLImageMap.strokeOnly(flattener.flatten($1, scene: scene).page.nodes)) }
            links = WebLinks.warnings(scene, strokeOnlyNodes: strokeOnly)
        }
        warnings.append(contentsOf: links)
        let title = settings.title.isEmpty ? scene.name : settings.title
        switch settings.pageMode {
        case .stacked:
            files.append(("index.html", html(title: title, body: bodies.joined(separator: "\n"))))
        case .separateFiles:
            for (index, body) in bodies.enumerated() {
                var navigation: [String] = []
                if index > 0 { navigation.append("<a rel=\"prev\" href=\"\(pageHrefs[numbers[index - 1]]!)\">Previous</a>") }
                if index + 1 < bodies.count { navigation.append("<a rel=\"next\" href=\"\(pageHrefs[numbers[index + 1]]!)\">Next</a>") }
                let nav = navigation.isEmpty ? "" : "\n<nav>\(navigation.joined(separator: " "))</nav>"
                files.append((index == 0 ? "index.html" : "page-\(numbers[index]).html", html(title: title, body: body + nav)))
            }
        }
        files.append(("style.css", Data((stylesheet(scene) + animationStyles(animationRules)).utf8)))
        // Pages share content-named images and fonts: each path once.
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.0).inserted }
        let sorted = unique.sorted { $0.0 < $1.0 }.map { (path: $0.0, data: $0.1) }
        return HTMLBundle(files: sorted, warnings: ExportWarnings(warnings.sorted))
    }

    var textMode: SVGOptions.Text {
        switch settings.fontMode {
        case .embed: .asTextEmbedFonts
        case .outlines: .outlines
        case .system: .asText
        }
    }

    /// The animated SVG of each page when the document is animated from its layers and the
    /// setting includes animation (SVG output only); nil otherwise.
    func animatedPages(_ scene: ExportScene, options: SVGOptions, pageHrefs: [Int: String]) -> [SVGDocument]? {
        guard !settings.animationStill, settings.vectorFormat == .svg, settings.layout == .wholePages, let animation = scene.animation,
              animation.frames.first?.page == nil else { return nil }
        let documents = try? AnimatedSVGExporter().documents(scene: scene, options: {
            var animated = AnimatedSVGOptions(svg: options)
            animated.nestsSVGAnimations = false
            animated.sameTabTarget = "_top"
            return animated
        }(), pageHrefs: pageHrefs)
        return documents?.count == scene.pages.count ? documents : nil
    }

    /// Where SVG pages put their images and fonts: `images/` and `fonts/` beside `pages/` and
    /// `objects/`, in the setting's image format and quality.
    var linkedFiles: SVGLinkedFiles {
        SVGLinkedFiles(imageFolder: "../images", fontFolder: "../fonts", imageFormat: settings.imageFormat, imageQuality: settings.imageQuality)
    }

    /// Adds an SVG page's linked images and fonts to the bundle (their paths relative to the
    /// bundle) and warns about text outlined because its font forbids embedding.
    func addLinkedFiles(_ document: SVGDocument, page number: Int, files: inout [(String, Data)], warnings: inout ExportWarnings) {
        for resource in document.resources {
            files.append((String(resource.path.dropFirst(3)), resource.data))
        }
        for font in document.outlinedFonts {
            let reason = font.restricted ? "its license does not allow embedding" : "it cannot be embedded as a subset"
            warnings.append(ExportWarning(.outlinedFont, node: font.node, page: number, "Page \(number): \(font.postScriptName) was converted to outlines because \(reason)."))
        }
    }

    /// The rules of placed animations' wrappers; nothing when the bundle has none.
    func animationStyles(_ rules: [String]?) -> String {
        guard let rules else { return "" }
        return ([".anim{position:absolute;left:0;top:0;display:block;transform-origin:0 0}", ".anim>svg{display:block;width:100%;height:100%}"] + rules)
            .joined(separator: "\n") + "\n"
    }

    // MARK: Whole pages

    func wholePage(_ page: ExportPage, flat: FlatPage, number: Int, scene: ExportScene, svgOptions: SVGOptions, pageHrefs: [Int: String],
                   svgPageHrefs: [Int: String], animated: SVGDocument?, files: inout [(String, Data)], warnings: inout ExportWarnings) throws -> String {
        let alt = HTMLText.escape("\(scene.name), page \(number)")
        let size = page.bounds.size
        // HTML's `width` and `height` are integers; the style sheet sizes the picture to the
        // page's exact CSS size.
        let dimensions = "width=\"\(Int(size.width.rounded()))\" height=\"\(Int(size.height.rounded()))\""
        switch settings.vectorFormat {
        case .svg:
            let path = "pages/page-\(number).svg"
            let document = animated ?? SVGWriter(options: svgOptions, pageHrefs: svgPageHrefs, linkedFiles: linkedFiles, sameTabTarget: "_top").write(flat, scene: scene)
            files.append((path, Data(document.text.utf8)))
            addLinkedFiles(document, page: number, files: &files, warnings: &warnings)
            // `<img>` follows no anchors and loads no other file: a page with links, images or
            // fonts is embedded as an object.
            if document.text.contains("<a ") || !document.resources.isEmpty {
                return "<object data=\"\(path)\" type=\"image/svg+xml\" \(dimensions) aria-label=\"\(alt)\"></object>"
            }
            return "<img src=\"\(path)\" \(dimensions) alt=\"\(alt)\">"
        case .png:
            let path = "pages/page-\(number).png"
            let data = try png(page, scene: scene, number: number, warnings: &warnings)
            files.append((path, data))
            let areas = HTMLImageMap.areas(flat, scene: scene, pageHrefs: pageHrefs)
            guard !areas.isEmpty else { return "<img src=\"\(path)\" \(dimensions) alt=\"\(alt)\">" }
            let map = "<map name=\"map-\(number)\">\(areas.map(\.html).joined())</map>"
            return "<img src=\"\(path)\" \(dimensions) alt=\"\(alt)\" usemap=\"#map-\(number)\">\(map)"
        }
    }

    /// `page` rendered as PNG at *Scale*, clamped to 16,384 pixels on a side, over *Page
    /// background* -- or over nothing for an object file, which must not hide what lies beneath it
    /// on the page (`object`).
    func png(_ page: ExportPage, scene: ExportScene, number: Int, object: Bool = false, warnings: inout ExportWarnings) throws -> Data {
        var scale = Double(settings.scale)
        let side = max(page.bounds.width, page.bounds.height) * scale
        if side > Self.maxPixels {
            scale = Self.maxPixels / max(page.bounds.width, page.bounds.height)
            warnings.append(ExportWarning(.clampedPage, page: number, "Page \(number) is larger than 16,384 pixels at \(settings.scale)× and was reduced."))
        }
        var single = scene
        single.pages = [page]
        let background: BitmapCommonOptions.Background = switch settings.background {
        case _ where object: .transparent
        case .transparent: .transparent
        case .white: .white
        case .document: .pageColor
        }
        let options = PNGOptions(common: BitmapCommonOptions(scales: [scale], background: background))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let summary = try BitmapExporter(format: .png).export(scene: single, options: options, to: ExportDestination(url: folder.appendingPathComponent("page.png")))
        guard let url = summary.files.first else { throw ExportError.nothingToExport }
        return try Data(contentsOf: url)
    }

    // MARK: Positioned objects

    /// One file per top-level object of `page`, placed with CSS in stacking order.
    func positionedObjects(_ page: ExportPage, number: Int, scene: ExportScene, svgOptions: SVGOptions, pageHrefs: [Int: String],
                           svgPageHrefs: [Int: String], files: inout [(String, Data)], warnings: inout ExportWarnings) throws -> String {
        var elements: [String] = []
        var stack = 0
        let flattener = SVGExporter.flattener(options: svgOptions, scene: scene)
        for (top, item) in page.displayList.items.enumerated() {
            // Pages are regrouped one group per layer; the layer's members are the objects.
            let members: [(item: DisplayItem, path: [Int])]
            if case .group(let group) = item, scene.info(for: page.nodeID(at: [top]))?.isLayer == true {
                members = group.children.enumerated().map { ($0.element, [top, $0.offset]) }
            } else {
                members = [(item, [top])]
            }
            for member in members {
                guard let bounds = member.item.bounds?.intersection(page.bounds).nonEmpty else { continue }
                stack += 1
                var nested: [[Int]: NodeID] = [:]
                if let id = page.nodeID(at: member.path) { nested[[0]] = id }
                for (path, id) in page.nestedNodeIDs where path.starts(with: member.path) && path.count > member.path.count {
                    nested[[0] + path.dropFirst(member.path.count)] = id
                }
                let list = DisplayList(canvas: page.displayList.canvas, items: [member.item], nodeIDs: [nested[[0]]])
                let objectPage = ExportPage(bounds: bounds, displayList: list, nestedNodeIDs: nested, number: number)
                let flat = flattener.flatten(objectPage, scene: scene).page
                let name = "objects/page-\(number)-\(stack)"
                let left = HTMLText.number(bounds.minX - page.bounds.minX), topEdge = HTMLText.number(bounds.minY - page.bounds.minY)
                let style = "left:\(left)px;top:\(topEdge)px;width:\(HTMLText.number(bounds.width))px;height:\(HTMLText.number(bounds.height))px;z-index:\(stack)"
                let alt = HTMLText.escape(scene.info(for: nested[[0]])?.alt ?? "")
                switch settings.vectorFormat {
                case .svg:
                    let document = SVGWriter(options: svgOptions, pageHrefs: svgPageHrefs, linkedFiles: linkedFiles, sameTabTarget: "_top").write(flat, scene: scene)
                    files.append((name + ".svg", Data(document.text.utf8)))
                    addLinkedFiles(document, page: number, files: &files, warnings: &warnings)
                    let tag = document.text.contains("<a ") || !document.resources.isEmpty ? "<object data=\"\(name).svg\" type=\"image/svg+xml\" style=\"\(style)\" aria-label=\"\(alt)\"></object>"
                        : "<img src=\"\(name).svg\" style=\"\(style)\" alt=\"\(alt)\">"
                    elements.append(tag)
                case .png:
                    files.append((name + ".png", try png(objectPage, scene: scene, number: number, object: true, warnings: &warnings)))
                    let areas = HTMLImageMap.areas(flat, scene: scene, pageHrefs: pageHrefs)
                    if areas.isEmpty {
                        elements.append("<img src=\"\(name).png\" style=\"\(style)\" alt=\"\(alt)\">")
                    } else {
                        let map = "map-\(number)-\(stack)"
                        elements.append("<img src=\"\(name).png\" style=\"\(style)\" alt=\"\(alt)\" usemap=\"#\(map)\"><map name=\"\(map)\">\(areas.map(\.html).joined())</map>")
                    }
                }
            }
        }
        return elements.joined()
    }

    // MARK: HTML and CSS

    func html(title: String, body: String) -> Data {
        let page = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTMLText.escape(title))</title>
        <link rel="stylesheet" href="style.css">
        </head>
        <body>
        \(body)
        </body>
        </html>

        """
        return Data(page.utf8)
    }

    func stylesheet(_ scene: ExportScene) -> String {
        let background: String
        switch settings.background {
        case .transparent: background = "transparent"
        case .white: background = "#ffffff"
        case .document: background = scene.pages.first?.background.map(Self.css) ?? "#ffffff"
        }
        return """
        body{margin:0;padding:24px 0;background:#e6e6e6}
        .page{position:relative;margin:0 auto 24px;background:\(background);overflow:hidden}
        .page>img,.page>object{display:block;width:100%;height:100%}
        .page img[style],.page object[style]{position:absolute;display:block}
        nav{text-align:center;font:14px -apple-system,sans-serif}

        """
    }

    /// A colour as CSS hex: the sRGB fallback of CMS-015's serializer (gamut-mapped by COLOR-024).
    static func css(_ color: Color) -> String {
        WTColor.CSS.serialize(color).fallback
    }
}
