import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import struct WTGeometry.AffineTransform
import struct WTRender.StrokeStyle

/// IO-041: the live parts of an imported scene (FreeHand's) -- named colours as swatches,
/// symbols and instances, tiled, lens and pattern fills, pattern strokes, arrowheads, clip paths
/// that keep their appearance, area text, text on a path and alignment.
@Suite struct ImportLiveMappingTests {
    static let box = [ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10)), .line(to: Point(x: 0, y: 10))], closed: true)]

    static func path(_ fill: ImportedPaint = .none, stroke: ImportedStroke? = nil, x: Double = 0) -> ImportedPath {
        ImportedPath(contours: box.map { $0.applying(.translation(x: x, y: 0)) }, fill: fill, stroke: stroke)
    }

    static func scene(_ nodes: [ImportedNode], symbols: [ImportedSymbol] = []) -> ImportedScene {
        ImportedScene(kind: .vector, name: "art.fh10", bounds: Rect(x: 0, y: 0, width: 100, height: 100), nodes: nodes, symbols: symbols)
    }

    /// The import group's children after importing `scene` into `replica`.
    static func imported(_ scene: ImportedScene, into replica: inout Replica) throws -> [OpID] {
        let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
        let change = try #require(try replica.perform(PlaceImportedScene(scene, placement: .at(.zero), layer: layer)))
        let group = try #require(PlaceImportedScene.placedRoot(of: change, in: replica.state))
        return replica.state.liveChildren(group)
    }

    @Test func namedColoursBecomeSwatchReferencesReusingSameNamedEqualSwatchesAndTheProtectedOnes() throws {
        var replica = try SwatchTests.document()
        try replica.perform(AddSwatch(Color(red: 0, green: 0.5, blue: 0), name: "Leaf"))
        try replica.perform(AddSwatch(Color(red: 1, green: 0, blue: 0), name: "Taken"))
        let leaf = ImportedSwatch(name: "Leaf", color: Color(red: 0, green: 0.5, blue: 0))
        let taken = ImportedSwatch(name: "Taken", color: Color(red: 0, green: 0, blue: 1))
        let fresh = ImportedSwatch(name: "PANTONE 186 CV", color: Color(cyan: 0, magenta: 1, yellow: 0.8, black: 0.05), spot: true)
        let registration = ImportedSwatch(name: "[Registration]", color: .black)
        let unnamed = ImportedSwatch(name: " ", color: Color(red: 0.25, green: 0.25, blue: 0.25))
        let text = ImportedText(runs: [ImportedTextRun(text: "Hi", fontName: "Helvetica", fontSize: 12, fill: .swatch(fresh), origin: Point(x: 0, y: 12))])
        let nodes: [ImportedNode] = [
            .path(Self.path(.swatch(leaf), stroke: ImportedStroke(paint: .swatch(registration)))),
            .path(Self.path(.swatch(taken))),
            .path(Self.path(.swatch(fresh))),
            .path(Self.path(.swatch(unnamed))),
            .text(text),
        ]
        let children = try Self.imported(Self.scene(nodes), into: &replica)
        let list = SwatchList(replica.state)
        func swatch(_ node: OpID, stroke: Bool = false) -> Swatch? {
            let appearance = replica.state.props(node).path.appearance
            let ref = stroke ? appearance.strokes.first?.settings.basic.color : appearance.fills.first?.settings.basic.color
            guard let ref, case .swatch(let node)? = ref.ref else { return nil }
            return list[OpID(node.id)]
        }
        #expect(swatch(children[0])?.name == "Leaf")
        #expect(swatch(children[0], stroke: true)?.role == .registration)
        #expect(swatch(children[1])?.name == "Taken-1")
        #expect(swatch(children[2])?.name == "PANTONE 186 CV")
        #expect(swatch(children[2])?.isSpot == true)
        #expect(swatch(children[3])?.hasDefaultName == true)
        #expect(list.swatches.filter { $0.name == "Leaf" }.count == 1)
        let values = try #require(TextNode(children[4], in: replica.state)).runs.flatMap(\.values)
        #expect(values.contains { value in
            if case .swatch? = value.fill.ref { return true }
            return false
        })
        #expect(ImportReferences.swatchName("[Registration]") == "Registration")
    }

    @Test func symbolsAreWrittenOnceWithTheirArtworkAndInstancesPlaceThem() throws {
        var replica = Replica(0xA)
        let inner = ImportedSymbol(key: "inner", name: "Dot", nodes: [.path(Self.path(.solid(.black)))])
        let outer = ImportedSymbol(key: "outer", name: "Pair", nodes: [
            .group(ImportedGroup(children: inner.nodes, transform: .translation(x: 20, y: 0), name: "Dot", role: .instance(symbol: "inner"))),
            .path(Self.path(.solid(.black), x: 40)),
        ])
        let nodes: [ImportedNode] = [
            .group(ImportedGroup(children: outer.nodes, transform: .translation(x: 100, y: 100), name: "Pair", role: .instance(symbol: "outer"))),
            .group(ImportedGroup(children: inner.nodes, transform: .translation(x: 5, y: 5), role: .instance(symbol: "inner"))),
            .group(ImportedGroup(children: inner.nodes, role: .instance(symbol: "missing"))),
        ]
        let children = try Self.imported(Self.scene(nodes, symbols: [inner, outer]), into: &replica)
        let symbols = Symbols.symbols(in: replica.state)
        #expect(symbols.map { replica.state.props($0).symbol.common.name } == ["Dot", "Pair"])
        #expect(replica.state.liveChildren(symbols[1]).count == 2)
        #expect(replica.state.nodeKind(replica.state.liveChildren(symbols[1])[0]) == .instance)
        // The symbol's origin is its artwork's centre; the instance puts that point where the
        // expanded group drew it.
        #expect(replica.state.props(symbols[0]).symbol.origin.x == 5)
        #expect(replica.state.nodeKind(children[0]) == .instance)
        #expect(Symbols.symbol(of: children[0], in: replica.state) == symbols[1])
        #expect(replica.state.props(children[0]).instance.common.name == "Pair")
        let placement = replica.state.props(children[1]).instance.common.transform
        #expect(placement.tx == 10 && placement.ty == 10)
        #expect(replica.state.nodeKind(children[2]) == .group, "an instance of an unknown symbol stays the expanded group")
    }

    @Test func tiledLensAndPatternFillsPatternStrokesAndArrowheadsAreLive() throws {
        var replica = Replica(0xA)
        let leaf = ImportedSwatch(name: "Leaf", color: Color(red: 0, green: 0.5, blue: 0))
        let tileArt: [ImportedNode] = [
            .path(Self.path(.swatch(leaf))),
            .group(ImportedGroup(children: [.path(Self.path(.solid(.black), x: 12))], clip: Self.path(.solid(.white)), clipAppearance: true)),
            .group(ImportedGroup(children: [.path(Self.path(.solid(.black), x: 24))], clip: Self.path(.solid(.white)))),
            .text(ImportedText(runs: [])),
        ]
        let tile = ImportedTile(nodes: tileArt, angle: 15, scaleX: 50, scaleY: 0, offset: Point(x: 3, y: 4))
        let emptyTile = ImportedTile(nodes: [.text(ImportedText(runs: []))])
        let lens = LensFill(type: .magnify, color: .white, amount: 30, magnification: 40, centerpoint: Point(x: 1, y: 2), objectsOnly: true)
        let pattern = PatternPaint(bitmap: .checker, color: Color(red: 1, green: 0, blue: 0))
        let head = ImportedArrowhead(contours: [ImportedContour(start: .zero, segments: [.line(to: Point(x: -3, y: 1)), .line(to: Point(x: -3, y: -1))], closed: true)],
                                     filled: true, name: "Head")
        let nodes: [ImportedNode] = [
            .path(Self.path(.tiled(tile))),
            .path(Self.path(.tiled(emptyTile))),
            .path(Self.path(.lens(lens))),
            .path(Self.path(.pattern(pattern), stroke: ImportedStroke(paint: .pattern(pattern), style: StrokeStyle(width: 3)))),
            .path(Self.path(stroke: ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: 1), startArrowhead: head, endArrowhead: head))),
        ]
        let children = try Self.imported(Self.scene(nodes), into: &replica)
        let tiled = try #require(replica.state.props(children[0]).path.appearance.fills.first).settings
        #expect(tiled.kind == .tiled)
        #expect(tiled.tiled.angle == 15 && tiled.tiled.scaleX == 50 && tiled.tiled.scaleY == 100 && tiled.tiled.offset.x == 3)
        // The path, the clip group (kept plain: a tile holds no references) and its clip path and
        // child, the geometry-only clip group's; the text has no tile drawing.
        #expect(tiled.tiled.tile.nodes.count == 7)
        #expect(replica.state.props(children[1]).path.appearance.fills.isEmpty)
        let lensFill = try #require(replica.state.props(children[2]).path.appearance.fills.first).settings
        #expect(lensFill.kind == .lens && lensFill.lens.type == .magnify && lensFill.lens.magnification == 20 && lensFill.lens.objectsOnly)
        #expect(lensFill.lens.centerpoint.y == 2)
        let patterned = replica.state.props(children[3]).path.appearance
        #expect(patterned.fills.first?.settings.kind == .pattern)
        #expect(patterned.fills.first?.settings.pattern.bitmap.rows == Data(PatternBitmap.checker.rows))
        #expect(patterned.strokes.first?.settings.kind == .pattern)
        #expect(patterned.strokes.first?.settings.pattern.width == 3)
        let basic = try #require(replica.state.props(children[4]).path.appearance.strokes.first).settings.basic
        #expect(basic.startArrowhead.name == "Head" && basic.startArrowhead.filled && basic.endArrowhead.contours.count == 1)
        for type in [LensType.transparency, .invert, .lighten, .darken, .monochrome] {
            #expect(ImportMapping.lens(LensFill(type: type)).type != .unspecified)
        }
    }

    @Test func clipPathsThatKeepTheirAppearanceKeepFillAndStroke() throws {
        var replica = Replica(0xA)
        let clip = Self.path(.solid(.white), stroke: ImportedStroke(paint: .solid(.black), style: StrokeStyle(width: 2)))
        let nodes: [ImportedNode] = [
            .group(ImportedGroup(children: [.path(Self.path(.solid(.black), x: 5))], clip: clip, clipAppearance: true)),
            .group(ImportedGroup(children: [.path(Self.path(.solid(.black), x: 5))], clip: clip)),
        ]
        let children = try Self.imported(Self.scene(nodes), into: &replica)
        let kept = replica.state.props(replica.state.liveChildren(children[0])[0]).path.appearance
        #expect(kept.fills.count == 1 && kept.strokes.count == 1)
        let stripped = replica.state.props(replica.state.liveChildren(children[1])[0]).path.appearance
        #expect(stripped.fills.isEmpty && stripped.strokes.isEmpty)
    }

    @Test func areaTextTextOnAPathFamiliesAndAlignment() throws {
        var replica = Replica(0xA)
        let runs = [
            ImportedTextRun(text: "One", fontName: "Helvetica-Bold", fontSize: 12, origin: Point(x: 0, y: 12), family: "Bring tha noize", style: "Bold"),
            ImportedTextRun(text: "Two", fontName: "Helvetica", fontSize: 12, origin: Point(x: 0, y: 26), family: "Helvetica"),
        ]
        let area = ImportedText(runs: runs, transform: .translation(x: 10, y: 20), frame: Size(width: 200, height: 80), alignment: .center)
        let onPath = ImportedText(runs: [runs[1]], transform: .translation(x: 1, y: 1), path: Self.path(.solid(.black)), alignment: .justify)
        let right = ImportedText(runs: [runs[1]], alignment: .right)
        let children = try Self.imported(Self.scene([.text(area), .text(onPath), .text(right)]), into: &replica)
        let block = replica.state.props(children[0]).text
        #expect(block.block.width == 200 && block.block.height == 80 && !block.block.autoWidth)
        #expect(block.common.transform.tx == 10 && block.common.transform.ty == 20)
        let text = try #require(TextNode(children[0], in: replica.state))
        #expect(text.string == "One\nTwo")
        #expect(text.paragraphs.allSatisfy { $0.props.alignment == Wiretuner_Doc_V1_Alignment.center })
        let values = text.runs.flatMap(\.values)
        #expect(values.contains { $0.fontFamily == "Bring tha noize" })
        #expect(values.contains { $0.fontStyle == "Bold" })
        let path = replica.state.props(children[1]).text
        #expect(path.onPath.mode == .along)
        let pathChild = try #require(replica.state.liveChildren(children[1]).first)
        #expect(replica.state.nodeKind(pathChild) == .path)
        #expect(replica.state.props(pathChild).path.appearance.fills.isEmpty)
        #expect(TextNode(children[1], in: replica.state)?.paragraphs.first?.props.alignment == .justified)
        #expect(TextNode(children[2], in: replica.state)?.paragraphs.first?.props.alignment == .right)
        #expect(ImportMapping.alignment(.left) == nil)
    }

    @Test func convertingAPlacedFileWritesTheSceneSwatchesToo() throws {
        var replica = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
        let placed = ImportFixture.placed(.eps, blob: ImportFixture.eps, name: "art.eps")
        let change = try #require(try replica.perform(PlaceImportedScene(placed, placement: .at(.zero), layer: layer)))
        let node = try #require(PlaceImportedScene.placedRoot(of: change, in: replica.state))
        let leaf = ImportedSwatch(name: "Leaf", color: Color(red: 0, green: 0.5, blue: 0))
        try replica.perform(ConvertPlacedFile(node, scene: Self.scene([.path(Self.path(.swatch(leaf)))])))
        #expect(SwatchList(replica.state).named("Leaf") != nil)
    }

    @Test func valuesAnImporterGetsWrongAreRepairedOnTheWayIn() throws {
        let tile = try #require(ImportMapping.tiled(ImportedTile(nodes: [.path(Self.path(.solid(.black)))], angle: .nan, scaleX: .nan, scaleY: -1),
                                                    references: ImportReferences()))
        #expect(tile.angle == 0 && tile.scaleX == 100 && tile.scaleY == 100 && !tile.hasOffset)
        let lens = ImportMapping.lens(LensFill(type: .magnify, amount: .nan, magnification: .nan))
        #expect(lens.amount == 50 && lens.magnification == 1)
        var replica = Replica(0xA)
        try replica.perform(ConvertToSymbol([], name: "Nothing"))
        let odd = ImportedText(runs: [ImportedTextRun(text: "x", fontName: "Helvetica", fontSize: 9, origin: .zero)], frame: Size(width: .nan, height: .infinity))
        let hollow = ImportedSymbol(key: "hollow", name: "Hollow", nodes: [.text(ImportedText(runs: []))])
        let children = try Self.imported(Self.scene([.text(odd), .group(ImportedGroup(children: hollow.nodes, role: .instance(symbol: "hollow")))], symbols: [hollow]),
                                         into: &replica)
        #expect(replica.state.props(children[0]).text.block.width == 0)
        #expect(replica.state.props(children[0]).text.block.height == 0)
        let symbol = try #require(Symbols.symbols(in: replica.state).last)
        #expect(replica.state.props(symbol).symbol.origin.x == 0)
    }
}
