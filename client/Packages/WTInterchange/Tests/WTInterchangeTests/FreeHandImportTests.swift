// IO-041: FreeHand import.  The converter is tested on the bridge's JSON written record by
// record (FreeHandRecordsFixture); the importer end to end on FreeHand 8 and 10 files written
// byte by byte (FreeHandFileFixture), through the vendored libfreehand.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite("FreeHand import")
struct FreeHandImportTests {
    typealias Fixture = FreeHandRecordsFixture

    /// The only layer's children.
    static func children(_ conversion: FreeHandConversion) -> [ImportedNode] {
        guard case .group(let layer)? = conversion.layers.first else { return [] }
        return layer.children
    }

    static func path(_ node: ImportedNode?) -> ImportedPath? {
        if case .path(let path)? = node { return path }
        return nil
    }

    static func group(_ node: ImportedNode?) -> ImportedGroup? {
        if case .group(let group)? = node { return group }
        return nil
    }

    static func text(_ node: ImportedNode?) -> ImportedText? {
        if case .text(let text)? = node { return text }
        return nil
    }

    // MARK: Pages and layers

    @Test("Pages are the scene's space: points, y down, the pages' union's top-left at the origin")
    func pages() throws {
        var f = Fixture()
        f.top["pages"] = [[1.0, 2.0, 9.5, 13.0], [11.0, 2.0, 19.5, 13.0], [0.0, 0.0, 0.0, 0.0]]
        f.layer([f.rect(1, 12, 1, 1)])
        let conversion = try f.convert()
        #expect(conversion.pages.count == 2)
        #expect(conversion.pages[0] == Rect(x: 0, y: 0, width: 612, height: 792))
        #expect(conversion.pages[1] == Rect(x: 720, y: 0, width: 612, height: 792))
        #expect(conversion.bounds == Rect(x: 0, y: 0, width: 1332, height: 792))
        // (1, 12) inches is 1 inch below the top-left corner.
        let path = try #require(Self.path(Self.children(conversion).first))
        #expect(path.contours[0].start.isApproximatelyEqual(to: Point(x: 0, y: 72), tolerance: 1e-9))
    }

    @Test("Without pages the union, then the tail's size, then US Letter")
    func pageFallbacks() throws {
        var f = Fixture()
        f.top["pages"] = []
        f.top["pageInfo"] = [2.0, 3.0, 6.0, 8.0]
        #expect(FreeHandConverter(records: try f.records(), name: "a").freeHandPages == [[2, 3, 6, 8]])
        f.top["pageInfo"] = [0.0, 0.0, 0.0, 0.0]
        f.top["tailPageInfo"] = [0.0, 0.0, 5.0, 7.0]
        #expect(FreeHandConverter(records: try f.records(), name: "a").freeHandPages == [[0, 0, 5, 7]])
        f.top["tailPageInfo"] = [0.0]
        #expect(FreeHandConverter(records: try f.records(), name: "a").freeHandPages == [[0, 0, 8.5, 11]])
    }

    @Test("Layers become layer groups; hidden, guide and empty layers are left out")
    func layers() throws {
        var f = Fixture()
        f.layer([f.rect(1, 1, 1, 1)], name: "Background", visibility: 1)
        f.layer([f.rect(1, 1, 1, 1)], name: "Guides", visibility: 11)
        f.layer([f.rect(1, 1, 1, 1)], name: "Secret", visibility: 2)
        f.layer([f.rect(1, 1, 1, 1)], name: nil, visibility: 2)
        f.layer([], name: "Empty")
        f.layer([f.rect(1, 1, 1, 1)], name: nil)
        f.layer([f.rect(2, 2, 1, 1)], name: "Top")
        let conversion = try f.convert()
        let names = conversion.layers.compactMap { Self.group($0).map { ($0.name ?? "", $0.role) } }
        #expect(names.map(\.0) == ["Background", "Layer", "Top"])
        #expect(names.allSatisfy { $0.1 == .layer })
        #expect(conversion.notes.contains("Hidden layers were left out: Secret, Unnamed."))
    }

    // MARK: Paths

    @Test("Path segments: lines, cubics, quadratics raised to cubics, arcs, closes; transforms baked")
    func pathSegments() throws {
        var f = Fixture()
        let move = f.transform([1, 0, 0, 1, 1, 0])
        let p = f.path([["M", 1.0, 9.0], ["L", 2.0, 9.0], ["C", 2.5, 9.0, 3.0, 8.5, 3.0, 8.0], ["Q", 3.0, 7.0, 2.0, 7.0],
                        ["A", 1.0, 1.0, 0.0, 0.0, 1.0, 1.0, 8.0], ["X", 1.0], ["L"], ["Z"]], xform: move, evenOdd: true)
        let empty = f.path([["M", 1.0, 1.0]])
        f.layer([p, empty])
        let children = Self.children(try f.convert())
        #expect(children.count == 1)
        let path = try #require(Self.path(children.first))
        #expect(path.fillRule == .evenOdd)
        let contour = path.contours[0]
        #expect(contour.closed)
        #expect(contour.start.isApproximatelyEqual(to: Point(x: 144, y: 72), tolerance: 1e-9))
        #expect(contour.segments.first == .line(to: Point(x: 216, y: 72)))
        #expect(contour.segments.count >= 4)
        #expect(path.transform == .identity)
    }

    @Test("Composite paths join their paths' contours in the first path's style, else their own")
    func compositePaths() throws {
        var f = Fixture()
        let red = f.basicFill(f.rgb(1, 0, 0))
        let blue = f.basicFill(f.rgb(0, 0, 1))
        let redStyle = f.propList(fill: red)
        let blueStyle = f.propList(fill: blue)
        let a = f.rect(1, 1, 2, 2, style: redStyle)
        let b = f.rect(1.5, 1.5, 1, 1)
        let c = f.rect(4, 4, 1, 1)
        f.layer([f.composite([a, b], style: blueStyle), f.composite([c], style: blueStyle), f.composite([]), f.composite([f.path([["M", 1.0, 1.0]])])])
        let children = Self.children(try f.convert())
        #expect(children.count == 2)
        #expect(Self.path(children[0])?.contours.count == 2)
        #expect(Self.path(children[0])?.fill == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(Self.path(children[1])?.fill == .solid(Color(red: 0, green: 0, blue: 1)))
    }

    // MARK: Groups and clipping

    @Test("Groups carry their transform to their children; empty groups vanish")
    func groups() throws {
        var f = Fixture()
        let scale = f.transform([2, 0, 0, 2, 0, 0])
        let inner = f.rect(1, 4, 1, 1)
        let group = f.group([inner, f.group([])], xform: scale)
        f.layer([group])
        let children = Self.children(try f.convert())
        let result = try #require(Self.group(children.first))
        #expect(result.children.count == 1)
        let path = try #require(Self.path(result.children.first))
        // (1, 4) doubled is (2, 8): 2 inches right, 2 inches below the top (10).
        #expect(path.contours[0].start.isApproximatelyEqual(to: Point(x: 144, y: 144), tolerance: 1e-9))
    }

    @Test("Clipping groups keep the clipping path's own fill and stroke")
    func clipGroups() throws {
        var f = Fixture()
        let fill = f.basicFill(f.rgb(0, 1, 0))
        let style = f.propList(fill: fill, stroke: f.basicLine(f.rgb(0, 0, 0)))
        let clip = f.rect(1, 1, 4, 4, style: style)
        let content = f.rect(0, 0, 2, 2)
        let clipped = f.group([clip, content], clip: true)
        let onlyClip = f.group([f.rect(1, 1, 1, 1)], clip: true)
        let notAPath = f.group([f.group([f.rect(1, 1, 1, 1)]), content], clip: true)
        let compositeClip = f.group([f.composite([f.rect(1, 1, 3, 3)]), content], clip: true)
        let empty = f.group([], clip: true)
        f.layer([clipped, onlyClip, notAPath, compositeClip, empty])
        let children = Self.children(try f.convert())
        #expect(children.count == 4)
        let group = try #require(Self.group(children[0]))
        #expect(group.clipAppearance)
        #expect(group.clip?.fill == .solid(Color(red: 0, green: 1, blue: 0)))
        #expect(group.clip?.stroke != nil)
        #expect(group.children.count == 1)
        #expect(Self.path(children[1]) != nil)
        #expect(Self.group(children[2])?.clip == nil)
        #expect(Self.group(children[3])?.clip?.contours.count == 1)
    }

    @Test("A path whose style holds contents clips them (Paste Inside)")
    func pasteInside() throws {
        var f = Fixture()
        let content = f.rect(2, 2, 1, 1)
        let plStyle = f.propList(contents: content)
        let gsStyle = f.graphicStyle([], elements: [String(Fixture.contents): content])
        let nothing = f.propList(contents: f.group([]))
        f.layer([f.rect(1, 1, 4, 4, style: plStyle), f.composite([f.rect(1, 1, 4, 4, style: gsStyle)]), f.rect(1, 1, 4, 4, style: nothing)])
        let children = Self.children(try f.convert())
        #expect(Self.group(children[0])?.clip != nil)
        #expect(Self.group(children[0])?.clipAppearance == true)
        #expect(Self.group(children[1])?.clip != nil)
        #expect(Self.path(children[2]) != nil)
        // Without a "contents" name nothing is pasted inside.
        f.top["contentsName"] = 0
        #expect(Self.path(Self.children(try f.convert())[0]) != nil)
    }

    @Test("Self-referring and very deep groups end without looping")
    func recursion() throws {
        var f = Fixture()
        // Group 20101 lists itself.
        f.set("lists", 20100, ["type": 0, "elements": [20101, 20102]])
        f.set("groups", 20101, ["style": 0, "elements": 20100, "xform": 0])
        let leaf = f.rect(1, 1, 1, 1)
        f.set("lists", 20103, ["type": 0, "elements": [leaf]])
        f.set("groups", 20102, ["style": 0, "elements": 20103, "xform": 0])
        var deepest = f.rect(1, 1, 1, 1)
        for _ in 0..<(FreeHandConverter.maximumDepth + 2) { deepest = f.group([deepest]) }
        f.layer([20101, deepest])
        let conversion = try f.convert()
        #expect(Self.group(Self.children(conversion).first)?.children.count == 1)
        #expect(conversion.notes.contains { $0.contains("nested more than") })
    }

    // MARK: Colours

    @Test("Colour records: Color6 and SpotColor6 components, process CMYK, spot inks, tints, previews")
    func colors() throws {
        var f = Fixture()
        let rgb6 = f.colorRecord(kind: 1, model: 1, components: [1, 0.5, 0])
        let cmyk6 = f.colorRecord(kind: 1, model: 2, components: [0.1, 0.87, 0.96, 1])
        let other = f.colorRecord(kind: 1, model: 3, components: [0.1], preview: [0.25, 0.5, 0.75])
        let named = f.colorRecord(kind: 2, name: "Leaf", model: 2, components: [0.5, 0, 1, 0])
        let pantone = f.colorRecord(kind: 2, name: "PANTONE 186 CV", model: 2, components: [0, 1, 0.8, 0.05])
        let tint6 = f.colorRecord(kind: 3, name: "", model: 1, components: [], preview: [0, 0, 1])
        let process = f.id()
        f.set("rgbColors", process, [0, 0, 0])
        f.set("colorRecords", process, ["kind": 4, "variant": 0, "name": f.string("Deep"), "other": 0, "cmyk": [65535, 0, 0, 32767], "raw": ""])
        let spot = f.id()
        f.set("rgbColors", spot, [65535, 0, 0])
        f.set("colorRecords", spot, ["kind": 5, "variant": 0, "name": f.string("Signal"), "other": 0, "raw": ""])
        let tint = f.id()
        f.set("tints", tint, ["base": rgb6, "tint": 32768])
        let cmykTint = f.id()
        f.set("tints", cmykTint, ["base": cmyk6, "tint": 65535])
        let bare = f.rgb(0.2, 0.4, 0.6)
        let converter = FreeHandConverter(records: try f.records(), name: "c")
        let orange = try #require(converter.color(rgb6)?.color)
        #expect(orange.space == .sRGB && orange.components.x == 1 && abs(orange.components.y - 0.5) < 0.001 && orange.components.z == 0)
        #expect(converter.color(cmyk6)?.color.space == .cmyk)
        #expect(converter.color(cmyk6)?.color.components.w == 1)
        #expect(converter.color(other)?.color == Color(red: 16383.0 / 65535, green: 32767.0 / 65535, blue: 49151.0 / 65535))
        guard case .swatch(let leaf)? = converter.colorPaint(named) else {
            Issue.record("expected a named colour")
            return
        }
        #expect(leaf.name == "Leaf" && !leaf.spot && leaf.color.space == .cmyk && abs(leaf.color.components.x - 0.5) < 0.001)
        #expect(converter.color(pantone)?.spot == true)
        #expect(converter.color(tint6)?.name == nil)
        #expect(converter.color(process)?.color == Color(cyan: 1, magenta: 0, yellow: 0, black: 32767.0 / 65535))
        #expect(converter.color(spot)?.spot == true)
        let tinted = try #require(converter.color(tint)?.color)
        #expect(abs(tinted.components.x - 1) < 1e-9 && abs(tinted.components.z - 0.5) < 0.01)
        #expect(converter.color(cmykTint)?.color.space == .cmyk)
        #expect(converter.colorPaint(bare) == .solid(Color(red: 0.2, green: 0.4, blue: 0.6)))
        #expect(converter.color(9999) == nil)
        #expect(FreeHandConverter.components(Data([0])) == nil)
        #expect(FreeHandConverter.isSpotLibraryName("toyo 0001"))
        #expect(!FreeHandConverter.isSpotLibraryName("Leaf"))
    }

    // MARK: Styles

    @Test("Property lists inherit fill and stroke from their parents")
    func propertyLists() throws {
        var f = Fixture()
        let black = f.basicLine(f.rgb(0, 0, 0), width: 2.0 / 72, pattern: f.id())
        let dashes = f.id()
        f.set("linePatterns", dashes, [4.0, 2.0])
        let dashed = f.basicLine(f.rgb(1, 0, 0), width: 1.0 / 72, pattern: dashes, miter: 0)
        let parent = f.propList(stroke: black)
        let child = f.propList(fill: f.basicFill(f.rgb(0, 0, 1)), parent: parent)
        let override = f.propList(stroke: dashed, parent: child)
        let loop = f.id()
        f.set("propertyLists", loop, ["parent": loop, "elements": [:]])
        f.layer([f.rect(1, 1, 1, 1, style: child), f.rect(1, 1, 1, 1, style: override), f.rect(1, 1, 1, 1, style: loop)])
        let children = Self.children(try f.convert())
        let first = try #require(Self.path(children[0]))
        #expect(first.fill == .solid(Color(red: 0, green: 0, blue: 1)))
        #expect(first.stroke?.style.width == 2)
        #expect(first.stroke?.style.dash == [])
        let second = try #require(Self.path(children[1]))
        #expect(second.stroke?.style.dash == [4, 2])
        #expect(second.stroke?.style.miterLimit == 4)
        #expect(Self.path(children[2])?.fill == ImportedPaint.none)
    }

    @Test("Graphic styles: attribute holders and their parents, filters for opacity, shadows and glows")
    func graphicStyles() throws {
        var f = Fixture()
        let fill = f.basicFill(f.rgb(1, 1, 0))
        let line = f.basicLine(f.rgb(0, 0, 0))
        let inherited = f.holder(0, parent: f.holder(fill))
        let base = f.graphicStyle([inherited, f.holder(line), f.holder(0)])
        let opacity = f.id()
        f.set("opacityFilters", opacity, 0.5)
        let shadow = f.id()
        f.set("shadowFilters", shadow, ["color": 0, "knockOut": false, "inner": false, "distribution": 1, "opacity": 1, "smoothness": 1, "angle": 45])
        let glow = f.id()
        f.set("glowFilters", glow, ["color": 0, "inner": false, "width": 1, "opacity": 1, "smoothness": 1, "distribution": 0])
        let filters = f.list([opacity, shadow, glow])
        let styled = f.graphicStyle([f.filterHolder(filter: filters, style: base)])
        let single = f.graphicStyle([f.filterHolder(filter: shadow, style: base)])
        f.layer([f.rect(1, 1, 1, 1, style: styled), f.group([f.rect(1, 1, 1, 1)], style: single), f.rect(1, 1, 1, 1, style: f.graphicStyle([], parent: base))])
        let conversion = try f.convert()
        let children = Self.children(conversion)
        let path = try #require(Self.path(children[0]))
        #expect(path.fill == .solid(Color(red: 1, green: 1, blue: 0)))
        #expect(path.stroke != nil)
        #expect(path.opacity == 0.5)
        #expect(Self.path(children[2])?.fill == .solid(Color(red: 1, green: 1, blue: 0)))
        #expect(conversion.notes.contains("2 shadows and 1 glow were left out."))
    }

    // MARK: Fills

    @Test("Graduated and radial fills become gradients across the bounds")
    func gradients() throws {
        var f = Fixture()
        let red = f.rgb(1, 0, 0)
        let blue = f.rgb(0, 0, 1)
        let green = f.rgb(0, 1, 0)
        let stops = f.id()
        f.set("multiColorLists", stops, [[Double(red), 0.0], [Double(green), 0.5], [Double(blue), 1.0]])
        let linear = f.id()
        f.set("linearFills", linear, ["color1": red, "color2": blue, "angle": 90.0, "multiColorList": 0])
        let multi = f.id()
        f.set("linearFills", multi, ["color1": red, "color2": blue, "angle": 0.0, "multiColorList": stops])
        let radial = f.id()
        f.set("radialFills", radial, ["color1": red, "color2": 9999, "cx": 0.5, "cy": 0.25, "multiColorList": 0])
        f.layer([f.rect(1, 1, 2, 2, style: f.propList(fill: linear)), f.rect(1, 1, 2, 2, style: f.propList(fill: multi)),
                 f.rect(1, 1, 2, 2, style: f.propList(fill: radial))])
        let children = Self.children(try f.convert())
        guard case .gradient(let vertical)? = Self.path(children[0])?.fill, case .gradient(let three)? = Self.path(children[1])?.fill,
              case .gradient(let round)? = Self.path(children[2])?.fill else {
            Issue.record("expected gradients")
            return
        }
        // 90° runs down the page: from the top edge to the bottom.
        #expect(vertical.axis!.start.isApproximatelyEqual(to: Point(x: 144, y: 504), tolerance: 1e-6))
        #expect(vertical.axis!.end.isApproximatelyEqual(to: Point(x: 144, y: 648), tolerance: 1e-6))
        #expect(vertical.stops.map(\.color) == [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 0, blue: 1)])
        #expect(three.stops.count == 3)
        #expect(round.kind == .radial)
        #expect(round.axis!.start.isApproximatelyEqual(to: Point(x: 144, y: 612), tolerance: 1e-6))
        // The first colour is outside.
        #expect(round.stops.first { $0.offset == 1 }?.color == Color(red: 1, green: 0, blue: 0))
        #expect(round.stops.first { $0.offset == 0 }?.color == .black)
    }

    @Test("Lens, tile, pattern and custom fills")
    func liveFills() throws {
        var f = Fixture()
        let color = f.rgb(0, 0, 1)
        var lenses: [Int] = []
        for mode in 0...5 {
            let lens = f.id()
            f.set("lensFills", lens, ["color": color, "value": mode == 1 ? 3.0 : 40.0, "mode": mode])
            lenses.append(lens)
        }
        let tileArt = f.group([f.rect(0, 0, 0.5, 0.5, style: f.propList(fill: f.basicFill(color)))])
        let tile = f.id()
        f.set("tileFills", tile, ["xform": 0, "group": tileArt, "scaleX": 0.5, "scaleY": 0, "offsetX": 0.25, "offsetY": 0.5, "angle": 30.0])
        let emptyTile = f.id()
        f.set("tileFills", emptyTile, ["xform": 0, "group": 0, "scaleX": 1, "scaleY": 1, "offsetX": 0, "offsetY": 0, "angle": 0])
        let pattern = f.id()
        f.set("patternFills", pattern, ["color": color, "pattern": "aa55aa55aa55aa55"])
        let custom = f.id()
        f.set("customProcs", custom, ["ids": [color], "widths": [], "params": [], "angles": []])
        let bareCustom = f.id()
        f.set("customProcs", bareCustom, ["ids": [], "widths": [], "params": [], "angles": []])
        let fills = lenses + [tile, emptyTile, pattern, custom, bareCustom]
        f.layer(fills.map { f.rect(1, 1, 1, 1, style: f.propList(fill: $0)) })
        let conversion = try f.convert()
        let paints = Self.children(conversion).compactMap { Self.path($0)?.fill }
        let types: [LensType] = [.transparency, .magnify, .lighten, .darken, .invert, .monochrome]
        for (paint, type) in zip(paints, types) {
            guard case .lens(let lens) = paint else {
                Issue.record("expected a lens")
                continue
            }
            #expect(lens.type == type)
        }
        if case .lens(let magnify) = paints[1] { #expect(magnify.magnification == 3) }
        guard case .tiled(let tiled) = paints[6] else {
            Issue.record("expected a tile")
            return
        }
        #expect(tiled.scaleX == 50 && tiled.scaleY == 100)
        #expect(tiled.angle == -30)
        #expect(tiled.offset == Point(x: 18, y: -36))
        #expect(tiled.nodes.count == 1)
        #expect(paints[7] == ImportedPaint.none)
        #expect(paints[8] == .pattern(PatternPaint(bitmap: .checker, color: Color(red: 0, green: 0, blue: 1))))
        #expect(paints[9] == .solid(Color(red: 0, green: 0, blue: 1)))
        #expect(paints[10] == .solid(.black))
        #expect(conversion.notes.contains("2 custom fills were imported as its colour.") || conversion.notes.contains { $0.hasPrefix("2 custom fills") })
    }

    // MARK: Strokes

    @Test("Strokes: width by the transform, arrowheads, pattern lines")
    func strokes() throws {
        var f = Fixture()
        let arrow = f.id()
        f.set("arrowPaths", arrow, ["style": 0, "xform": 0, "evenOdd": false, "closed": true, "d": [["M", 0.0, 0.0], ["L", -3.0, 1.5], ["L", -3.0, -1.5], ["Z"]]])
        let emptyArrow = f.id()
        f.set("arrowPaths", emptyArrow, ["style": 0, "xform": 0, "evenOdd": false, "closed": true, "d": [["M", 0.0, 0.0]]])
        let line = f.basicLine(9999, width: 2.0 / 72, start: arrow, end: emptyArrow)
        let patternLine = f.id()
        f.set("patternLines", patternLine, ["color": f.rgb(1, 0, 0), "percent": 0.5, "miter": 0, "width": 3.0 / 72])
        let doubled = f.transform([2, 0, 0, 2, 0, 0])
        f.layer([f.rect(1, 1, 1, 1, style: f.propList(stroke: line), xform: doubled), f.rect(1, 1, 1, 1, style: f.propList(stroke: patternLine))])
        let conversion = try f.convert()
        let children = Self.children(conversion)
        let stroke = try #require(Self.path(children[0])?.stroke)
        #expect(stroke.style.width == 4)
        #expect(stroke.paint == .solid(.black))
        #expect(stroke.startArrowhead?.contours.first?.segments.first == .line(to: Point(x: -3, y: -1.5)))
        #expect(stroke.endArrowhead == nil)
        #expect(Self.path(children[1])?.stroke?.style.width == 3)
        #expect(conversion.notes.contains("1 pattern stroke was imported as plain strokes."))
    }

    // MARK: Text

    @Test("Area text: paragraphs, runs, fonts, colours and alignment in the frame")
    func areaText() throws {
        var f = Fixture()
        let bold = f.agdFont("Helvetica", style: 1, size: 20)
        let plain = f.charProperties(color: f.rgb(1, 0, 0), size: 14, fontName: "Helvetica")
        let heavy = f.charProperties(size: 0, font: bold)
        let first = f.paragraph("Hello", properties: plain, alignment: 2)
        let second = f.paragraph("World\u{0B}!", properties: heavy, alignment: 2)
        let blank = f.paragraph("", properties: plain)
        let text = f.textObject([first, blank, second], x: 1, y: 9, width: 3, height: 2)
        f.layer([text])
        let result = try #require(Self.text(Self.children(try f.convert()).first))
        #expect(result.frame == Size(width: 216, height: 144))
        #expect(result.alignment == .center)
        #expect(result.runs.map(\.text) == ["Hello", "", "World!"])
        #expect(result.runs[0].family == "Helvetica")
        #expect(result.runs[0].fontSize == 14)
        #expect(result.runs[0].fill == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(result.runs[2].style == "Bold")
        #expect(result.runs[2].fontSize == 20)
        // The frame's top-left corner, (1, 9) inches, is 1 inch from the top.
        #expect(result.transform.apply(Point(x: 0, y: 0)).isApproximatelyEqual(to: Point(x: 72, y: 72), tolerance: 1e-9))
        #expect(result.runs[0].origin.x > 0)
    }

    @Test("Linked frames show their part of the string; columns are one frame")
    func textRanges() throws {
        var f = Fixture()
        let props = f.charProperties()
        let a = f.paragraph("abc", properties: props, alignment: 1)
        let b = f.paragraph("defg", properties: props, alignment: 3)
        let missing = f.id()
        f.layer([f.textObject([a, b], begin: 5, end: 7), f.textObject([a, missing, b], end: 2, columns: 2), f.textObject([a], end: 0),
                 f.textObject([f.paragraph("", properties: props)])])
        let conversion = try f.convert()
        let children = Self.children(conversion)
        #expect(Self.text(children[0])?.runs.map(\.text) == ["ef"])
        #expect(Self.text(children[0])?.alignment == .justify)
        #expect(Self.text(children[1])?.runs.map(\.text) == ["ab"])
        #expect(Self.text(children[1])?.alignment == .right)
        #expect(Self.text(children[2])?.runs.map(\.text) == ["abc"])
        #expect(children.count == 3)
        #expect(conversion.notes.contains("1 text block with columns or rows was imported as one frame."))
    }

    @Test("Text on a path keeps the path in the block's space")
    func textOnPath() throws {
        var f = Fixture()
        let props = f.charProperties()
        let path = f.path([["M", 1.0, 5.0], ["L", 4.0, 5.0]])
        let compound = f.composite([f.path([["M", 1.0, 6.0], ["L", 4.0, 6.0]])])
        let squeeze = f.transform([1.5, 0, 0, 1, 0, 0])
        let dot = f.path([["M", 1.0, 1.0]])
        f.layer([f.textObject([f.paragraph("Along", properties: props)], width: 0, height: 0, xform: squeeze, path: path),
                 f.textObject([f.paragraph("Arc", properties: props)], width: 0, height: 0, path: compound),
                 f.textObject([f.paragraph("None", properties: props)], width: 0, height: 0, path: dot),
                 f.textObject([f.paragraph("Point", properties: props)], width: 0, height: 0)])
        let children = Self.children(try f.convert())
        let along = try #require(Self.text(children[0]))
        let onPath = try #require(along.path)
        let start = along.transform.apply(onPath.contours[0].start)
        #expect(start.isApproximatelyEqual(to: Point(x: 72, y: 360), tolerance: 1e-9))
        #expect(along.frame == nil)
        #expect(Self.text(children[1])?.path != nil)
        #expect(children.count == 3)
        #expect(Self.text(children[2])?.frame == nil && Self.text(children[2])?.path == nil)
    }

    @Test("FreeHand 3 to 7 display text: MacRoman characters, property runs, line ends")
    func displayText() throws {
        var f = Fixture()
        let red = f.rgb(1, 0, 0)
        let font = f.string("Times")
        let text = f.id()
        let characters: [UInt8] = [0x43, 0x61, 0x66, 0x8E, 0x0D, 0x4E, 0x65, 0x78, 0x74, 0x0A]    // "Café\rNext\n" in MacRoman
        f.set("displayTexts", text, ["style": 0, "xform": 0, "startX": 1.0, "startY": 9.0, "width": 3.0, "height": 1.0, "justify": 1,
                                     "charProps": [["offset": 0, "fontName": font, "fontSize": 18.0, "fontStyle": 3, "fontColor": red, "textEffs": 0, "leading": -1.0,
                                                    "letterSpacing": 0.0, "wordSpacing": 0.0, "horizontalScale": 1.0, "baselineShift": 0.0],
                                                   ["offset": 2, "fontName": 0, "fontSize": 0.0, "fontStyle": 0, "fontColor": 0, "textEffs": 0, "leading": -1.0,
                                                    "letterSpacing": 0.0, "wordSpacing": 0.0, "horizontalScale": 1.0, "baselineShift": 0.0]],
                                     "paraOffsets": [], "characters": characters.map { String(format: "%02x", $0) }.joined()])
        let pathText = f.id()
        f.set("pathTexts", pathText, ["elements": 0, "layer": 0, "displayText": text, "shape": 0, "textSize": 0])
        let empty = f.id()
        f.set("displayTexts", empty, ["style": 0, "xform": 0, "startX": 0.0, "startY": 0.0, "width": 0.0, "height": 0.0, "justify": 0, "charProps": [],
                                      "paraOffsets": [], "characters": ""])
        let controls = f.id()
        f.set("displayTexts", controls, ["style": 0, "xform": 0, "startX": 0.0, "startY": 0.0, "width": 0.0, "height": 0.0, "justify": 2, "charProps": [],
                                         "paraOffsets": [], "characters": "0102"])
        f.layer([text, pathText, empty, controls])
        let children = Self.children(try f.convert())
        #expect(children.count == 2)
        let result = try #require(Self.text(children[0]))
        #expect(result.runs.map(\.text) == ["Ca", "fé", "Next"])
        #expect(result.runs[0].style == "Bold Italic")
        #expect(result.runs[0].family == "Times")
        #expect(result.runs[1].family == "Helvetica")
        #expect(result.alignment == .center)
        #expect(result.frame == Size(width: 216, height: 72))
        #expect(FreeHandConverter.displayAlignment(2) == .right)
        #expect(FreeHandConverter.displayAlignment(3) == .justify)
        #expect(FreeHandConverter.styleName(bold: false, italic: true) == "Italic")
    }

    // MARK: Images

    @Test("Images: the data list's bytes placed on FreeHand's rectangle; unreadable ones are noted")
    func images() throws {
        var f = Fixture()
        let png = FreeHandImportTests.png(width: 4, height: 2)
        let half = f.id()
        f.set("data", half, png.prefix(10).map { String(format: "%02x", $0) }.joined())
        let rest = f.id()
        f.set("data", rest, png.dropFirst(10).map { String(format: "%02x", $0) }.joined())
        let list = f.id()
        f.set("dataLists", list, ["size": png.count, "elements": [half, rest]])
        let image = f.id()
        f.set("images", image, ["style": 0, "dataList": list, "xform": 0, "startX": 1.0, "startY": 1.0, "width": 2.0, "height": 1.0, "format": "PNG"])
        let broken = f.id()
        f.set("data", broken, "00010203")
        let brokenList = f.id()
        f.set("dataLists", brokenList, ["size": 4, "elements": [broken]])
        let bad = f.id()
        f.set("images", bad, ["style": 0, "dataList": brokenList, "xform": 0, "startX": 1.0, "startY": 1.0, "width": 2.0, "height": 1.0, "format": ""])
        let none = f.id()
        f.set("images", none, ["style": 0, "dataList": 0, "xform": 0, "startX": 1.0, "startY": 1.0, "width": 2.0, "height": 1.0, "format": ""])
        f.layer([image, bad, none])
        let conversion = try f.convert()
        let children = Self.children(conversion)
        #expect(children.count == 1)
        guard case .image(let result)? = children.first else {
            Issue.record("expected an image")
            return
        }
        #expect(result.pixels.width == 4)
        let rect = result.naturalRect.applying(result.transform)
        #expect(abs(rect.minX - 72) < 1e-9 && abs(rect.width - 144) < 1e-9)
        #expect(abs(rect.minY - 576) < 1e-9 && abs(rect.height - 72) < 1e-9)
        #expect(conversion.notes.contains("2 images could not be read and were left out."))
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Blends and symbols

    @Test("Blends import as groups of their steps")
    func blends() throws {
        var f = Fixture()
        let blend = f.id()
        f.set("newBlends", blend, ["style": 0, "parent": 0, "list1": f.list([f.rect(1, 1, 1, 1)]), "list2": f.list([f.rect(2, 2, 1, 1)]), "list3": 0])
        let empty = f.id()
        f.set("newBlends", empty, ["style": 0, "parent": 0, "list1": 0, "list2": 0, "list3": 0])
        f.layer([blend, empty])
        let conversion = try f.convert()
        let group = try #require(Self.group(Self.children(conversion).first))
        #expect(group.name == "Blend")
        #expect(group.children.count == 2)
        #expect(conversion.notes.contains("1 blend was imported as groups of their steps."))
    }

    @Test("Symbol instances become instance groups of one symbol")
    func symbols() throws {
        var f = Fixture()
        let art = f.group([f.rect(0, 0, 1, 1)])
        let symbolClass = f.id()
        f.set("symbolClasses", symbolClass, ["name": f.string("Star"), "group": art, "dateTime": 0, "library": 0, "list": 0])
        let unnamed = f.id()
        f.set("symbolClasses", unnamed, ["name": 0, "group": f.rect(0, 0, 1, 1), "dateTime": 0, "library": 0, "list": 0])
        let hollow = f.id()
        f.set("symbolClasses", hollow, ["name": 0, "group": 0, "dateTime": 0, "library": 0, "list": 0])
        var instances: [Int] = []
        for (klass, x) in [(symbolClass, 2.0), (symbolClass, 4.0), (unnamed, 1.0), (hollow, 1.0), (7777, 1.0)] {
            let id = f.id()
            f.set("symbolInstances", id, ["style": 0, "parent": 0, "symbolClass": klass, "xform": [1.0, 0, 0, 1, x, 1]])
            instances.append(id)
        }
        f.layer(instances)
        let conversion = try f.convert()
        let children = Self.children(conversion)
        #expect(children.count == 3)
        #expect(conversion.symbols.map(\.name) == ["Star", "Symbol 2"])
        let first = try #require(Self.group(children[0]))
        #expect(first.role == .instance(symbol: "freehand-\(symbolClass)"))
        #expect(first.name == "Star")
        // The symbol's (0, 0) inches lands at (2, 1): 2 inches right, 9 inches down.
        #expect(first.transform.apply(Point(x: 0, y: 0)).isApproximatelyEqual(to: Point(x: 144, y: 648), tolerance: 1e-9))
        #expect(abs((Self.group(children[1])?.transform.apply(.zero).x ?? 0) - 288) < 1e-9)
    }

    // MARK: Notices

    @Test("A partly read file and features WireTuner does not read are named")
    func fileNotes() throws {
        var f = Fixture()
        f.top["complete"] = false
        f.top["recordsRead"] = 5
        f.top["stoppedAt"] = "Mystery"
        f.top["recordTypes"] = ["Envelope": 2, "PerspectiveEnvelope": 1, "NewContourFill": 1, "ContourFill": 1, "Path": 4]
        f.layer([f.rect(1, 1, 1, 1)])
        let notes = try f.convert().notes
        #expect(notes.contains("The file could only be read in part (5 of 10 records at a “Mystery” record); the rest is missing."))
        #expect(notes.contains("Not imported: envelopes, perspective projections, contour gradients; the objects using them come in without them."))
        f.top["stoppedAt"] = nil
        #expect(try f.convert().notes.first == "The file could only be read in part (5 of 10 records); the rest is missing.")
    }

    // MARK: Records

    @Test("Record JSON: hex bytes, id tables, segments, missing fields")
    func recordDecoding() throws {
        let json = #"{"data": {"4": "0aFz 1", "x": "00"}, "paths": {"2": {"style": 1, "xform": 0, "evenOdd": false, "closed": false, "d": [["M", 1, 2], ["Z"]]}}}"#
        let records = try JSONDecoder().decode(FreeHandRecords.self, from: Data(json.utf8))
        #expect(records.data[4]?.data == Data([0x0a, 0xF1]))
        #expect(records.data.values.count == 1)
        #expect(records.paths[2]?.d.map(\.action) == ["M", "Z"])
        #expect(records.paths[0] == nil)
        #expect(records.version == 0 && records.complete && records.layers.values.isEmpty)
        #expect(FreeHandConverter.affine([1, 2]) == .identity)
        #expect(FreeHandConverter.affine([1, 0, 0, 1, .nan, 0]) == .identity)
    }

    // MARK: The importer, end to end

    @Test("A FreeHand 8 file imports through libfreehand: layer, square, process colour swatch")
    func freeHand8File() throws {
        let data = FreeHandFileFixture.square(version: 8)
        #expect(ImportFormat.sniff(data) == .freehand)
        let registry = ImportRegistry.standard
        #expect(registry.format(of: data, name: "Square.fh8") == .freehand)
        let descriptor = try registry.probe(data, name: "Square.fh8")
        #expect(descriptor.format == .freehand)
        #expect(descriptor.pageCount == 1)
        #expect(abs(descriptor.naturalSize.width - 612) < 1e-9)
        let scene = try registry.convert(data, name: "Square.fh8")
        #expect(scene.kind == .vector)
        let layer = try #require(Self.group(scene.nodes.first))
        #expect(layer.name == "Artwork")
        #expect(layer.role == .layer)
        let path = try #require(Self.path(layer.children.first))
        guard case .swatch(let swatch) = path.fill else {
            Issue.record("expected a named colour, got \(path.fill)")
            return
        }
        #expect(swatch.name == "Leaf")
        #expect(swatch.color.space == .cmyk)
        #expect(abs(swatch.color.components.x - 0.8) < 0.001)
        #expect(scene.swatches == [swatch])
        // The square spans (1, 1) to (3, 3) inches on an 11-inch page.
        #expect(path.contours[0].allPoints.contains { $0.isApproximatelyEqual(to: Point(x: 72, y: 720), tolerance: 1e-6) })
    }

    @Test("A FreeHand 10 file (0x1C records, compressed) imports with its RGB named colour")
    func freeHand10File() throws {
        let data = FreeHandFileFixture.square(version: 10, layerName: "Foreground", colorName: "Moss")
        #expect(ImportFormat.sniff(data) == .freehand)
        let scene = try FreeHandImporter().convert(data, name: "Square.FH10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        let layer = try #require(Self.group(scene.nodes.first))
        guard case .swatch(let swatch)? = Self.path(layer.children.first)?.fill else {
            Issue.record("expected a named colour")
            return
        }
        #expect(swatch.name == "Moss")
        #expect(abs(swatch.color.components.y - 0.6) < 0.001)
        let (pages, same) = try FreeHandImporter().pages(data, name: "Square.FH10")
        #expect(pages == [Rect(x: 0, y: 0, width: 612, height: 792)])
        #expect(same.nodes == scene.nodes)
    }

    @Test("Refusals: not FreeHand, damaged, nothing to import, too large")
    func refusals() throws {
        let importer = FreeHandImporter()
        #expect(throws: ImportError.unreadable(name: "x.fh10", reason: "it is not a FreeHand document.")) {
            try importer.convert(Data("AGX1 not really".utf8), name: "x.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        }
        #expect(!FreeHandFile.isFreeHand(Data("hello".utf8)))
        #expect(!FreeHandFile.isFreeHand(Data()))
        // An AGD header with nothing behind it.
        var header = Data("AGD5".utf8)
        header.append(Data(count: 4))
        header.append(contentsOf: [0, 0, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: ImportError.self) {
            try importer.convert(header, name: "bad.fh10", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        }
        // A file whose only layer is empty.
        var file = FreeHandFileFixture(version: 8)
        let name = file.mString("Empty")
        let elements = file.list([])
        let layer = file.layer(elements: elements, name: name)
        file.block(layerList: file.list([layer]))
        #expect(throws: ImportError.empty(name: "empty.fh8")) {
            try importer.convert(file.data(), name: "empty.fh8", format: .freehand, options: ImportOptionValues(), context: ImportContext())
        }
        #expect(throws: ImportError.self) {
            try importer.convert(FreeHandFileFixture.square(version: 8), name: "big.fh8", format: .freehand, options: ImportOptionValues(),
                                 context: ImportContext(maximumFileSize: 10))
        }
        #expect(throws: ImportError.self) {
            _ = try FreeHandImporter.records(Data("{".utf8) + Data("AGD".utf8), name: "x")
        }
    }

    @Test("The format: extensions, type, sniffing, the Open panel's types")
    func format() {
        #expect(ImportFormat(fileExtension: "FH10") == .freehand)
        #expect(ImportFormat(fileExtension: "ft11") == .freehand)
        #expect(ImportFormat.freehand.displayName == "FreeHand")
        #expect(!ImportFormat.freehand.isBitmap)
        #expect(ImportRegistry.standard.availableFormats.contains(.freehand))
        #expect(ImportRegistry.standard.acceptedUTIs.contains("com.macromedia.freehand"))
        // No system type for FreeHand in the test host: a type per extension instead.
        let types = ImportRegistry.standard.acceptedTypes
        #expect(types.contains { $0.preferredFilenameExtension == "fh10" || $0.identifier == "com.macromedia.freehand" })
        #expect(types.contains(.pdf))
        #expect(ImportFormat.sniff(Data("FH3 and more".utf8)) == nil || ImportFormat.sniff(Data("FH3 and more".utf8)) == .freehand)
    }
}

/// IO-041's additions to the neutral scene: named colours, live fills, arrowheads, clip
/// appearance, area and path text, symbols.
@Suite("Imported scene: live values")
struct ImportedSceneLiveTests {
    static let leaf = ImportedSwatch(name: "Leaf", color: Color(red: 0.2, green: 0.6, blue: 0.2))
    static let tile = ImportedTile(nodes: [.path(ImportedPath(contours: [ImportedContour(start: .zero, segments: [.line(to: Point(x: 4, y: 0)), .line(to: Point(x: 4, y: 4))], closed: true)],
                                                              fill: .swatch(ImportedSwatchLiveFixture.moss)))], angle: 10, scaleX: 50, scaleY: 50, offset: Point(x: 1, y: 2))

    @Test("Paints: representative colours and the swatches they use")
    func paints() {
        let lens = LensFill(type: .monochrome, color: .white)
        let pattern = PatternPaint(bitmap: .checker, color: Color(red: 1, green: 0, blue: 0))
        #expect(ImportedPaint.swatch(Self.leaf).representativeColor == Self.leaf.color)
        #expect(ImportedPaint.lens(lens).representativeColor == .white)
        #expect(ImportedPaint.pattern(pattern).representativeColor == pattern.color)
        #expect(ImportedPaint.tiled(Self.tile).representativeColor == nil)
        #expect(ImportedPaint.tiled(Self.tile).swatches == [ImportedSwatchLiveFixture.moss])
        #expect(ImportedPaint.solid(.black).swatches.isEmpty)
        #expect(ImportedPaint.swatch(Self.leaf).paint == .solid(Self.leaf.color))
        #expect(ImportedPaint.lens(lens).paint == .lens(lens))
        #expect(ImportedPaint.pattern(pattern).paint == .pattern(pattern))
        guard case .tiled(let tiled) = ImportedPaint.tiled(Self.tile).paint else {
            Issue.record("expected a tiled paint")
            return
        }
        #expect(tiled.tile.count == 1 && tiled.scaleX == 50 && tiled.offset == Point(x: 1, y: 2))
    }

    @Test("A scene lists its named colours once, from paths, strokes, text, clips, tiles and symbols")
    func sceneSwatches() {
        let box = [ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10))], closed: true)]
        let red = ImportedSwatch(name: "Red", color: Color(red: 1, green: 0, blue: 0), spot: true)
        let clip = ImportedPath(contours: box, fill: .swatch(red))
        let text = ImportedText(runs: [ImportedTextRun(text: "a", fontName: "Helvetica", fontSize: 12, fill: .swatch(Self.leaf), origin: .zero)],
                                path: ImportedPath(contours: box, stroke: ImportedStroke(paint: .swatch(red))))
        let nodes: [ImportedNode] = [
            .group(ImportedGroup(children: [.path(ImportedPath(contours: box, fill: .tiled(Self.tile)))], clip: clip, clipAppearance: true)),
            .group(ImportedGroup(children: [], clip: ImportedPath(contours: box, fill: .swatch(ImportedSwatch(name: "Hidden", color: .black))))),
            .text(text),
            .image(ImportedImage(pixels: ImportedPixels(blob: ImportedBlob(data: Data([1]), uti: "public.png"), width: 1, height: 1, mode: .rgb, bitsPerChannel: 8, hasAlpha: false))),
        ]
        let symbol = ImportedSymbol(key: "s", name: "S", nodes: [.path(ImportedPath(contours: box, fill: .swatch(Self.leaf)))])
        let scene = ImportedScene(kind: .vector, name: "x", bounds: .zero, nodes: nodes, symbols: [symbol])
        #expect(scene.swatches == [red, ImportedSwatchLiveFixture.moss, Self.leaf])
        #expect(scene.blobs.count == 1)
    }

    @Test("Control bounds of paths, groups with clips, text, images and placed files")
    func bounds() {
        let box = [ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10))], closed: true)]
        let moved = AffineTransform.translation(x: 5, y: 5)
        #expect(ImportedNode.path(ImportedPath(contours: box, transform: moved)).controlBounds() == Rect(x: 5, y: 5, width: 10, height: 10))
        let clipped = ImportedNode.group(ImportedGroup(children: [], clip: ImportedPath(contours: box), transform: moved))
        #expect(clipped.controlBounds(.scale(2)) == Rect(x: 10, y: 10, width: 20, height: 20))
        let area = ImportedNode.text(ImportedText(runs: [ImportedTextRun(text: "a", fontName: "Helvetica", fontSize: 12, origin: Point(x: 1, y: 12))],
                                                  frame: Size(width: 30, height: 20), path: ImportedPath(contours: box, transform: moved)))
        #expect(area.controlBounds() == Rect(x: 0, y: 0, width: 30, height: 20))
        let image = ImportedNode.image(ImportedImage(pixels: ImportedPixels(blob: ImportedBlob(data: Data([1]), uti: "public.png"), width: 72, height: 36, mode: .rgb,
                                                                          bitsPerChannel: 8, hasAlpha: false)))
        #expect(image.controlBounds() == Rect(x: 0, y: 0, width: 72, height: 36))
        let placed = ImportedNode.placed(ImportedPlacedFile(kind: .eps, blob: ImportedBlob(data: Data([2]), uti: "com.adobe.encapsulated-postscript"),
                                                            bounds: Rect(x: 0, y: 0, width: 4, height: 3), transform: moved))
        #expect(placed.controlBounds() == Rect(x: 5, y: 5, width: 4, height: 3))
    }

    @Test("A clip path that keeps its appearance draws its fill below the contents and its stroke above")
    func clipAppearanceRendering() throws {
        let box = [ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10)), .line(to: Point(x: 0, y: 10))], closed: true)]
        let clip = ImportedPath(contours: box, fill: .solid(.white), stroke: ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: 1)))
        let inside = ImportedNode.path(ImportedPath(contours: box.map { $0.applying(.translation(x: 5, y: 5)) }, fill: .solid(Color(red: 1, green: 0, blue: 0))))
        let scene = ImportedScene(kind: .vector, name: "clip", bounds: Rect(x: 0, y: 0, width: 20, height: 20),
                                  nodes: [.group(ImportedGroup(children: [inside], clip: clip, opacity: 0.5, clipAppearance: true))])
        guard case .group(let outer)? = scene.exportScene().pages[0].displayList.items.first else {
            Issue.record("expected a group")
            return
        }
        #expect(outer.opacity == 0.5)
        #expect(outer.children.count == 3)
        var bare = clip
        bare.stroke = nil
        let unstroked = ImportedScene(kind: .vector, name: "clip", bounds: .zero, nodes: [.group(ImportedGroup(children: [inside], clip: bare, clipAppearance: true))])
        guard case .group(let two)? = unstroked.exportScene().pages[0].displayList.items.first else {
            Issue.record("expected a group")
            return
        }
        #expect(two.children.count == 2)
    }
}

enum ImportedSwatchLiveFixture {
    static let moss = ImportedSwatch(name: "Moss", color: Color(red: 0.3, green: 0.5, blue: 0.2))
}

/// The converter's fallbacks for records that point at nothing or hold odd values.
@Suite("FreeHand import: damaged references")
struct FreeHandFallbackTests {
    typealias Fixture = FreeHandRecordsFixture

    @Test("Missing colours, lists, styles and strings fall back to defaults")
    func missingReferences() throws {
        var f = Fixture()
        let badRGB = f.id()
        f.set("rgbColors", badRGB, [1, 2])
        let noColour = f.basicFill(9999)
        let patternFill = f.id()
        f.set("patternFills", patternFill, ["color": 9999, "pattern": "ff"])
        let stops = f.id()
        f.set("multiColorLists", stops, [[1.0], [9999.0, 0.5]])
        let linear = f.id()
        f.set("linearFills", linear, ["color1": 9999, "color2": 9999, "angle": 45.0, "multiColorList": stops])
        let lens = f.id()
        f.set("lensFills", lens, ["color": 0, "value": 250.0, "mode": 2])
        let patternLine = f.id()
        f.set("patternLines", patternLine, ["color": 9999, "percent": 1, "miter": 0, "width": 0])
        let zeroDash = f.id()
        f.set("linePatterns", zeroDash, [0.0, 0.0])
        let line = f.basicLine(badRGB, pattern: zeroDash)
        let noAttr = f.id()
        f.set("graphicStyles", noAttr, ["parent": 0, "attr": 0, "elements": [:]])
        let noFilter = f.graphicStyle([f.filterHolder(filter: 0)])
        let flat = f.transform([0, 0, 0, 0, 1, 1])
        f.layer([f.rect(1, 1, 1, 1, style: f.propList(fill: noColour, stroke: line)), f.rect(1, 1, 1, 1, style: f.propList(fill: patternFill, stroke: patternLine)),
                 f.rect(1, 1, 1, 1, style: f.propList(fill: linear)), f.rect(1, 1, 1, 1, style: f.propList(fill: lens)),
                 f.rect(1, 1, 1, 1, style: 7777), f.rect(1, 1, 1, 1, style: noAttr), f.rect(1, 1, 1, 1, style: noFilter),
                 f.group([f.rect(1, 1, 1, 1, style: f.propList(fill: linear))], xform: flat)])
        let children = FreeHandImportTests.children(try f.convert())
        let first = try #require(FreeHandImportTests.path(children[0]))
        #expect(first.fill == .solid(.black))
        #expect(first.stroke?.paint == .solid(.black))
        #expect(first.stroke?.style.dash == [])
        guard case .pattern(let pattern)? = FreeHandImportTests.path(children[1])?.fill else {
            Issue.record("expected a pattern")
            return
        }
        #expect(pattern.color == .black)
        #expect(pattern.bitmap.rows == [0xff, 0, 0, 0, 0, 0, 0, 0])
        #expect(FreeHandImportTests.path(children[1])?.stroke?.paint == .solid(.black))
        guard case .gradient(let gradient)? = FreeHandImportTests.path(children[2])?.fill else {
            Issue.record("expected a gradient")
            return
        }
        #expect(gradient.stops.map(\.color) == [.white, .black])
        guard case .lens(let lighten)? = FreeHandImportTests.path(children[3])?.fill else {
            Issue.record("expected a lens")
            return
        }
        #expect(lighten.amount == 100 && lighten.color == .black)
        #expect(FreeHandImportTests.path(children[4])?.fill == ImportedPaint.none)
        #expect(FreeHandImportTests.path(children[5])?.fill == ImportedPaint.none)
        #expect(FreeHandImportTests.path(children[6])?.opacity == 1)
        // A transform that flattens everything still gives a gradient axis.
        if case .gradient(let flattened)? = FreeHandImportTests.path(FreeHandImportTests.group(children[7])?.children.first)?.fill {
            #expect(flattened.axis != nil)
        }
    }

    @Test("Structure: layer lists naming non-layers, lists that are missing, unnamed symbols")
    func missingStructure() throws {
        var f = Fixture()
        let clip = f.id()
        f.set("clipGroups", clip, ["style": 0, "elements": 0, "xform": 0])
        let composite = f.id()
        f.set("compositePaths", composite, ["style": 0, "elements": 0])
        let orphanPathText = f.id()
        f.set("pathTexts", orphanPathText, ["elements": 0, "layer": 0, "displayText": 9999, "shape": 0, "textSize": 0])
        let symbol = f.id()
        f.set("symbolClasses", symbol, ["name": f.string(""), "group": f.rect(0, 0, 1, 1), "dateTime": 0, "library": 0, "list": 0])
        let instance = f.id()
        f.set("symbolInstances", instance, ["style": 0, "parent": 0, "symbolClass": symbol, "xform": [1.0, 0, 0, 1, 0, 0]])
        f.layer([clip, composite, orphanPathText, instance, 8888])
        var records = try f.records()
        let conversion = try f.convert()
        #expect(conversion.symbols.map(\.name) == ["Symbol 1"])
        #expect(FreeHandImportTests.children(conversion).count == 1)
        // A layer list entry that is not a layer is skipped.
        var g = Fixture()
        g.layer([g.rect(1, 1, 1, 1)])
        g.set("lists", 5000, ["type": 0, "elements": [4242, 5]])
        g.top["layerList"] = 5000
        records = try g.records()
        var converter = FreeHandConverter(records: records, name: "g")
        #expect(converter.convert().layers.count == 1)
    }

    @Test("Text: missing strings, blocks and properties; control-only runs; several runs")
    func textFallbacks() throws {
        var f = Fixture()
        let props = f.charProperties(size: 0)
        let blok = f.id()
        f.set("textBloks", blok, Array("AB\u{1F}CD".utf16).map(Int.init))
        let twoRuns = f.id()
        f.set("paragraphs", twoRuns, ["paraStyle": 9999, "textBlok": blok, "charStyles": [[0, props], [2, 7777], [3, props], [9, props], [1]]])
        let controls = f.id()
        f.set("textBloks", controls, [0x1F, 0x0B])
        let controlParagraph = f.id()
        f.set("paragraphs", controlParagraph, ["paraStyle": 0, "textBlok": controls, "charStyles": [[0, props]]])
        let noBlok = f.id()
        f.set("paragraphs", noBlok, ["paraStyle": 0, "textBlok": 9999, "charStyles": [[0, props]]])
        let emptyFirst = f.paragraph("", properties: props)
        f.layer([f.textObject([emptyFirst, twoRuns, controlParagraph, noBlok]), f.textObject([], x: 0, y: 0)])
        let tStringless = f.id()
        f.set("textObjects", tStringless, ["style": 0, "xform": 0, "tString": 0, "vmpObj": 0, "path": 0, "startX": 0.0, "startY": 0.0, "width": 0.0, "height": 0.0,
                                           "beginPos": 0, "endPos": 0, "colNum": 0, "rowNum": 0, "colSep": 0.0, "rowSep": 0.0, "rowBreakFirst": 0])
        f.layer([tStringless])
        let conversion = try f.convert()
        let text = try #require(FreeHandImportTests.text(FreeHandImportTests.children(conversion).first))
        #expect(text.runs.map(\.text) == ["", "AB", "CD", "", ""])
        #expect(text.runs[1].fontSize == 12)
        #expect(text.runs[2].family == "Helvetica")
        #expect(conversion.layers.count == 1)
        #expect(FreeHandConverter.postScriptName(family: "No Such Family 7", style: "") == "No Such Family 7")
        #expect(FreeHandConverter.postScriptName(family: "Helvetica", style: "Bold") == "Helvetica-Bold")
        #expect(FreeHandConverter.alignment(9) == .left)
    }

    @Test("Display text without properties or width")
    func displayFallbacks() throws {
        var f = Fixture()
        let text = f.id()
        f.set("displayTexts", text, ["style": 0, "xform": 0, "startX": 1.0, "startY": 9.0, "width": 0.0, "height": 0.0, "justify": 0, "charProps": [],
                                     "paraOffsets": [], "characters": "4869"])
        f.layer([text])
        let result = try #require(FreeHandImportTests.text(FreeHandImportTests.children(try f.convert()).first))
        #expect(result.runs.map(\.text) == ["Hi"])
        #expect(result.runs[0].family == "Helvetica" && result.runs[0].style == "" && result.runs[0].fontSize == 12)
        #expect(result.frame == nil)
        #expect(FreeHandConverter.displayAlignment(0) == .left)
    }

    @Test("Notices: shadows alone, glows alone, one of each")
    func effectNotes() {
        var notes = FreeHandNotes()
        notes.shadows = 1
        #expect(notes.messages == ["1 shadow was left out."])
        notes = FreeHandNotes()
        notes.glows = 3
        #expect(notes.messages == ["3 glows were left out."])
        notes = FreeHandNotes()
        notes.blends = 2
        notes.unreadableImages = 1
        notes.patternStrokes = 2
        notes.textColumns = 2
        notes.customFills = 1
        #expect(notes.messages.count == 5)
    }
}
