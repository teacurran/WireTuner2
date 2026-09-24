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

    /// The bundle of `scene`'s pages.
    public func publish(_ scene: ExportScene) throws -> HTMLBundle {
        try settings.validate()
        guard !scene.pages.isEmpty else { throw ExportError.nothingToExport }
        let numbers = WebLinks.pageNumbers(scene)
        var pageHrefs: [Int: String] = [:]
        for number in numbers {
            pageHrefs[number] = settings.pageMode == .stacked ? "#page-\(number)" : (number == numbers[0] ? "index.html" : "page-\(number).html")
        }
        var files: [(String, Data)] = []
        var warnings = ExportWarnings()
        var bodies: [String] = []
        let svgOptions = SVGOptions(precision: 2, text: textMode, ids: .fromNames, styling: .presentationAttributes, responsive: true,
                                    pageBackground: false, minify: true, includeDocumentInfo: false)
        let flattener = SVGExporter.flattener(options: svgOptions, scene: scene)
        let animated = animatedPages(scene, options: svgOptions, pageHrefs: pageHrefs)
        for (index, page) in scene.pages.enumerated() {
            let number = numbers[index]
            let flat = flattener.flatten(page, scene: scene)
            for note in flat.report.notes where note.contains("rasteriz") {
                warnings.append(ExportWarning(.rasterizedEffect, page: number, "Page \(number): \(note)."))
            }
            let size = page.bounds.size
            let body: String
            switch settings.layout {
            case .wholePages:
                body = try wholePage(page, flat: flat.page, number: number, scene: scene, svgOptions: svgOptions, pageHrefs: pageHrefs,
                                     animated: animated?[index], files: &files, warnings: &warnings)
            case .positionedObjects:
                body = try positionedObjects(page, number: number, scene: scene, svgOptions: svgOptions, pageHrefs: pageHrefs, files: &files, warnings: &warnings)
            }
            bodies.append("<section id=\"page-\(number)\" class=\"page\" style=\"width:\(HTMLText.number(size.width))px;height:\(HTMLText.number(size.height))px\">\(body)</section>")
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
        files.append(("style.css", Data(stylesheet(scene).utf8)))
        let sorted = files.sorted { $0.0 < $1.0 }.map { (path: $0.0, data: $0.1) }
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
        let documents = try? AnimatedSVGExporter().documents(scene: scene, options: AnimatedSVGOptions(svg: options), pageHrefs: pageHrefs)
        return documents?.count == scene.pages.count ? documents : nil
    }

    // MARK: Whole pages

    func wholePage(_ page: ExportPage, flat: FlatPage, number: Int, scene: ExportScene, svgOptions: SVGOptions, pageHrefs: [Int: String],
                   animated: SVGDocument?, files: inout [(String, Data)], warnings: inout ExportWarnings) throws -> String {
        let alt = HTMLText.escape("\(scene.name), page \(number)")
        let size = page.bounds.size
        let dimensions = "width=\"\(HTMLText.number(size.width))\" height=\"\(HTMLText.number(size.height))\""
        switch settings.vectorFormat {
        case .svg:
            let path = "pages/page-\(number).svg"
            let document = animated ?? SVGWriter(options: svgOptions, pageHrefs: pageHrefs).write(flat, scene: scene)
            files.append((path, Data(document.text.utf8)))
            // `<img>` does not follow anchors: a page with links is embedded as an object.
            if document.text.contains("<a ") {
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

    /// `page` rendered as PNG at *Scale*, clamped to 16,384 pixels on a side.
    func png(_ page: ExportPage, scene: ExportScene, number: Int, warnings: inout ExportWarnings) throws -> Data {
        var scale = Double(settings.scale)
        let side = max(page.bounds.width, page.bounds.height) * scale
        if side > Self.maxPixels {
            scale = Self.maxPixels / max(page.bounds.width, page.bounds.height)
            warnings.append(ExportWarning(.clampedPage, page: number, "Page \(number) is larger than 16,384 pixels at \(settings.scale)× and was reduced."))
        }
        var single = scene
        single.pages = [page]
        let transparent = settings.background == .transparent
        let options = PNGOptions(common: BitmapCommonOptions(scales: [scale], background: transparent ? .transparent : .pageColor))
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
                           files: inout [(String, Data)], warnings: inout ExportWarnings) throws -> String {
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
                    let document = SVGWriter(options: svgOptions, pageHrefs: pageHrefs).write(flat, scene: scene)
                    files.append((name + ".svg", Data(document.text.utf8)))
                    let tag = document.text.contains("<a ") ? "<object data=\"\(name).svg\" type=\"image/svg+xml\" style=\"\(style)\" aria-label=\"\(alt)\"></object>"
                        : "<img src=\"\(name).svg\" style=\"\(style)\" alt=\"\(alt)\">"
                    elements.append(tag)
                case .png:
                    files.append((name + ".png", try png(objectPage, scene: scene, number: number, warnings: &warnings)))
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
        .page>img,.page>object{display:block}
        .page img[style],.page object[style]{position:absolute;display:block}
        nav{text-align:center;font:14px -apple-system,sans-serif}

        """
    }

    /// A colour as CSS hex (sRGB).
    static func css(_ color: Color) -> String {
        let rgb = color.converted(to: .sRGB).components
        func hex(_ value: Double) -> String { String(format: "%02x", Int((min(max(value, 0), 1) * 255).rounded())) }
        return "#" + hex(rgb.x) + hex(rgb.y) + hex(rgb.z)
    }
}
