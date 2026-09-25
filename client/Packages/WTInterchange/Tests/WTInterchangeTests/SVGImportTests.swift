// IMG-012: the SVG importer -- value grammars, the CSS cascade, shapes, paints, gradients, `use`,
// clipping, images, text, *Flatten groups*, `.svgz`, animation detection and errors.  Round trips
// through the SVG exporter are in SVGImportRoundTripTests.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender
import struct WTRender.StrokeStyle

/// Builds and imports SVG text for the tests.
enum SVGImportFixture {
    /// A document whose user unit is exactly one point (100pt over a 100-unit view box).
    static func svg(_ body: String, root: String = "width=\"100pt\" height=\"100pt\" viewBox=\"0 0 100 100\"") -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" xmlns:inkscape=\"http://www.inkscape.org/namespaces/inkscape\" \(root)>\(body)</svg>"
    }

    static func scene(_ body: String, root: String? = nil, options: SVGImportOptions = SVGImportOptions(), importer: SVGImporter = SVGImporter(), context: ImportContext = ImportContext()) throws -> ImportedScene {
        let text = root.map { svg(body, root: $0) } ?? svg(body)
        return try importer.convert(Data(text.utf8), name: "test.svg", format: .svg, options: options.values, context: context)
    }

    static func paths(_ body: String, options: SVGImportOptions = SVGImportOptions()) throws -> [ImportedScenePath] {
        try scene(body, options: options).scenePaths
    }

    /// Every anchor of every contour, rounded to 1e-9 (the 96 px/in mapping is not exact in
    /// binary).
    static func anchors(_ path: ImportedScenePath) -> [Point] {
        path.contours.flatMap { [$0.start] + $0.segments.map(\.end) }.map(rounded)
    }

    static func rounded(_ point: Point) -> Point {
        Point(x: (point.x * 1e9).rounded() / 1e9, y: (point.y * 1e9).rounded() / 1e9)
    }

    static func rounded(_ rect: Rect) -> Rect {
        Rect(minX: (rect.minX * 1e9).rounded() / 1e9, minY: (rect.minY * 1e9).rounded() / 1e9, maxX: (rect.maxX * 1e9).rounded() / 1e9, maxY: (rect.maxY * 1e9).rounded() / 1e9)
    }

    static func close(_ a: Point, _ b: Point, _ tolerance: Double = 1e-6) -> Bool {
        a.distance(to: b) <= tolerance
    }

    static func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
        abs(a - b) <= tolerance
    }

    static func png(width: Int = 4, height: Int = 2) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageEncoding.encode(context.makeImage()!, type: .png)!
    }

    /// A gzip member of `data` with every optional header field.
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0x04 | 0x08 | 0x10 | 0x02, 0, 0, 0, 0, 0, 3])
        out.append(contentsOf: [2, 0, 0xAA, 0xBB])        // FEXTRA
        out.append(contentsOf: Array("a.svg".utf8) + [0])  // FNAME
        out.append(contentsOf: Array("hi".utf8) + [0])     // FCOMMENT
        out.append(contentsOf: [0, 0])                     // FHCRC
        out.append(try! (data as NSData).compressed(using: .zlib) as Data)
        out.appendLittleEndian(CRC32.checksum(data))
        out.appendLittleEndian(UInt32(data.count))
        return out
    }
}

@Suite("SVG import values")
struct SVGImportValueTests {
    @Test func compactNumbers() {
        #expect(SVGImportValues.numbers("1.5.5-3e-1,2 +4") == [1.5, 0.5, -0.3, 2, 4])
        #expect(SVGImportValues.numbers("1e x") == [1])
        #expect(SVGImportValues.numbers("abc").isEmpty)
        #expect(SVGImportValues.numbers(".5E+2") == [50])
    }

    @Test func lengths() {
        #expect(SVGImportValues.length("10") == 10)
        #expect(SVGImportValues.length("1in") == 96)
        #expect(SVGImportValues.length("72pt") == 96)
        #expect(SVGImportValues.length("1pc") == 16)
        #expect(SVGImportFixture.close(SVGImportValues.length("25.4mm")!, 96))
        #expect(SVGImportFixture.close(SVGImportValues.length("2.54cm")!, 96))
        #expect(SVGImportValues.length("50%", percentOf: 200) == 100)
        #expect(SVGImportValues.length("2em", fontSize: 10) == 20)
        #expect(SVGImportValues.length("2ex", fontSize: 10) == 10)
        #expect(SVGImportValues.length("3furlongs") == nil)
        #expect(SVGImportValues.length("px") == nil)
        #expect(SVGImportValues.length("  ") == nil)
        #expect(SVGImportValues.length(nil) == nil)
        #expect(SVGImportValues.lengths("1 2,3px") == [1, 2, 3])
        #expect(SVGImportValues.lengths(nil).isEmpty)
    }

    @Test func colors() {
        #expect(SVGImportValues.color("red") == Color(red: 1, green: 0, blue: 0))
        #expect(SVGImportValues.color("RebeccaPurple") == Color(red: 0x66 / 255.0, green: 0x33 / 255.0, blue: 0x99 / 255.0))
        #expect(SVGImportValues.color("#f00") == Color(red: 1, green: 0, blue: 0))
        #expect(SVGImportValues.color("#f008")?.alpha == Double(0x88) / 255)
        #expect(SVGImportValues.color("#00ff00") == Color(red: 0, green: 1, blue: 0))
        #expect(SVGImportValues.color("#0000ff80")?.alpha == 128.0 / 255)
        #expect(SVGImportValues.color("#12345") == nil)
        #expect(SVGImportValues.color("#zzz") == nil)
        #expect(SVGImportValues.color("rgb(255, 0, 0)") == Color(red: 1, green: 0, blue: 0))
        #expect(SVGImportValues.color("rgb(100%, 50%, 0%)") == Color(red: 1, green: 0.5, blue: 0))
        #expect(SVGImportValues.color("rgba(0, 0, 255, 0.5)")?.alpha == 0.5)
        #expect(SVGImportValues.color("rgb(0 0 255 / 50%)")?.alpha == 0.5)
        #expect(SVGImportValues.color("rgb(1, 2)") == nil)
        let hsl = SVGImportValues.color("hsl(120, 100%, 50%)")!
        #expect(SVGImportFixture.close(hsl.green, 1) && SVGImportFixture.close(hsl.red, 0))
        #expect(SVGImportValues.color("hsla(240deg, 100%, 25%, 0.25)")?.alpha == 0.25)
        #expect(SVGImportValues.color("hsl(0, 100%, 75%)")!.red == 1)
        #expect(SVGImportValues.color("hsl(x, 1, 2)") == nil)
        #expect(SVGImportValues.color("color(display-p3 1 0 0)")?.space == .displayP3)
        #expect(SVGImportValues.color("color(srgb 0 1 0 / 0.5)") == Color(red: 0, green: 1, blue: 0, alpha: 0.5))
        #expect(SVGImportValues.color("color(rec2020 1 0 0)") == nil)
        #expect(SVGImportValues.color("color(display-p3 1)") == nil)
        #expect(SVGImportValues.color("lab(50 0 0)") == nil)
        #expect(SVGImportValues.color("currentColor", current: .white) == .white)
        #expect(SVGImportValues.color("transparent") == .clear)
        #expect(SVGImportValues.color("nonsense") == nil)
    }

    @Test func transforms() {
        let t = SVGImportValues.transform("translate(10 20) scale(2)")
        #expect(t.apply(Point(x: 1, y: 1)) == Point(x: 12, y: 22))
        #expect(SVGImportValues.transform("translate(5)").apply(Point.zero) == Point(x: 5, y: 0))
        #expect(SVGImportValues.transform("scale(2 3)").apply(Point(x: 1, y: 1)) == Point(x: 2, y: 3))
        #expect(SVGImportFixture.close(SVGImportValues.transform("rotate(90)").apply(Point(x: 1, y: 0)), Point(x: 0, y: 1)))
        #expect(SVGImportFixture.close(SVGImportValues.transform("rotate(180 5 5)").apply(Point.zero), Point(x: 10, y: 10)))
        #expect(SVGImportFixture.close(SVGImportValues.transform("skewX(45)").apply(Point(x: 0, y: 1)), Point(x: 1, y: 1)))
        #expect(SVGImportFixture.close(SVGImportValues.transform("skewY(45)").apply(Point(x: 1, y: 0)), Point(x: 1, y: 1)))
        #expect(SVGImportValues.transform("matrix(1 0 0 1 3 4),translate(1,1)").apply(Point.zero) == Point(x: 4, y: 5))
        // An unreadable function ends the list.
        #expect(SVGImportValues.transform("translate(1) bogus(2) translate(5)").apply(Point.zero) == Point(x: 1, y: 0))
        #expect(SVGImportValues.transform("rotate(1 2)").isIdentity)
        #expect(SVGImportValues.transform(nil).isIdentity)
    }

    @Test func pathGrammar() {
        let contours = SVGImportValues.pathData("M10 10 h10 v10 H10 z m5 5 l1 1 2 2 L0 0 V5")
        #expect(contours.count == 2)
        #expect(contours[0].closed)
        #expect(contours[0].segments.map(\.end) == [Point(x: 20, y: 10), Point(x: 20, y: 20), Point(x: 10, y: 20)])
        // After z the relative move starts from the closed contour's start.
        #expect(contours[1].start == Point(x: 15, y: 15))
        #expect(contours[1].segments.map(\.end) == [Point(x: 16, y: 16), Point(x: 18, y: 18), Point(x: 0, y: 0), Point(x: 0, y: 5)])
        // Implicit line-tos after an absolute move, and a line after z starting a new contour.
        let implicit = SVGImportValues.pathData("M0 0 10 0 10 10z l5 0")
        #expect(implicit.count == 2)
        #expect(implicit[0].segments.count == 2)
        #expect(implicit[1].start == Point.zero && implicit[1].segments == [.line(to: Point(x: 5, y: 0))])
        #expect(SVGImportValues.pathData("v 5 h 5").first?.segments.map(\.end) == [Point(x: 0, y: 5), Point(x: 5, y: 5)] || SVGImportValues.pathData("v 5 h 5").isEmpty)
    }

    @Test func curvesAndReflections() {
        let contours = SVGImportValues.pathData("M0 0 C10 0 20 10 20 20 S30 40 40 40 s10 10 20 0 Q50 50 60 60 T80 80 t10 0 c1 1 2 2 3 3 q1 1 2 2")
        guard case .cubic(let c1, _, _) = contours[0].segments[1] else {
            Issue.record("expected a cubic")
            return
        }
        #expect(c1 == Point(x: 20, y: 30))
        guard case .cubic(let t1, _, let tEnd) = contours[0].segments[4] else {
            Issue.record("expected a cubic")
            return
        }
        // T reflects Q's control (50,50) about (60,60) to (70,70); raised to a cubic.
        #expect(SVGImportFixture.close(t1, Point(x: 60 + (70 - 60) * 2.0 / 3, y: 60 + (70 - 60) * 2.0 / 3)))
        #expect(tEnd == Point(x: 80, y: 80))
        #expect(contours[0].end == Point(x: 95, y: 85))
        // S without a preceding curve uses the current point as its first control.
        let lone = SVGImportValues.pathData("M0 0 S10 10 20 0 T30 0")
        guard case .cubic(let first, _, _) = lone[0].segments[0] else {
            Issue.record("expected a cubic")
            return
        }
        #expect(first == Point.zero)
    }

    @Test func arcs() {
        let contours = SVGImportValues.pathData("M0 0 A10 10 0 0 1 20 0 a5 5 0 1 1 10 0 A0 5 0 0 0 40 0 A5 5 0 0 0 40 0 A1 1 0 0 0 60 0")
        let contour = contours[0]
        #expect(contour.end == Point(x: 60, y: 0))
        // Every point of the first half circle lies 10 from (10, 0).
        let anchors = [contour.start] + contour.segments.map(\.end)
        #expect(anchors.contains(Point(x: 20, y: 0)))
        let top = contour.segments.prefix(2).map(\.end)
        #expect(top.allSatisfy { abs($0.distance(to: Point(x: 10, y: 0)) - 10) < 1e-9 })
        // The too-small radius is scaled up: the last arc still ends on its point.
        #expect(contour.segments.contains(.line(to: Point(x: 40, y: 0))))
        let rotated = SVGImportValues.pathData("M0 0 A10 5 30 0 0 10 10")
        #expect(rotated[0].end == Point(x: 10, y: 10))
    }

    @Test func pathErrorsKeepWhatWasRead() {
        #expect(SVGImportValues.pathData("M0 0 L10 10 X5 5")[0].segments.count == 1)
        #expect(SVGImportValues.pathData("10 10").isEmpty)
        #expect(SVGImportValues.pathData("M0 0 L10").first?.segments.isEmpty == true)
        for broken in ["M", "M0 0 H", "M0 0 V", "M0 0 C1 1", "M0 0 S1 1", "M0 0 Q1", "M0 0 T", "M0 0 A1 1 0 2 0 1 1"] {
            #expect(SVGImportValues.pathData(broken).allSatisfy { $0.segments.isEmpty }, "\(broken)")
        }
    }
}

@Suite("SVG import CSS")
struct SVGImportCSSTests {
    func element(_ name: String, _ attributes: [String: String] = [:], parent: SVGImportElement? = nil) -> SVGImportElement {
        let element = SVGImportElement(name: name, attributes: attributes)
        element.parent = parent
        parent?.content.append(.element(element))
        return element
    }

    @Test func selectorsAndSpecificity() {
        let sheet = SVGImportStyleSheet("""
        /* comment */ rect { fill: red } .a { fill: green } #b { fill: blue }
        rect.a { stroke: black } * { stroke-width: 3 } g rect { opacity: 0.5 } g > circle { opacity: 0.25 }
        @media print { rect { fill: yellow } } a:hover { fill: pink } p, .c { fill: gray !important }
        broken { novalue; : x ; fill: }
        """)
        let group = element("g")
        let rect = element("rect", ["class": "a c", "id": "b"], parent: group)
        let matched = sheet.matching(rect)
        let fill = matched.normal.last { $0.property == "fill" }
        #expect(fill?.value == "blue")
        #expect(matched.normal.contains(SVGImportDeclaration(property: "stroke", value: "black", important: false)))
        #expect(matched.normal.contains { $0.property == "opacity" && $0.value == "0.5" })
        #expect(matched.important == [SVGImportDeclaration(property: "fill", value: "gray", important: true)])
        let nested = element("circle", parent: element("a", parent: group))
        #expect(!sheet.matching(nested).normal.contains { $0.property == "opacity" })
        let child = element("circle", parent: group)
        #expect(sheet.matching(child).normal.contains { $0.property == "opacity" && $0.value == "0.25" })
        #expect(SVGImportSelector("") == nil)
        #expect(SVGImportSelector("> rect")?.compounds.count == 1)
        #expect(SVGImportStyleSheet("rect { fill: red").rules.isEmpty)
        #expect(SVGImportStyleSheet("@keyframes x { from { a: b } ").rules.isEmpty)
        #expect(SVGImportStyleSheet.stripComments("a /* b") == "a ")
        let orphan = element("circle")
        #expect(SVGImportSelector("g > circle")?.matches(orphan) == false)
    }

    @Test func cascadeOrder() throws {
        let scene = try SVGImportFixture.scene("""
        <style>rect { fill: red } #r2 { fill: green !important }</style>
        <rect id="r1" width="10" height="10" fill="blue"/>
        <rect id="r2" width="10" height="10" style="fill: yellow"/>
        <rect id="r3" width="10" height="10" fill="blue" style="fill: #00f; stroke: inherit"/>
        """)
        let fills = scene.scenePaths.map(\.fill)
        #expect(fills[0] == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(fills[1] == .solid(Color(red: 0, green: 128 / 255.0, blue: 0)))
        #expect(fills[2] == .solid(Color(red: 0, green: 0, blue: 1)))
    }
}

@Suite("SVG import conversion")
struct SVGImportConversionTests {
    @Test func rootViewportAt96PixelsPerInch() throws {
        let importer = SVGImporter()
        let plain = try importer.probe(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"48\"/>".utf8), name: "a.svg", format: .svg)
        #expect(plain.naturalSize == Rect(x: 0, y: 0, width: 72, height: 36))
        #expect(!plain.placed)
        let boxOnly = try importer.probe(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"/>".utf8), name: "a.svg", format: .svg)
        #expect(boxOnly.naturalSize == Rect(x: 0, y: 0, width: 150, height: 75))
        let neither = try importer.probe(Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 0 1\"/>".utf8), name: "a.svg", format: .svg)
        #expect(neither.naturalSize == Rect(x: 0, y: 0, width: 225, height: 112.5))
        #expect(importer.formats == [.svg])
        #expect(importer.optionsSchema(for: .svg) == SVGImportOptions.schema)
        // xMidYMid meet centres a 1:1 box in a 2:1 viewport.
        let scene = try SVGImportFixture.scene("<rect width=\"10\" height=\"10\"/>", root: "width=\"200\" height=\"100\" viewBox=\"0 0 10 10\"")
        let anchors = SVGImportFixture.anchors(scene.scenePaths[0])
        #expect(anchors[0] == Point(x: 37.5, y: 0))
        #expect(anchors[2] == Point(x: 112.5, y: 75))
    }

    @Test func aspectRatioModes() {
        let box = Rect(x: 0, y: 0, width: 10, height: 10)
        let viewport = Rect(x: 0, y: 0, width: 20, height: 10)
        #expect(SVGImportViewport.map(box, into: viewport, preserve: "none").apply(Point(x: 10, y: 10)) == Point(x: 20, y: 10))
        #expect(SVGImportViewport.map(box, into: viewport, preserve: "xMinYMin").apply(Point.zero) == Point.zero)
        #expect(SVGImportViewport.map(box, into: viewport, preserve: "xMaxYMax meet").apply(Point.zero) == Point(x: 10, y: 0))
        let slice = SVGImportViewport.map(box, into: viewport, preserve: "defer xMidYMid slice")
        #expect(slice.apply(Point(x: 10, y: 10)) == Point(x: 20, y: 15))
    }

    @Test func shapes() throws {
        let paths = try SVGImportFixture.paths("""
        <rect x="1" y="2" width="30" height="20" rx="5"/>
        <rect width="30" height="20" ry="50"/>
        <rect width="0" height="20"/>
        <rect width="10" height="10" rx="-1"/>
        <circle cx="50" cy="50" r="10"/>
        <circle r="0"/>
        <ellipse cx="50" cy="50" rx="20" ry="10"/>
        <line x1="0" y1="0" x2="10" y2="10" stroke="black"/>
        <polyline points="0,0 10,0 10,10 5" fill="none" stroke="black"/>
        <polygon points="0 0 10 0 10 10"/>
        <polygon points=""/>
        <path d=""/>
        <unknown/>
        """)
        #expect(paths.count == 8)
        #expect(paths[0].contours[0].segments.count == 8)
        #expect(SVGImportFixture.rounded(SVGImportConverter.bounds(of: paths[0].contours)) == Rect(x: 1, y: 2, width: 30, height: 20))
        // ry larger than half the height clamps, rx follows ry.
        #expect(SVGImportFixture.rounded(SVGImportConverter.bounds(of: paths[1].contours)) == Rect(x: 0, y: 0, width: 30, height: 20))
        #expect(paths[2].contours[0].segments.count == 3)
        let circle = SVGImportConverter.bounds(of: paths[3].contours)
        #expect(SVGImportFixture.close(circle.minX, 40) && SVGImportFixture.close(circle.maxY, 60))
        #expect(SVGImportFixture.close(SVGImportConverter.bounds(of: paths[4].contours).width, 40))
        #expect(!paths[6].contours[0].closed && paths[6].contours[0].segments.count == 2)
        #expect(paths[7].contours[0].closed)
        #expect(paths[5].fill == .solid(.black) && paths[5].stroke?.paint == .solid(Color(red: 0, green: 0, blue: 0)))
    }

    @Test func strokeAndFillProperties() throws {
        let paths = try SVGImportFixture.paths("""
        <g fill="red" stroke="blue" stroke-width="4" stroke-linecap="round" stroke-linejoin="bevel" stroke-miterlimit="8" fill-rule="evenodd">
          <rect width="10" height="10" stroke-dasharray="1 2 3" stroke-dashoffset="2" fill-opacity="0.5" stroke-opacity="50%"/>
          <rect width="10" height="10" fill="inherit" stroke-linecap="square" stroke-linejoin="round" stroke-dasharray="none"/>
          <rect width="10" height="10" stroke-dasharray="1 -1" stroke-width="0"/>
          <rect width="10" height="10" opacity="0.4" stroke-miterlimit="0.5" stroke-dasharray="0 0"/>
          <rect width="10" height="10" visibility="hidden"/>
          <rect width="10" height="10" display="none"/>
          <rect width="10" height="10" fill="none" stroke="currentColor" color="green"/>
        </g>
        """)
        #expect(paths.count == 5)
        let first = paths[0]
        #expect(first.fill == .solid(Color(red: 1, green: 0, blue: 0, alpha: 0.5)))
        #expect(first.fillRule == .evenOdd)
        #expect(first.stroke?.paint == .solid(Color(red: 0, green: 0, blue: 1, alpha: 0.5)))
        #expect(first.stroke?.style == StrokeStyle(width: 4, cap: .round, join: .bevel, miterLimit: 8, dash: [1, 2, 3, 1, 2, 3], dashPhase: 2))
        #expect(paths[1].stroke?.style.cap == .square && paths[1].stroke?.style.join == .round && paths[1].stroke?.style.dash == [])
        #expect(paths[1].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(paths[2].stroke == nil)
        #expect(paths[3].opacity == 0.4 && paths[3].stroke?.style.miterLimit == 8 && paths[3].stroke?.style.dash == [])
        #expect(paths[4].fill == .none && paths[4].stroke?.paint == .solid(Color(red: 0, green: 128 / 255.0, blue: 0)))
    }

    @Test func groupsNamesAndLinks() throws {
        let scene = try SVGImportFixture.scene("""
        <g id="outer" opacity="0.5" transform="translate(10 0)">
          <g inkscape:label="Layer 1"><rect id="box" width="10" height="10"/></g>
          <a xlink:href="https://example.com"><circle r="5"><title>Dot</title></circle></a>
          <a href="https://example.org"/>
          <g/>
        </g>
        <switch><rect width="1" height="1"/><circle r="1"/></switch>
        <g><title> Titled </title><rect width="1" height="1"/></g>
        """)
        guard case .group(let outer) = scene.nodes[0] else {
            Issue.record("expected a group")
            return
        }
        #expect(outer.name == "outer" && outer.opacity == 0.5)
        let paths = scene.scenePaths
        #expect(paths[0].name == "box" && paths[0].groupNames == ["outer", "Layer 1"])
        #expect(SVGImportFixture.anchors(paths[0])[0] == Point(x: 10, y: 0))
        #expect(paths[0].opacity == 0.5)
        #expect(paths[1].url == "https://example.com" && paths[1].name == "Dot")
        #expect(paths.count == 4)
        #expect(scene.nodes.count == 3)
        #expect(scene.nodes[2].name == "Titled")
    }

    @Test func unsupportedFeaturesAreNoted() throws {
        let scene = try SVGImportFixture.scene("""
        <defs><pattern id="p" width="4" height="4"><rect width="2" height="2"/></pattern><filter id="f"/><mask id="m"/><marker id="k"/></defs>
        <rect width="10" height="10" fill="url(#p)" filter="url(#f)"/>
        <rect width="10" height="10" fill="url(#p) red" mask="url(#m)" marker-end="url(#k)"/>
        <rect width="10" height="10" fill="url(#missing"/>
        <foreignObject width="10" height="10"/>
        <script>alert(1)</script>
        """, options: SVGImportOptions(animation: .convert))
        let paths = scene.scenePaths
        #expect(paths[0].fill == .none)
        #expect(paths[1].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(paths[2].fill == .none)
        for kind in ["patterns", "filters", "masks", "markers", "foreign objects"] {
            #expect(scene.notes.contains { $0.contains(kind) }, "\(kind)")
        }
        #expect(scene.notes.contains { $0.contains("contains animation") })
    }

    @Test func gradients() throws {
        let scene = try SVGImportFixture.scene("""
        <defs>
          <linearGradient id="lin"><stop offset="0" stop-color="red"/><stop offset="100%" style="stop-color: blue; stop-opacity: 0.5"/></linearGradient>
          <linearGradient id="user" gradientUnits="userSpaceOnUse" x1="10%" y1="0" x2="90" y2="0" spreadMethod="reflect" xlink:href="#lin"/>
          <linearGradient id="skew" gradientUnits="userSpaceOnUse" x2="10" gradientTransform="skewX(45)" spreadMethod="repeat" href="#lin"/>
          <radialGradient id="rad" cx="0.5" cy="0.5" r="0.5" fx="0.2" fy="0.5"><stop offset="0.7" stop-color="green"/><stop offset="0.2" stop-color="black"/></radialGradient>
          <radialGradient id="one"><stop stop-color="red"/></radialGradient>
          <radialGradient id="none"/>
          <linearGradient id="loopA" href="#loopB"/><linearGradient id="loopB" href="#loopA"/>
        </defs>
        <rect x="10" y="20" width="100" height="50" fill="url(#lin)" fill-opacity="0.5"/>
        <rect width="100" height="50" fill="url(#user)"/>
        <rect width="100" height="50" stroke="url(#skew)"/>
        <rect x="0" y="0" width="40" height="20" fill="url(#rad)"/>
        <rect width="10" height="10" fill="url(#one)"/>
        <rect width="10" height="10" fill="url(#none) blue"/>
        <line x2="10" stroke="url(#lin)"/>
        <rect width="10" height="10" fill="url(#loopA)"/>
        """)
        let paths = scene.scenePaths
        guard case .gradient(let linear) = paths[0].fill else {
            Issue.record("expected a gradient")
            return
        }
        #expect(linear.kind == .linear && linear.behavior == .normal)
        #expect(linear.axis?.start == Point(x: 10, y: 20) && linear.axis?.end == Point(x: 110, y: 20))
        #expect(linear.stops[0].color == Color(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(linear.stops[1].color == Color(red: 0, green: 0, blue: 1, alpha: 0.25))
        guard case .gradient(let user) = paths[1].fill else {
            Issue.record("expected a gradient")
            return
        }
        #expect(user.behavior == .reflect && user.stops.count == 2)
        #expect(user.axis?.start == Point(x: 10, y: 0) && user.axis?.end == Point(x: 90, y: 0))
        guard case .gradient(let skew)? = paths[2].stroke?.paint else {
            Issue.record("expected a gradient stroke")
            return
        }
        // Skewing shears the isolines to 45°, so the user-space axis runs perpendicular to them.
        #expect(skew.behavior == .repeat)
        #expect(SVGImportFixture.close(skew.axis!.end, Point(x: 5, y: -5)))
        guard case .gradient(let radial) = paths[3].fill else {
            Issue.record("expected a gradient")
            return
        }
        #expect(radial.kind == .radial)
        #expect(radial.axis == Gradient.Axis(start: Point(x: 20, y: 10), end: Point(x: 40, y: 10), end2: Point(x: 20, y: 20)))
        #expect(radial.stops.map(\.offset) == [0.7, 0.7])
        #expect(scene.notes.contains { $0.contains("focal") })
        #expect(paths[4].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(paths[5].fill == .solid(Color(red: 0, green: 0, blue: 1)))
        // A bounding-box gradient on a zero-height line falls back to no paint.
        #expect(paths[6].stroke == nil)
        #expect(paths[7].fill == .none)
    }

    @Test func useSymbolsAndNestedViewports() throws {
        let scene = try SVGImportFixture.scene("""
        <defs><rect id="r" width="10" height="10" fill="red"/>
          <symbol id="s" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></symbol>
          <symbol id="plain"><rect width="2" height="2"/></symbol>
          <g id="loop"><use href="#loop"/></g>
        </defs>
        <use xlink:href="#r" x="20" y="30"/>
        <use href="#s" width="20" height="20" x="50"/>
        <use href="#plain" id="named"/>
        <use href="#loop"/>
        <use href="#missing"/>
        <use/>
        <svg x="10" y="10" width="20" height="20" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>
        <svg width="20" height="20" overflow="visible"><rect width="5" height="5"/></svg>
        <svg width="0" height="20"><rect width="5" height="5"/></svg>
        <svg width="10" height="10"/>
        """)
        let paths = scene.scenePaths
        #expect(SVGImportFixture.anchors(paths[0])[0] == Point(x: 20, y: 30))
        #expect(paths[0].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        let symbol = SVGImportConverter.bounds(of: paths[1].contours)
        #expect(SVGImportFixture.close(symbol.minX, 50) && SVGImportFixture.close(symbol.width, 20))
        #expect(paths[2].groupNames.last == "named")
        #expect(scene.notes.contains { $0.contains("circular") })
        let nested = paths[3]
        #expect(SVGImportFixture.anchors(nested)[2] == Point(x: 30, y: 30))
        guard case .group(let viewport) = scene.nodes[3] else {
            Issue.record("expected the nested viewport group")
            return
        }
        #expect(viewport.clip != nil)
        guard case .group(let visible) = scene.nodes[4] else {
            Issue.record("expected the overflow-visible group")
            return
        }
        #expect(visible.clip == nil)
        #expect(scene.nodes.count == 5)
    }

    @Test func clipPaths() throws {
        let scene = try SVGImportFixture.scene("""
        <defs>
          <clipPath id="c1"><rect width="10" height="10" clip-rule="evenodd"/></clipPath>
          <clipPath id="c2" transform="translate(5 5)"><rect width="10" height="10"/><circle r="5" transform="scale(2)"/><use href="#shape" x="1"/><text>x</text></clipPath>
          <clipPath id="c3" clipPathUnits="objectBoundingBox"><rect width="0.5" height="1"/></clipPath>
          <clipPath id="empty"/>
          <path id="shape" d="M0 0 L0 10 L10 0 Z" transform="translate(1 0)"/>
        </defs>
        <rect width="50" height="50" clip-path="url(#c1)"/>
        <g clip-path="url('#c2')" transform="translate(100 0)"><rect width="50" height="50"/></g>
        <rect x="10" y="20" width="40" height="20" clip-path="url(#c3)"/>
        <rect width="5" height="5" clip-path="url(#empty)"/>
        <rect width="5" height="5" clip-path="url(#shape)"/>
        <g clip-path="url(#c3)"/>
        """)
        guard case .group(let first) = scene.nodes[0], let clip = first.clip else {
            Issue.record("expected a clip group")
            return
        }
        #expect(clip.fillRule == .evenOdd)
        guard case .group(let second) = scene.nodes[1], let union = second.clip else {
            Issue.record("expected a clip group")
            return
        }
        #expect(SVGImportFixture.rounded(Point(x: second.transform.tx, y: second.transform.a)) == Point(x: 100, y: 1))
        #expect(union.contours.count == 3 && union.fillRule == .nonZero)
        #expect(union.contours[0].start == Point(x: 5, y: 5))
        // The triangle referenced through `use` winds the other way; the union reverses it.
        let triangle = union.contours[2]
        #expect(SVGImportFixture.rounded(triangle.start) == Point(x: 17, y: 5) && triangle.segments.last?.end == Point(x: 7, y: 5))
        guard case .group(let third) = scene.nodes[2], let box = third.clip else {
            Issue.record("expected a clip group")
            return
        }
        #expect(SVGImportFixture.rounded(SVGImportConverter.bounds(of: box.contours)) == Rect(x: 10, y: 20, width: 20, height: 20))
        #expect(scene.nodes.count == 5)
        if case .path = scene.nodes[3] {} else { Issue.record("an empty clip path clips nothing") }
    }

    @Test func images() throws {
        let png = SVGImportFixture.png()
        let base64 = png.base64EncodedString()
        let percent = png.map { String(format: "%%%02X", $0) }.joined()
        let directory = ScratchFolders.directory()
        try png.write(to: directory.appendingPathComponent("pic.png"))
        let body = """
        <image id="a" x="10" y="10" width="40" height="40" xlink:href="data:image/png;base64,\(base64)"/>
        <image width="40" height="40" preserveAspectRatio="none" href="data:image/png,\(percent)"/>
        <image width="40" height="40" preserveAspectRatio="xMidYMid slice" href="data:image/png;base64,\(base64)"/>
        <image href="data:image/png;base64,\(base64)" opacity="0.5"/>
        <image href="pic.png" width="4" height="2"/>
        <image href="data:image/png;base64,AAAA"/>
        <image href="data:bad"/>
        <image href="data:image/png,%G1"/>
        <image href="data:image/png;base64,\(base64)" width="0" height="4"/>
        <image/>
        """
        let without = try SVGImportFixture.scene(body)
        #expect(without.notes.contains { $0.contains("outside the SVG") })
        #expect(without.notes.contains { $0.contains("could not be read") })
        let scene = try SVGImportFixture.scene(body, importer: SVGImporter(baseURL: directory.appendingPathComponent("doc.svg")))
        let images = scene.images
        #expect(images.count == 5)
        #expect(images[0].name == "a")
        // A 4 × 2 image meets a 40 × 40 box: 10× scale, centred vertically.
        #expect(SVGImportFixture.rounded(images[0].naturalRect.applying(images[0].transform)) == Rect(x: 10, y: 20, width: 40, height: 20))
        #expect(SVGImportFixture.rounded(images[1].naturalRect.applying(images[1].transform)) == Rect(x: 0, y: 0, width: 40, height: 40))
        guard case .group(let slice) = scene.nodes[2] else {
            Issue.record("expected a sliced image in a clip group")
            return
        }
        #expect(slice.clip != nil)
        guard case .group(let translucent) = scene.nodes[3] else {
            Issue.record("expected a translucent image group")
            return
        }
        #expect(translucent.opacity == 0.5)
        #expect(SVGImportFixture.rounded(images[3].naturalRect.applying(images[3].transform)) == Rect(x: 0, y: 0, width: 4, height: 2))
        #expect(scene.blobs.count == 1)
        #expect(SVGImportConverter.dataURL("nocomma") == nil)
    }

    @Test func text() throws {
        let scene = try SVGImportFixture.scene("""
        <text id="t" x="10" y="20" font-family="'Helvetica', sans-serif" font-size="12" fill="red">
          Hello <tspan font-weight="bold">bold</tspan><tspan x="10" dy="14" font-style="italic">next</tspan>
          <a><tspan display="none">gone</tspan></a><desc>skip</desc>
        </text>
        <text x="50" y="50" text-anchor="middle" font-family="NoSuchFontFamily" font-size="10">mid</text>
        <text x="50" y="60" text-anchor="end" font-family="serif" font-size="larger" xml:space="preserve"> end </text>
        <text x="0" y="0" dx="5" font-size="50%" font-weight="bolder" font-family="monospace">d<tspan font-weight="lighter">e</tspan><tspan font-weight="900">f</tspan><tspan font-weight="normal">g</tspan><tspan font-size="x-large">h</tspan><tspan font-size="smaller">i</tspan></text>
        <text visibility="hidden">hidden</text>
        <text>   </text>
        """)
        let texts = scene.nodes.compactMap { node -> ImportedText? in
            if case .text(let text) = node { return text }
            return nil
        }
        #expect(texts.count == 4)
        let first = texts[0]
        #expect(first.name == "t")
        #expect(first.runs.map(\.text) == ["Hello ", "bold", "next"])
        #expect(first.runs[0].fontName == "Helvetica" && first.runs[0].fontSize == 12)
        #expect(first.runs[1].fontName == "Helvetica-Bold")
        #expect(first.runs[1].origin.x > first.runs[0].origin.x)
        #expect(first.runs[2].origin == Point(x: 10, y: 34))
        #expect(first.runs[0].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        let middle = texts[1].runs[0]
        #expect(middle.fontName == "NoSuchFontFamily")
        #expect(middle.origin.x < 50)
        let end = texts[2].runs[0]
        #expect(end.text == " end ")
        #expect(end.fontName.contains("Times"))
        #expect(end.fontSize == 19.2)
        #expect(texts[3].runs[0].origin.x == 5)
        #expect(texts[3].runs[0].fontSize == 8)
        #expect(texts[3].runs[4].fontSize == 24)
        #expect(scene.texts.first == "Hello boldnext")
    }

    @Test func textAsOutlines() throws {
        let scene = try SVGImportFixture.scene("<text id=\"o\" x=\"10\" y=\"50\" font-family=\"Helvetica\" font-size=\"40\" fill=\"blue\" stroke=\"black\">Hi</text>", options: SVGImportOptions(text: .outlines))
        guard case .group(let group) = scene.nodes[0] else {
            Issue.record("expected a group of glyph paths")
            return
        }
        #expect(group.name == "o")
        let paths = scene.scenePaths
        #expect(paths.count == 1)
        #expect(paths[0].fill == .solid(Color(red: 0, green: 0, blue: 1)) && paths[0].stroke != nil)
        let bounds = SVGImportConverter.bounds(of: paths[0].contours)
        // Glyphs sit above the baseline at y = 50, cap height about 0.7 em.
        #expect(bounds.maxY <= 50.5 && bounds.minY > 15 && bounds.minX >= 10)
        let quads = CGMutablePath()
        quads.move(to: CGPoint.zero)
        quads.addQuadCurve(to: CGPoint(x: 2, y: 0), control: CGPoint(x: 1, y: 1))
        quads.addCurve(to: CGPoint(x: 3, y: 3), control1: CGPoint(x: 2, y: 1), control2: CGPoint(x: 3, y: 2))
        quads.addLine(to: CGPoint(x: 0, y: 3))
        quads.closeSubpath()
        #expect(SVGImportFont.contours(of: quads)[0].segments.count == 3)
    }

    @Test func flattenGroups() throws {
        let body = """
        <g transform="translate(10 0)" opacity="0.5"><g transform="scale(2)"><rect width="5" height="5" opacity="0.5"/></g>
          <text y="10">t</text>
          <g clip-path="url(#c)"><rect width="5" height="5"/></g></g>
        <defs><clipPath id="c"><rect width="2" height="2"/></clipPath></defs>
        """
        let scene = try SVGImportFixture.scene(body, options: SVGImportOptions(flattenGroups: true))
        #expect(scene.nodes.count == 3)
        guard case .path(let path) = scene.nodes[0] else {
            Issue.record("expected a flattened path")
            return
        }
        #expect(path.opacity == 0.25)
        #expect(SVGImportFixture.anchors(scene.scenePaths[0])[2] == Point(x: 20, y: 10))
        guard case .group(let wrapped) = scene.nodes[1], case .text = wrapped.children[0] else {
            Issue.record("expected the translucent text wrapped")
            return
        }
        #expect(wrapped.opacity == 0.5)
        guard case .group(let translucentClip) = scene.nodes[2], case .group(let clip) = translucentClip.children[0] else {
            Issue.record("expected the clip group kept")
            return
        }
        #expect(clip.clip != nil && translucentClip.opacity == 0.5)
        let unflattened = try SVGImportFixture.scene(body)
        #expect(unflattened.scenePaths.map(\.contours) == scene.scenePaths.map(\.contours))
    }

    @Test func compressedFiles() throws {
        let text = SVGImportFixture.svg("<rect width=\"10\" height=\"10\"/>")
        let compressed = SVGImportFixture.gzip(Data(text.utf8))
        #expect(ImportFormat.sniff(compressed) == .svg)
        let scene = try SVGImporter().convert(compressed, name: "a.svgz", format: .svg, options: ImportOptionValues(), context: ImportContext())
        #expect(scene.scenePaths.count == 1)
        var damaged = compressed
        damaged[damaged.count - 20] ^= 0xFF
        damaged.replaceSubrange(30..<40, with: Data(repeating: 0xFF, count: 10))
        #expect(throws: ImportError.self) { try SVGImporter().convert(damaged, name: "a.svgz", format: .svg, options: ImportOptionValues(), context: ImportContext()) }
        #expect(SVGImportTree.gunzip(Data([0x1F, 0x8B, 8, 0])) == nil)
        #expect(SVGImportTree.gunzip(Data([0x1F, 0x8B, 7] + [UInt8](repeating: 0, count: 20))) == nil)
        #expect(SVGImportTree.gunzip(Data([0x1F, 0x8B, 8, 0x04] + [UInt8](repeating: 0, count: 6) + [0xFF, 0xFF] + [UInt8](repeating: 0, count: 8))) == nil)
    }

    @Test func errors() {
        #expect(throws: ImportError.unreadable(name: "bad.svg", reason: "it is XML but not SVG.")) {
            try SVGImporter().convert(Data("<html/>".utf8), name: "bad.svg", format: .svg, options: ImportOptionValues(), context: ImportContext())
        }
        do {
            _ = try SVGImporter().probe(Data("<svg><g></svg>".utf8), name: "broken.svg", format: .svg)
            Issue.record("expected an error")
        } catch let error as ImportError {
            #expect(error.fileName == "broken.svg")
            #expect(error.description.contains("malformed"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: ImportError.self) { try SVGImporter.animationInfo(Data()) }
    }

    @Test func displayNoneRoot() throws {
        let scene = try SVGImportFixture.scene("<rect width=\"1\" height=\"1\"/>", root: "width=\"10\" height=\"10\" display=\"none\"")
        #expect(scene.nodes.isEmpty)
        let cdata = try SVGImportFixture.scene("<style><![CDATA[ rect { fill: blue } ]]></style><rect width=\"1\" height=\"1\"/>")
        #expect(cdata.scenePaths[0].fill == .solid(Color(red: 0, green: 0, blue: 1)))
    }
}

@Suite("SVG import animation")
struct SVGImportAnimationTests {
    func info(_ body: String) throws -> SVGAnimationInfo {
        try SVGImporter.animationInfo(Data(SVGImportFixture.svg(body).utf8))
    }

    @Test func css() throws {
        let keyframes = try info("<style>@keyframes spin { from { transform: rotate(0) } to { transform: rotate(360deg) } } .a { animation: spin 2s 0.5s 3 }</style><rect class=\"a\"/>")
        #expect(keyframes.css && !keyframes.smil && !keyframes.script)
        #expect(keyframes.durationMs == 6500)
        #expect(try info("<style>.a { animation: spin 2s infinite }</style>").durationMs == 0)
        #expect(try info("<rect style=\"transition: fill 300ms\"/>").durationMs == 300)
        let longhand = try info("<rect style=\"animation-name: a, b; animation-duration: 1s, 2s; animation-delay: 1s; animation-iteration-count: 2, 3\"/>")
        #expect(longhand.durationMs == 7000)
        #expect(try info("<rect style=\"animation-duration: 1s; animation-iteration-count: infinite\"/>").durationMs == 0)
        #expect(try info("<rect style=\"transition-duration: 1.5s; transition-delay: 500ms\"/>").durationMs == 2000)
        #expect(try info("<rect style=\"animation-duration: 4s; animation-iteration-count: x\"/>").durationMs == 4000)
        #expect(!(try info("<rect style=\"fill: red\"/>")).isAnimated)
    }

    @Test func smilAndScript() throws {
        let smil = try info("<rect><animate attributeName=\"x\" begin=\"1s\" dur=\"2s\" repeatCount=\"3\"/><set to=\"1\" begin=\"8s\"/><animateMotion end=\"00:00:05\"/><animateColor dur=\"1s\" repeatDur=\"4s\"/></rect>")
        #expect(smil.smil && smil.durationMs == 8000)
        #expect(try info("<animate dur=\"indefinite\"/>").durationMs == 0)
        #expect(try info("<animate dur=\"1s\" repeatCount=\"indefinite\"/>").durationMs == 0)
        #expect(try info("<animateTransform/>").durationMs == 0)
        let script = try info("<script>x()</script>")
        #expect(script.script && script.isAnimated)
        #expect(try info("<rect onclick=\"x()\"/>").script)
        #expect(SVGImportAnimation.clock("00:01:02.5") == 62.5)
        #expect(SVGImportAnimation.clock("02:30") == 150)
        #expect(SVGImportAnimation.clock("0.5min") == 30)
        #expect(SVGImportAnimation.clock("1h") == 3600)
        #expect(SVGImportAnimation.clock("150ms") == 0.15)
        #expect(SVGImportAnimation.clock("3") == 3)
        #expect(SVGImportAnimation.clock("a:b") == nil)
        #expect(SVGImportAnimation.clock("1:2:3:4") == nil)
        #expect(SVGImportAnimation.cssTime("2") == nil)
    }

    @Test func placement() throws {
        let animated = Data(SVGImportFixture.svg("<rect width=\"10\" height=\"10\"><animate dur=\"2s\"/></rect>").utf8)
        let importer = SVGImporter()
        #expect(try importer.probe(animated, name: "a.svg", format: .svg).placed)
        let placed = try importer.convert(animated, name: "a.svg", format: .svg, options: SVGImportOptions().values, context: ImportContext())
        #expect(placed.kind == .placed)
        guard case .placed(let file) = placed.nodes[0] else {
            Issue.record("expected a placed animation")
            return
        }
        #expect(file.kind == .svgAnimation(css: false, smil: true, script: false, durationMs: 2000))
        #expect(file.blob.data == animated && file.blob.uti == "public.svg-image")
        #expect(SVGImportFixture.rounded(file.bounds) == Rect(x: 0, y: 0, width: 100, height: 100))
        let converted = try importer.convert(animated, name: "a.svg", format: .svg, options: SVGImportOptions(animation: .convert).values, context: ImportContext())
        #expect(converted.kind == .vector && converted.scenePaths.count == 1)
        let forced = try importer.convert(Data(SVGImportFixture.svg("").utf8), name: "s.svg", format: .svg, options: SVGImportOptions(animation: .place).values, context: ImportContext())
        guard case .placed(let still) = forced.nodes[0] else {
            Issue.record("expected a placed file")
            return
        }
        #expect(still.kind == SVGAnimationInfo().placedKind)
    }

    @Test func sizeLimit() {
        let padding = String(repeating: "<!--" + String(repeating: "x", count: 1017) + "-->", count: SVGImporter.maximumAnimationSize / 1024 + 1)
        let data = Data(SVGImportFixture.svg("\(padding)<animate dur=\"1s\"/>").utf8)
        #expect(throws: ImportError.tooLarge(name: "big.svg", bytes: data.count, limit: SVGImporter.maximumAnimationSize)) {
            try SVGImporter().convert(data, name: "big.svg", format: .svg, options: SVGImportOptions().values, context: ImportContext())
        }
    }
}

@Suite("SVG import edge cases")
struct SVGImportEdgeCaseTests {
    @Test func explicitDefaultsAndBadValues() throws {
        let paths = try SVGImportFixture.paths("""
        <rect width="10" height="10" fill-rule="nonzero" clip-rule="nonzero" stroke="red" stroke-linecap="butt" stroke-linejoin="miter" fill="bogus" opacity="x" font-weight="heavy" font-style="oblique"/>
        <rect width="10" height="10" rx="-1" ry="2"/>
        <path/>
        <polygon/>
        <a><rect width="1" height="1"/></a>
        """)
        #expect(paths.count == 3)
        #expect(paths[0].fill == .none && paths[0].opacity == 1 && paths[0].fillRule == .nonZero)
        #expect(paths[0].stroke?.style.cap == .butt && paths[0].stroke?.style.join == .miter)
        #expect(paths[1].contours[0].segments.count == 8)
        #expect(paths[2].url == nil)
    }

    @Test func gradientEdgeCases() throws {
        let paths = try SVGImportFixture.paths("""
        <defs>
          <linearGradient id="a" x1="bogus" x2="x%"><stop offset="x"/><stop offset="y%" stop-color="blue"/></linearGradient>
          <linearGradient id="b" gradientUnits="userSpaceOnUse" x1="bogus" x2="50%"><stop offset="0"/><stop offset="1" stop-color="blue"/></linearGradient>
          <radialGradient id="c" fx="0.5" fy="0.2"><stop offset="0"/><stop offset="1"/></radialGradient>
        </defs>
        <rect width="10" height="10" fill="url(#a)"/>
        <rect width="10" height="10" fill="url(#b)"/>
        <rect width="10" height="10" fill="url(#c)"/>
        """)
        guard case .gradient(let a) = paths[0].fill, case .gradient(let b) = paths[1].fill else {
            Issue.record("expected gradients")
            return
        }
        #expect(a.stops.map(\.offset) == [0, 0] && a.axis?.start == Point(x: 0, y: 0) && a.axis?.end == Point(x: 0, y: 0))
        #expect(b.axis?.start == Point(x: 0, y: 0) && b.axis?.end == Point(x: 50, y: 0))
        #expect(paths[2].fill != .none)
    }

    @Test func clipAndBoundsEdgeCases() throws {
        let scene = try SVGImportFixture.scene("""
        <defs>
          <clipPath id="multi"><path d="M0 0 C0 10 10 10 10 0 Z"/><rect width="4" height="4"/><use href="#r" y="2"/></clipPath>
          <clipPath id="box" clipPathUnits="objectBoundingBox"><rect width="1" height="1"/></clipPath>
          <rect id="r" width="1" height="1"/>
        </defs>
        <rect width="5" height="5" clip-path="url(#multi)"/>
        <rect width="5" height="5" clip-path="inset(0)"/>
        <g clip-path="url(#box)"><g><rect x="2" y="2" width="1" height="1"/></g>
          <image x="1" y="1" width="2" height="2" href="data:image/png;base64,\(SVGImportFixture.png().base64EncodedString())"/>
          <text x="3" y="10" font-size="4">abc</text></g>
        """)
        guard case .group(let multi) = scene.nodes[0], let clip = multi.clip else {
            Issue.record("expected a clip group")
            return
        }
        // The downward bulge winds negatively in y-down space and is reversed.
        #expect(clip.contours[0].start == Point(x: 10, y: 0))
        #expect(clip.contours[2].start == Point(x: 0, y: 2))
        if case .path = scene.nodes[1] {} else { Issue.record("a non-url clip path is ignored") }
        guard case .group(let box) = scene.nodes[2], let unit = box.clip else {
            Issue.record("expected a bounding-box clip group")
            return
        }
        let bounds = SVGImportConverter.bounds(of: unit.contours)
        #expect(bounds.minX == 1 && bounds.minY == 1.5 && bounds.maxY == 10)
        let placed = ImportedNode.placed(ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data([1]), uti: "public.data"), bounds: Rect(x: 0, y: 0, width: 5, height: 5)))
        #expect(SVGImportConverter.bounds(of: [placed]) == Rect(x: 0, y: 0, width: 5, height: 5))
        guard case .placed(let moved) = SVGImportConverter.transformed(placed, by: .translation(x: 1, y: 0)) else {
            Issue.record("expected the placed file")
            return
        }
        #expect(moved.transform == .translation(x: 1, y: 0))
        #expect(SVGImportConverter.transformed(placed, by: .identity) == placed)
    }

    @Test func viewportsTextAndFlattenEdgeCases() throws {
        let scene = try SVGImportFixture.scene("""
        <svg><rect width="50%" height="1"/></svg>
        <image transform="translate(1 0)" width="4" height="2" href="data:image/png,%89PNG\(Self.percentTail())"/>
        <text font-family="''" y="5">x</text>
        <text font-family="Apple Chancery" font-weight="bold" font-style="italic" y="5">x</text>
        <g><title>a<desc/>b</title><text y="1">t</text></g>
        """, options: SVGImportOptions(flattenGroups: true))
        let paths = scene.scenePaths
        #expect(SVGImportConverter.bounds(of: paths[0].contours).width == 50)
        #expect(scene.images.count == 1 && scene.images[0].transform.tx == 1)
        let texts = scene.nodes.compactMap { node -> ImportedText? in
            if case .text(let text) = node { return text }
            return nil
        }
        #expect(texts[0].runs[0].fontName == "Helvetica")
        #expect(!texts[1].runs[0].fontName.isEmpty)
        #expect(texts.count == 3)
    }

    /// The PNG fixture after its first four bytes, alphanumerics left as themselves.
    static func percentTail() -> String {
        SVGImportFixture.png().dropFirst(4).map { byte -> String in
            let scalar = Unicode.Scalar(byte)
            return byte < 0x80 && (CharacterSet.alphanumerics.contains(scalar)) ? String(Character(scalar)) : String(format: "%%%02X", byte)
        }.joined()
    }

    @Test func valueEdgeCases() throws {
        #expect(SVGImportValues.color("rgba(0, 0, 0, x)")?.alpha == 1)
        let magenta = SVGImportValues.color("hsl(300, 100%, 50%)")!
        #expect(SVGImportFixture.close(magenta.red, 1) && SVGImportFixture.close(magenta.blue, 1) && SVGImportFixture.close(magenta.green, 0))
        #expect(SVGImportAnimation.smilEnd(SVGImportElement(name: "animate", attributes: ["begin": "", "dur": "2s"])) == 2)
        #expect(SVGImportAnimation.cssEnds(SVGImportStyleSheet.declarations("animation: spin")) == [0])
        let orphan = SVGImportElement(name: "rect", attributes: [:])
        let root = SVGImportElement(name: "svg", attributes: [:])
        orphan.parent = root
        #expect(SVGImportSelector("g rect")?.matches(orphan) == false)
        let title = SVGImportElement(name: "title", attributes: [:])
        title.content = [.text("a"), .element(SVGImportElement(name: "b", attributes: [:])), .text("c")]
        #expect(title.text == "ac")
    }
}
