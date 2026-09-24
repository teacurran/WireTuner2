// WEB-018, WEB-006, WEB-008: animated SVG export, web export presets and the size estimate, and
// the HTML bundle writer.  Fixtures are built here; bundles are read back as text and the SVG
// pages through the SVG tree parser and validator.

import Foundation
import ImageIO
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct AnimatedSVGTests {
    @Test func framesAreGroupsWithStepKeyframesAndTheBackgroundOnce() throws {
        let scene = AnimationExportTests.scene(fps: 10, holds: [1, 3, 1])
        let documents = try AnimatedSVGExporter().documents(scene: scene)
        #expect(documents.count == 1)
        let text = documents[0].text
        let root = try #require(XMLTreeParser.parse(text))
        #expect(SVGValidator.problems(root).isEmpty)
        let groups = root.all("g")
        #expect(groups.filter { $0.attributes["class"] == "f" }.map { $0.attributes["id"] } == ["f0", "f1", "f2"])
        // The grey background bar is written once, outside the frames.
        #expect(groups.filter { $0.attributes["class"] == "bg" }.count == 1)
        #expect(root.all("path").count == 4)
        // 5 periods at 10 fps: 0.5 s; frame 1 holds 3 periods (20% ... 80%).
        #expect(text.contains("animation-duration:0.5s") && text.contains("animation-iteration-count:infinite"))
        #expect(text.contains("@keyframes wt-f1{0%{visibility:hidden}20%{visibility:visible}80%{visibility:hidden}100%{visibility:hidden}}"))
        #expect(text.contains("@keyframes wt-f0{0%{visibility:visible}20%{visibility:hidden}"))
        #expect(text.contains("@keyframes wt-f2{0%{visibility:hidden}80%{visibility:visible}100%{visibility:visible}}"))
        #expect(!text.contains("animation-play-state") && !text.contains("<script") && !text.contains("<animate"))
        #expect(documents[0].notes.contains("3 frames written as an animated SVG"))
        // White background rectangle behind every frame.
        #expect(root.all("rect").first?.attributes["fill"] == "#ffffff")
    }

    @Test func loopAutoplayAndBackgroundOverrides() throws {
        let scene = AnimationExportTests.scene(loop: false, background: .transparent)
        let text = try AnimatedSVGExporter().documents(scene: scene, options: AnimatedSVGOptions(fps: 5, autoplay: false))[0].text
        #expect(text.contains("animation-iteration-count:1") && text.contains("animation-play-state:paused"))
        #expect(text.contains("svg:hover .f,svg:active .f{animation-play-state:running}"))
        #expect(text.contains("animation-duration:1s"))
        #expect(!text.contains("<rect"))
        let page = try AnimatedSVGExporter().documents(scene: AnimationExportTests.scene(background: .pageColor), options: AnimatedSVGOptions(loop: true))[0].text
        #expect(page.contains("fill=\"#ffffcc\""))
        #expect(throws: ExportError.self) { try AnimatedSVGExporter().documents(scene: scene, options: AnimatedSVGOptions(fps: 0)) }
        var still = scene
        still.animation = nil
        #expect(throws: ExportError.nothingToExport) { try AnimatedSVGExporter().documents(scene: still) }
    }

    @Test func pagesSourceTranslatesEachFrameOntoTheFirstPage() throws {
        let pages = [Rect(x: 0, y: 0, width: 60, height: 60), Rect(x: 80, y: 0, width: 60, height: 60)]
        let scene = AnimationExportTests.scene(source: .pages, pages: pages)
        let documents = try AnimatedSVGExporter().documents(scene: scene)
        #expect(documents.count == 1)
        let root = try #require(XMLTreeParser.parse(documents[0].text))
        let frames = root.all("g").filter { $0.attributes["class"] == "f" }
        #expect(frames.count == 2 && frames[0].attributes["transform"] == nil && frames[1].attributes["transform"] == "translate(-80 0)")
        #expect(root.all("g").filter { $0.attributes["class"] == "bg" }.isEmpty)
        let only = try AnimatedSVGExporter().documents(scene: scene, options: AnimatedSVGOptions(pages: [1]))
        #expect(XMLTreeParser.parse(only[0].text)!.all("g").filter { $0.attributes["class"] == "f" }.count == 1)
        #expect(throws: ExportError.nothingToExport) { try AnimatedSVGExporter().documents(scene: scene, options: AnimatedSVGOptions(pages: [7])) }
        let url = AnimationExportTests.url("animated", .svg)
        let summary = try AnimatedSVGExporter().export(scene: scene, to: ExportDestination(url: url))
        #expect(summary.files.count == 1 && FileManager.default.fileExists(atPath: summary.files[0].path))
        #expect(AnimatedSVGTiming(holds: [1, 1], fps: 2) == AnimatedSVGTiming(holds: [1, 1], fps: 2))
        #expect(Set([AnimatedSVGTiming(holds: [1], fps: 1)]).count == 1)
        let one = try AnimatedSVGExporter().documents(scene: AnimationExportTests.scene(source: .pages, pages: [pages[0]]))[0].text
        #expect(one.contains("@keyframes wt-f0{0%{visibility:visible}100%{visibility:visible}}"))
    }
}

@Suite struct WebPresetTests {
    /// A page `side` points square of twenty coloured ellipses.
    static func page(side: Double = 1000) -> ExportScene {
        let cell = side / 5
        let items = (0..<20).map { index in
            Corpus.path(Corpus.ellipse(Double(index % 5) * cell, Double(index / 5) * cell * 1.25, cell * 0.9, cell * 1.15),
                        [Corpus.fill(.solid([Corpus.red, Corpus.blue, Corpus.green, Corpus.yellow][index % 4]))])
        }
        return Corpus.scene([Corpus.page(items, width: side, height: side)], info: ExportDocumentInfo(title: "Estimate", author: "Tea"))
    }

    @Test func theFourWebPresetsSetEveryOption() throws {
        #expect(WebExportPreset.builtIn.map(\.name) == ["Web — PNG 2×", "Web — JPEG 80", "Web — WebP 80", "Web — SVG"])
        let png = try #require(WebExportPreset.builtIn[0].options() as? PNGOptions)
        #expect(png.common.scales == [2] && png.common.background == .transparent && !png.common.embedProfile && png.bits == 32)
        let jpeg = try #require(WebExportPreset.builtIn[1].options() as? JPEGOptions)
        #expect(jpeg.quality == 80 && jpeg.common.background == .white && jpeg.progressive)
        let webp = try #require(WebExportPreset.builtIn[2].options() as? WebPOptions)
        #expect(webp.quality == 80 && webp.common.background == .transparent)
        let svg = try #require(WebExportPreset.builtIn[3].options() as? SVGOptions)
        #expect(svg.minify && svg.responsive && !svg.includeDocumentInfo)
        let avif = try #require(WebExportPreset(id: "a", name: "A", format: .avif, quality: 50).options() as? AVIFOptions)
        #expect(avif.quality == 50)
        let gif = try #require(WebExportPreset(id: "g", name: "G", format: .gif, transparent: false, matte: [0, 0, 1]).options() as? GIFOptions)
        #expect(!gif.transparent && gif.matte == Color(red: 0, green: 0, blue: 1))
        let opaque = try #require(WebExportPreset(id: "p", name: "P", format: .png, scale: 1, transparent: false).options() as? PNGOptions)
        #expect(opaque.bits == 24 && opaque.common.scales == [1])
        #expect(WebPresetFormat.allCases.map(\.exportFormat) == [.png, .jpeg, .webp, .avif, .gif, .svg])
        #expect(WebPresetFormat.avif.isAvailable == BitmapExporter.canEncode(.avif) && WebPresetFormat.png.isAvailable)
        // Strip metadata drops Document Info from the scene; keeping it keeps it.
        #expect(WebExportPreset.builtIn[0].scene(Self.page()).info.isEmpty)
        #expect(!WebExportPreset(id: "k", name: "K", format: .png, stripMetadata: false).scene(Self.page()).info.isEmpty)
        for bad in [WebExportPreset(id: "x", name: "X", format: .png, scale: 3), WebExportPreset(id: "x", name: "X", format: .png, quality: 0),
                    WebExportPreset(id: "x", name: " ", format: .png), WebExportPreset(id: "x", name: "X", format: .png, matte: [2, 0, 0])] {
            #expect(throws: ExportError.self) { try bad.validate() }
        }
    }

    @Test func theEstimateIsTheWrittenSize() throws {
        let scene = Self.page(side: 200)
        for preset in WebExportPreset.builtIn where preset.format.isAvailable {
            let estimate = try ExportSizeEstimate.bytes(scene: scene, preset: preset)
            let folder = Corpus.directory().appendingPathComponent("estimate-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let exporter = try ExportRegistry.standard.exporter(for: preset.format.exportFormat)
            let summary = try exporter.export(scene: preset.scene(scene), options: preset.options(), to: ExportDestination(url: folder.appendingPathComponent("x.\(preset.format.exportFormat.fileExtension)")))
            let written = try summary.files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            #expect(estimate > 0)
            #expect(abs(Double(estimate - written)) <= Double(written) * 0.05, "\(preset.name): \(estimate) vs \(written)")
        }
        #expect(ExportSizeEstimate.label(245_760).hasPrefix("About "))
    }

    /// WEB-006's budget: the estimate of a 2,000 × 2,000-pixel page within a second (perf run only).
    @Test(.enabled(if: PerfBudget.isMeasuring, "the perf run only: release with WT_PERF=1"))
    func theEstimateOfALargePageArrivesWithinASecond() throws {
        let start = ContinuousClock.now
        _ = try ExportSizeEstimate.bytes(scene: Self.page(side: 1000), preset: WebExportPreset.builtIn[0])
        PerfBudget.expect(ContinuousClock.now - start, within: .seconds(1), "PNG 2× estimate of a 2,000 × 2,000 px page")
    }

    @Test func webPAndAVIFKeepTransparency() throws {
        let scene = Corpus.scene([Corpus.page([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(Corpus.red))])], width: 40, height: 40)])
        for format in [WebPresetFormat.webp, .avif] where format.isAvailable {
            let preset = WebExportPreset(id: format.rawValue, name: format.rawValue, format: format, scale: 1)
            let folder = Corpus.directory().appendingPathComponent("alpha-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let summary = try BitmapExporter(format: format.exportFormat).export(scene: scene, options: preset.options(), to: ExportDestination(url: folder.appendingPathComponent("a.\(format.exportFormat.fileExtension)")))
            let source = try #require(CGImageSourceCreateWithURL(summary.files[0] as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            #expect(properties?[kCGImagePropertyHasAlpha] as? Bool == true, "\(format)")
        }
    }

    @Test func presetFilesRoundTripAndTheStoreKeepsUserPresets() throws {
        let mine = WebExportPreset(id: "mine", name: "Hero JPEG 60", format: .jpeg, scale: 1, quality: 60, stripMetadata: false, transparent: false, matte: [0.1, 0.2, 0.3])
        let data = try WebPresetFile.data([mine])
        #expect(try WebPresetFile.presets(from: data) == [mine])
        #expect(throws: ExportError.self) { try WebPresetFile.presets(from: Data("nope".utf8)) }
        #expect(throws: ExportError.self) { try WebPresetFile.presets(from: Data(#"{"version":99,"presets":[]}"#.utf8)) }
        #expect(WebPresetFile.fileExtension == "wtpreset")
        let suite = "wt.test.presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WebExportPresetStore(defaults: defaults)
        #expect(store.userPresets.isEmpty)
        try store.save(mine)
        #expect(store.userPresets == [mine])
        #expect(store.all.suffix(1) == [mine])
        #expect(throws: ExportError.self) { try store.save(WebExportPreset.builtIn[0]) }
        var renamed = mine
        renamed.name = "Hero"
        try store.save(renamed)
        #expect(store.userPresets == [renamed])
        try store.delete("mine")
        #expect(store.userPresets.isEmpty)
        let other = WebExportPreset(id: "other", name: "Other", format: .png)
        #expect(try store.importFile(WebPresetFile.data([mine, other, WebExportPreset.builtIn[1]])) == 2)
        #expect(store.userPresets.map(\.id) == ["mine", "other"])
        defaults.set(Data("junk".utf8), forKey: WebExportPresetStore.key)
        #expect(store.userPresets.isEmpty)
    }
}

@Suite struct HTMLPublisherTests {
    /// Two pages: page 1 holds a linked rectangle, a stroke-only linked wave and an object
    /// linking to page 2, inside a layer group; page 2 a plain square.
    static func scene() -> ExportScene {
        let (layer, url, wave, next) = (Corpus.node(1), Corpus.node(2), Corpus.node(3), Corpus.node(4))
        let group = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(10, 10, 40, 20), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.wave(10, 60, 80, 30), [Corpus.stroke(.solid(Corpus.blue), width: 2)]),
            Corpus.path(Corpus.ellipse(120, 10, 30, 30), [Corpus.fill(.solid(Corpus.green))]),
        ]))
        var first = Corpus.page([group], nodes: [layer], background: Color(red: 1, green: 1, blue: 0.8))
        first.nestedNodeIDs = [[0, 0]: url, [0, 1]: wave, [0, 2]: next]
        first.number = 1
        var second = Corpus.page([Corpus.path(Corpus.rect(0, 0, 20, 20), [Corpus.fill(.solid(.black))])])
        second.number = 2
        return Corpus.scene([first, second], nodes: [
            layer: ExportNodeInfo(name: "Layer 1", isLayer: true),
            url: ExportNodeInfo(name: "Order", alt: "Red button", url: "shop.example.com", linkTarget: .newTab),
            wave: ExportNodeInfo(url: "https://wave.example", linkAlt: "Wave"),
            next: ExportNodeInfo(pageLink: 2),
        ])
    }

    @Test(arguments: HTMLLayout.allCases.flatMap { layout in HTMLPageMode.allCases.flatMap { mode in HTMLVectorFormat.allCases.map { (layout, mode, $0) } } })
    func everyCombinationPublishesACompleteDeterministicBundle(layout: HTMLLayout, mode: HTMLPageMode, vector: HTMLVectorFormat) throws {
        let settings = HTMLPublishSettings(layout: layout, pageMode: mode, vectorFormat: vector, scale: 1, title: "Brochure")
        let bundle = try HTMLPublisher(settings: settings).publish(Self.scene())
        let paths = bundle.files.map(\.path)
        #expect(paths.contains("index.html") && paths.contains("style.css"))
        #expect(paths == paths.sorted())
        #expect(paths.contains("page-2.html") == (mode == .separateFiles))
        let index = try #require(bundle.text("index.html"))
        #expect(index.hasPrefix("<!DOCTYPE html>") && index.contains("<title>Brochure</title>") && index.contains("<meta charset=\"utf-8\">"))
        #expect(index.contains("<section id=\"page-1\""))
        #expect(index.contains("<section id=\"page-2\"") == (mode == .stacked))
        let pageLink = mode == .stacked ? "#page-2" : "page-2.html"
        let folder = layout == .wholePages ? "pages/page-1" : "objects/page-1-"
        #expect(paths.contains { $0.hasPrefix(folder) && $0.hasSuffix(vector == .svg ? ".svg" : ".png") })
        switch vector {
        case .svg:
            let svgs = bundle.files.filter { $0.path.hasSuffix(".svg") }
            for file in svgs {
                let root = try #require(XMLTreeParser.parse(String(decoding: file.data, as: UTF8.self)))
                #expect(SVGValidator.problems(root).isEmpty, "\(file.path)")
            }
            let all = svgs.map { String(decoding: $0.data, as: UTF8.self) }.joined()
            #expect(all.contains("xlink:href=\"https://shop.example.com\"") && all.contains("xlink:href=\"\(pageLink)\""))
            #expect(index.contains("<object data="))
        case .png:
            #expect(index.contains("<map name=\"map-1"))
            #expect(index.contains("shape=\"poly\"") && index.contains("href=\"https://shop.example.com\"") && index.contains("target=\"_blank\""))
            #expect(index.contains("href=\"\(pageLink)\"") && index.contains("alt=\"Red button\"") && index.contains("alt=\"Wave\""))
            #expect(bundle.warnings.all.contains { $0.kind == .strokeOnlyLink })
        }
        if mode == .separateFiles {
            #expect(index.contains("rel=\"next\" href=\"page-2.html\""))
            #expect(bundle.text("page-2.html")?.contains("rel=\"prev\" href=\"index.html\"") == true)
        }
        // Publishing again gives byte-identical files.
        let again = try HTMLPublisher(settings: settings).publish(Self.scene())
        #expect(again.files.map(\.path) == paths && zip(again.files, bundle.files).allSatisfy { $0.data == $1.data })
    }

    @Test func republishingOverTheFolderRewritesOnlyWhatChanged() throws {
        let folder = Corpus.directory().appendingPathComponent("publish-\(UUID().uuidString.prefix(8))")
        let bundle = try HTMLPublisher().publish(Self.scene())
        let written = try bundle.write(to: folder)
        #expect(written.count == bundle.files.count)
        #expect(try bundle.write(to: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pages/page-2.svg").path))
        let retitled = try HTMLPublisher(settings: HTMLPublishSettings(title: "New")).publish(Self.scene())
        #expect(try retitled.write(to: folder) == ["index.html"])
        #expect(bundle.file("missing") == nil)
        #expect(throws: ExportError.self) { try bundle.write(to: URL(fileURLWithPath: "/nonexistent-root-\(UUID().uuidString)/x")) }
    }

    @Test func backgroundsTitlesWarningsAndRefusals() throws {
        let scene = Self.scene()
        let document = try HTMLPublisher().publish(scene)
        #expect(document.text("style.css")?.contains("background:#ffffcc") == true)
        #expect(document.text("index.html")?.contains("<title>Corpus</title>") == true)
        #expect(try HTMLPublisher(settings: HTMLPublishSettings(background: .white)).publish(scene).text("style.css")?.contains("background:#ffffff;") == true)
        #expect(try HTMLPublisher(settings: HTMLPublishSettings(background: .transparent)).publish(scene).text("style.css")?.contains("background:transparent") == true)
        #expect(throws: ExportError.self) { try HTMLPublisher(settings: HTMLPublishSettings(scale: 0)).publish(scene) }
        #expect(throws: ExportError.nothingToExport) { try HTMLPublisher().publish(Corpus.scene([])) }
        // A page too large for PNG at its scale is clamped and listed.
        var huge = Corpus.scene([Corpus.page([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))])], width: 9000, height: 20)])
        huge.pages[0].number = 1
        let clamped = try HTMLPublisher(settings: HTMLPublishSettings(vectorFormat: .png, scale: 2)).publish(huge)
        #expect(clamped.warnings.all.contains { $0.kind == .clampedPage && $0.page == 1 })
        let png = try #require(clamped.file("pages/page-1.png"))
        let image = try #require(CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width <= 16_384)
        // Fonts map onto the SVG writer's text modes.
        #expect(HTMLPublisher(settings: HTMLPublishSettings(fontMode: .outlines)).textMode == .outlines)
        #expect(HTMLPublisher(settings: HTMLPublishSettings(fontMode: .system)).textMode == .asText)
        #expect(HTMLPublisher().textMode == .asTextEmbedFonts)
        #expect(HTMLPublisher.css(Color(red: 1, green: 0, blue: 0)) == "#ff0000")
    }

    @Test func anAnimatedDocumentPublishesAnimatedPagesUnlessStill() throws {
        let scene = AnimationExportTests.scene()
        let animated = try HTMLPublisher().publish(scene)
        #expect(animated.text("pages/page-1.svg")?.contains("@keyframes wt-f0") == true)
        let still = try HTMLPublisher(settings: HTMLPublishSettings(animationStill: true)).publish(scene)
        #expect(still.text("pages/page-1.svg")?.contains("@keyframes") == false)
        #expect(still.text("index.html")?.contains("<img src=\"pages/page-1.svg\"") == true)
    }

    @Test func imageMapsCoverGroupsImagesAndTextRanges() {
        let (group, image, text) = (Corpus.node(20), Corpus.node(21), Corpus.node(22))
        let items: [DisplayItem] = [
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))]),
                                        Corpus.path(Corpus.rect(20, 0, 10, 10), [Corpus.fill(.solid(.black))])])),
            .image(ImageItem(assetID: "missing", rect: Rect(x: 50, y: 50, width: 20, height: 10))),
        ]
        var scene = Corpus.scene([Corpus.page(items, nodes: [group, image])], nodes: [
            group: ExportNodeInfo(url: "https://group.example"), image: ExportNodeInfo(alt: "Photo", url: "https://image.example"),
        ])
        scene.textLinks = [text: [ExportTextLink(url: "https://words.example", rects: [Rect(x: 5, y: 100, width: 40, height: 10), Rect(x: 900, y: 900, width: 5, height: 5)]),
                                  ExportTextLink(url: "bad url", rects: [Rect(x: 0, y: 0, width: 1, height: 1)])]]
        let flat = SVGExporter.flattener(options: SVGOptions(), scene: scene).flatten(scene.pages[0], scene: scene).page
        let areas = HTMLImageMap.areas(flat, scene: scene, pageHrefs: [:])
        #expect(areas.filter { $0.href == "https://group.example" }.count == 2)
        let photo = areas.first { $0.href == "https://image.example" }
        #expect(photo?.alt == "Photo")
        #expect(areas.filter { $0.href == "https://words.example" }.count == 1)
        #expect(!areas.contains { $0.href.contains("bad") })
        // The warnings sink orders ties by kind, then message.
        let node = Corpus.node(1)
        let sorted = ExportWarnings([ExportWarning(.unusedLink, node: node, "b"), ExportWarning(.invalidLink, node: node, "z"), ExportWarning(.invalidLink, node: node, "a")]).sorted
        #expect(sorted.map(\.message) == ["a", "z", "b"])
    }

    @Test func imageMapPolygonsFollowTheOutline() {
        let polygons = HTMLImageMap.polygons(Corpus.ellipse(0, 0, 100, 100), transform: .identity)
        #expect(polygons.count == 1 && polygons[0].count > 16)
        #expect(polygons[0].allSatisfy { abs(hypot($0.x - 50, $0.y - 50) - 50) < 0.5 })
        var quad = DisplayPath()
        quad.move(to: Point(x: 0, y: 0))
        quad.addQuadCurve(control: Point(x: 50, y: 100), to: Point(x: 100, y: 0))
        quad.close()
        #expect(HTMLImageMap.polygons(quad, transform: .translation(x: 10, y: 0))[0].first == Point(x: 10, y: 0))
        let area = HTMLImageMapArea(shape: .rect(Rect(x: 1, y: 2, width: 3, height: 4)), href: "a&b", alt: "\"q\"", newTab: false)
        #expect(area.html == "<area shape=\"rect\" coords=\"1,2,4,6\" href=\"a&amp;b\" alt=\"&quot;q&quot;\">")
        #expect(HTMLPublishSettings.defaults == HTMLPublishSettings())
    }
}
