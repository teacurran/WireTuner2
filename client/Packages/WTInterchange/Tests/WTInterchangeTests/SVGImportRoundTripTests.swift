// IMG-012 round trips (testing.adoc, "Import and export"): scenes exported by the SVG exporter
// (IO-019) and imported again reproduce their geometry within 0.01 pt, their names, colours,
// gradient stops, clips, links and text, and render within tolerance of the original.  Plus the
// large-file smoke test.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite("SVG import round trips")
struct SVGImportRoundTripTests {
    /// Points-sized output (the default size), so one user unit is one point both ways.
    static let options = SVGOptions(precision: 4, responsive: false, sizeUnit: "pt")

    static func roundTrip(_ scene: ExportScene, options: SVGOptions = options, importOptions: SVGImportOptions = SVGImportOptions()) throws -> ImportedScene {
        let document = SVGExporter().documents(scene: scene, options: options)[0]
        return try SVGImporter().convert(Data(document.text.utf8), name: "round.svg", format: .svg, options: importOptions.values, context: ImportContext())
    }

    /// The default export states its size in points, so it re-imports 1:1; so do the other
    /// physical units.  A responsive file (view box only) reads at 96 px/in, 75%.
    @Test func defaultExportReimportsAtTrueSize() throws {
        let items: [DisplayItem] = [Corpus.path(Corpus.rect(10, 20, 60, 40), [Corpus.fill(.solid(Corpus.red))])]
        let scene = Corpus.scene([Corpus.page(items)])
        let text = SVGExporter().documents(scene: scene, options: .defaults)[0].text
        #expect(text.contains("width=\"200pt\"") && text.contains("height=\"150pt\"") && text.contains("viewBox=\"0 0 200 150\""))
        let imported = try SVGImportRoundTripTests.roundTrip(scene, options: .defaults)
        #expect(imported.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(SVGImportConverter.bounds(of: imported.scenePaths[0].contours) == Rect(x: 10, y: 20, width: 60, height: 40))
        // Millimetres and inches are rounded to the precision (2.778in is 200.016 pt).
        for unit in ["mm", "in"] {
            let other = try SVGImportRoundTripTests.roundTrip(scene, options: SVGOptions(responsive: false, sizeUnit: unit))
            #expect(abs(other.bounds.width - 200) < 0.05 && abs(other.bounds.height - 150) < 0.05, "\(unit)")
            let bounds = SVGImportConverter.bounds(of: other.scenePaths[0].contours)
            #expect(abs(bounds.minX - 10) < 0.05 && abs(bounds.width - 60) < 0.05, "\(unit)")
        }
        let responsive = try SVGImportRoundTripTests.roundTrip(scene, options: SVGOptions(responsive: true))
        #expect(responsive.bounds == Rect(x: 0, y: 0, width: 150, height: 112.5))
    }

    @Test func geometryNamesAndPaints() throws {
        let wave = Corpus.wave(20, 60, 100, 40)
        let items: [DisplayItem] = [
            Corpus.path(Corpus.rect(10, 10, 60, 40), [Corpus.fill(.solid(Corpus.red)), Corpus.stroke(.solid(.black), width: 3, join: .round, dash: [4, 2])]),
            Corpus.path(Corpus.ellipse(100, 10, 50, 30), [Corpus.fill(.solid(Corpus.blue.withAlpha(multipliedBy: 0.5)), rule: .evenOdd)]),
            Corpus.path(wave, [Corpus.stroke(.solid(Corpus.green), width: 2, cap: .round)]),
            Corpus.path(Corpus.rect(0, 0, 20, 10), [Corpus.fill(.solid(Corpus.yellow))], transform: AffineTransform.scale(x: 2, y: 1).concatenating(.translation(x: 150, y: 100))),
        ]
        let nodes = [Corpus.node(1), Corpus.node(2), Corpus.node(3), Corpus.node(4)]
        let info: [NodeID: ExportNodeInfo] = [Corpus.node(1): ExportNodeInfo(name: "Box", url: "https://example.com/box"), Corpus.node(2): ExportNodeInfo(name: "Ring")]
        let scene = Corpus.scene([Corpus.page(items, nodes: nodes)], nodes: info)
        let imported = try SVGImportRoundTripTests.roundTrip(scene)
        #expect(imported.bounds == Rect(x: 0, y: 0, width: 200, height: 150))
        let paths = imported.scenePaths
        // The exporter writes a filled-and-stroked path as a fill and a stroke.
        #expect(paths.count == 5)
        // A filled and stroked path is written as a group named after it holding both.
        #expect(paths[0].groupNames.last == "Box" && paths[0].url == "https://example.com/box" && paths[1].url == "https://example.com/box")
        #expect(SVGImportFixture.anchors(paths[0]) == [Point(x: 10, y: 10), Point(x: 70, y: 10), Point(x: 70, y: 50), Point(x: 10, y: 50)])
        #expect(paths[0].fill == .solid(Corpus.red.converted(to: .sRGB)) || Self.near(paths[0].fill.representativeColor, Corpus.red))
        #expect(paths[1].stroke?.style.width == 3 && paths[1].stroke?.style.dash == [4, 2] && paths[1].stroke?.style.join == .round)
        #expect(paths[2].name == "Ring" && paths[2].fillRule == .evenOdd)
        #expect(Self.near(paths[2].fill.representativeColor, Corpus.blue.withAlpha(multipliedBy: 0.5)))
        let ellipse = DisplayPath(ellipseIn: Rect(x: 100, y: 10, width: 50, height: 30))
        #expect(Self.sameGeometry(paths[2].contours, ellipse))
        #expect(Self.sameGeometry(paths[3].contours, wave))
        #expect(paths[3].stroke?.style.cap == .round && paths[3].fill == .none)
        #expect(SVGImportConverter.bounds(of: paths[4].contours) == Rect(x: 150, y: 100, width: 40, height: 10))
        try Self.expectRendersAlike(scene.pages[0], imported)
    }

    @Test func gradientsClipsTextAndGroups() throws {
        let group = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(120, 90, 80, 60), [Corpus.fill(.solid(Corpus.red))]),
        ], clip: Corpus.ellipse(125, 95, 60, 45)))
        let translucent = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(10, 110, 40, 30), [Corpus.fill(.solid(Corpus.green))]),
        ], opacity: 0.5))
        let items: [DisplayItem] = [
            Corpus.path(Corpus.rect(10, 10, 80, 40), [Corpus.fill(Corpus.gradient(.linear, axis: Gradient.Axis(start: Point(x: 10, y: 10), end: Point(x: 90, y: 10))))]),
            Corpus.path(Corpus.ellipse(10, 60, 80, 40), [Corpus.fill(Corpus.gradient(.radial))]),
            group,
            translucent,
            Corpus.text("Round trip", size: 14, origin: Point(x: 100, y: 40)),
        ]
        let scene = Corpus.scene([Corpus.page(items)])
        let imported = try SVGImportRoundTripTests.roundTrip(scene)
        let paths = imported.scenePaths
        guard case .gradient(let linear) = paths[0].fill else {
            Issue.record("expected a linear gradient")
            return
        }
        #expect(linear.kind == .linear && linear.stops.count >= 3)
        #expect(Self.near(linear.stops.first?.color, Corpus.red) && Self.near(linear.stops.last?.color, Corpus.blue))
        #expect(linear.axis!.start.distance(to: Point(x: 10, y: 10)) < 0.01 && linear.axis!.end.distance(to: Point(x: 90, y: 10)) < 0.01)
        guard case .gradient(let radial) = paths[1].fill else {
            Issue.record("expected a radial gradient")
            return
        }
        #expect(radial.kind == .radial)
        let clipped = imported.nodes.first { node in
            if case .group(let group) = node { return group.clip != nil }
            return false
        }
        #expect(clipped != nil)
        #expect(paths.contains { $0.opacity == 0.5 })
        #expect(imported.texts == ["Round trip"])
        try Self.expectRendersAlike(scene.pages[0], imported)
        // Text converted to outlines on the way in renders the same way.
        let outlined = try SVGImportRoundTripTests.roundTrip(scene, importOptions: SVGImportOptions(text: .outlines))
        #expect(outlined.texts.isEmpty)
        try Self.expectRendersAlike(scene.pages[0], outlined)
    }

    @Test func images() throws {
        let image = Corpus.image(width: 16, height: 12, alpha: true)
        let item = DisplayItem.image(ImageItem(assetID: "pic", rect: Rect(x: 0, y: 0, width: 32, height: 24), transform: .translation(x: 40, y: 30), hasAlpha: true))
        let scene = Corpus.scene([Corpus.page([item], nodes: [Corpus.node(9)])], nodes: [Corpus.node(9): ExportNodeInfo(name: "Photo")], assets: ["pic": ExportAsset(image: image)])
        let imported = try SVGImportRoundTripTests.roundTrip(scene)
        let images = imported.images
        #expect(images.count == 1)
        #expect(images[0].name == "Photo")
        #expect(images[0].pixels.width == 16 && images[0].pixels.height == 12 && images[0].pixels.hasAlpha)
        let placed = images[0].naturalRect.applying(images[0].transform)
        #expect(abs(placed.minX - 40) < 0.01 && abs(placed.width - 32) < 0.01 && abs(placed.height - 24) < 0.01)
        #expect(imported.exportScene().assets[images[0].pixels.blob.hex] != nil)
    }

    @Test func largeFileImports() throws {
        var body = ""
        body.reserveCapacity(10_500_000)
        var index = 0
        while body.utf8.count < 10_000_000 {
            let x = index % 500, y = (index / 500) % 500
            body += "<path fill=\"#\(String(format: "%06x", index & 0xFFFFFF))\" stroke=\"black\" stroke-width=\"0.5\" d=\"M\(x) \(y) C\(x + 1) \(y + 2) \(x + 3) \(y + 1) \(x + 4) \(y + 4) L\(x + 2) \(y + 5) Z\"/>\n"
            index += 1
        }
        let data = Data(SVGImportFixture.svg(body, root: "width=\"500\" height=\"500\"").utf8)
        let start = Date()
        let scene = try SVGImporter().convert(data, name: "large.svg", format: .svg, options: SVGImportOptions().values, context: ImportContext())
        let seconds = Date().timeIntervalSince(start)
        print("SVG import of \(data.count / 1_000_000) MB (\(index) paths): \(String(format: "%.2f", seconds)) s (the budget is 3 s on M1 in release)")
        #expect(scene.scenePaths.count == index)
        // Like the other budgets, held in the perf run only: debug timings under load say
        // nothing about the importer (testing.adoc, "Where budgets run").
        PerfBudget.expect(.seconds(seconds), within: .seconds(3))
    }

    // MARK: Helpers

    static func near(_ a: Color?, _ b: Color, tolerance: Double = 0.01) -> Bool {
        guard let a else {
            return false
        }
        let x = a.srgb, y = b.srgb
        return abs(x.x - y.x) <= tolerance && abs(x.y - y.y) <= tolerance && abs(x.z - y.z) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    /// Whether `contours` trace `path` within 0.01 pt at its anchors and control points.
    static func sameGeometry(_ contours: [ImportedContour], _ path: DisplayPath) -> Bool {
        var expected: [Point] = []
        for element in path.elements {
            switch element {
            case .move(let p), .line(let p): expected.append(p)
            case .quadCurve(let c, let e): expected += [c, e]
            case .cubicCurve(let c1, let c2, let e): expected += [c1, c2, e]
            case .close: break
            }
        }
        let actual = contours.flatMap(\.allPoints)
        guard actual.count >= expected.count else {
            return false
        }
        return zip(actual, expected).allSatisfy { $0.distance(to: $1) <= 0.01 }
    }

    /// The imported scene renders like the original page: under 1% of pixels differ by more
    /// than a small anti-aliasing tolerance.
    static func expectRendersAlike(_ page: ExportPage, _ imported: ImportedScene, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let original = Corpus.reference(page, scale: 2)
        let copy = Corpus.reference(imported.exportScene().pages[0], scale: 2)
        let difference = Corpus.difference(original, copy, tolerance: 40)
        if difference >= 0.01 {
            Corpus.dump(original, "svg-import-original")
            Corpus.dump(copy, "svg-import-copy")
        }
        #expect(difference < 0.01, "differs in \(difference * 100)% of pixels", sourceLocation: sourceLocation)
    }
}
