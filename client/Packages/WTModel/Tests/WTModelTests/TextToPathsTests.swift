import CoreGraphics
import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle
import WTText

/// TYPE-044 Convert to Paths (text-to-paths.adoc).
@Suite @MainActor struct TextToPathsTests {
    /// The tight bounds of a display path (curves by their extremes, not their control points).
    static func tightBounds(_ path: DisplayPath) -> CGRect {
        let cg = CGMutablePath()
        for element in path.elements {
            switch element {
            case .move(let p): cg.move(to: CGPoint(x: p.x, y: p.y))
            case .line(let p): cg.addLine(to: CGPoint(x: p.x, y: p.y))
            case .quadCurve(let c, let p): cg.addQuadCurve(to: CGPoint(x: p.x, y: p.y), control: CGPoint(x: c.x, y: c.y))
            case .cubicCurve(let c1, let c2, let p):
                cg.addCurve(to: CGPoint(x: p.x, y: p.y), control1: CGPoint(x: c1.x, y: c1.y), control2: CGPoint(x: c2.x, y: c2.y))
            case .close: cg.closeSubpath()
            }
        }
        return cg.boundingBoxOfPath
    }

    /// The display path a path node draws, in its parent's space.
    static func drawn(_ node: OpID, in state: EngineState) -> DisplayPath {
        let path = VectorPath(state.props(node).path, node: node, state: state)
        return DocumentDisplayListBuilder.display(path) { _ in true }.path
    }

    static func convert(_ replica: inout Replica, _ node: OpID) throws -> OpID {
        let fonts = DocumentFontIndex(state: replica.state)
        let conversion = try TextToPaths.conversion(node, in: replica.state, engine: fonts.layoutEngine)
        let change = try #require(try replica.perform(ConvertTextToPaths([conversion])))
        #expect(change.label == "Convert text to paths")
        return try #require(replica.state.liveChildren(replica.state.store.placement(node)!.parent).first { replica.state.nodeKind($0) == .group })
    }

    @Test func glyphPathsMatchTheLiveTextAcrossFiveFonts() throws {
        var a = Replica(1)
        let fonts = ["Helvetica", "Times", "Courier", "Georgia", "Menlo"]
        let line = "The quick brown fox jumps over the lazy dog 0123456789"
        let node = try TextFixture.block(&a, fonts.map { _ in line }.joined(separator: "\n"), at: Point(x: 20, y: 30))
        for (index, family) in fonts.enumerated() {
            let start = index * (line.count + 1)
            try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, start), to: TextFixture.at(a, node, start + line.count),
                                    value: TextFixture.family(family)))
        }
        let engine = DocumentFontIndex(state: a.state).layoutEngine
        let layout = TextLayoutReading.layout(TextFixture.text(a, node), engine: engine, state: a.state)
        let live = layout.outlines(forContainer: 0)
        #expect(live.glyphs.count >= 200)
        #expect(Set(live.glyphs.map(\.fontName)).count == 5)
        let group = try Self.convert(&a, node)
        let paths = a.state.liveChildren(group)
        #expect(paths.count == live.glyphs.count)
        for (glyph, path) in zip(live.glyphs, paths) {
            let expected = Self.tightBounds(glyph.path)
            let actual = Self.tightBounds(Self.drawn(path, in: a.state))
            #expect(abs(expected.minX - actual.minX) < 0.1 && abs(expected.maxX - actual.maxX) < 0.1, "\(expected) \(actual)")
            #expect(abs(expected.minY - actual.minY) < 0.1 && abs(expected.maxY - actual.maxY) < 0.1, "\(expected) \(actual)")
        }
        // The text is deleted; the group holds its place and is named after the first words.
        #expect(!a.state.isLive(node))
        #expect(a.state.props(group).group.common.name == "The quick brown")
    }

    @Test func iAndOAreCompositePathsWithHolesWoundTheOtherWay() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "iO")
        try a.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixture.family("Helvetica")))
        let group = try Self.convert(&a, node)
        let paths = a.state.liveChildren(group)
        #expect(paths.count == 2)
        let i = VectorPath(a.state.props(paths[0]).path, node: paths[0], state: a.state)
        let o = VectorPath(a.state.props(paths[1]).path, node: paths[1], state: a.state)
        #expect(i.contours.count == 2 && o.contours.count == 2)
        func area(_ contour: VectorContour) -> Double {
            let points = contour.points.map(\.anchor)
            return zip(points, points.dropFirst() + [points[0]]).reduce(0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) } / 2
        }
        #expect(i.contours.allSatisfy { $0.closed })
        // The O's outer and inner contours wind in opposite directions: non-zero leaves the hole.
        #expect(area(o.contours[0]) * area(o.contours[1]) < 0)
        // The i's dot and stem wind the same way (two islands).
        #expect(area(i.contours[0]) * area(i.contours[1]) > 0)
        // Each glyph path carries the text's fill.
        #expect(a.state.props(paths[0]).path.appearance.fills.count == 1)
    }

    @Test func fillsStrokesEffectsAndTheBlockRectangle() throws {
        var a = Replica(1)
        let node = try #require(try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 200, height: 50)), text: "Ab cd"))).createdObjects[0]
        let red = Appearances.inline(red: 1, green: 0, blue: 0)
        try a.perform(TextColor.fill(node: node, from: .start, to: TextFixture.at(a, node, 1), red))
        try a.perform(TextColor.stroke(node: node, from: TextFixture.at(a, node, 1), to: TextFixture.at(a, node, 2)))
        try a.perform(TextColor.removeFill(node: node, from: TextFixture.at(a, node, 3), to: TextFixture.at(a, node, 4)))
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 3), to: .end, value: .with { $0.effect.underline = .with { $0.width = 1 } }))
        try a.perform(ApplyMark(node: node, from: .start, to: TextFixture.at(a, node, 1), value: .with { $0.effect.zoom = .init() }))
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 1), to: TextFixture.at(a, node, 2), value: .with { $0.effect.shadow = .init() }))
        try a.perform(AddTextBlockAppearance.fill(node))
        try a.perform(AddTextBlockAppearance.stroke(node))
        let group = try Self.convert(&a, node)
        let children = a.state.liveChildren(group)
        let props = children.map { a.state.props($0).path }
        // Bottom: the block's rectangle with the block fill and stroke; then b's shadow (a filled copy).
        #expect(VectorPath(props[0], node: children[0], state: a.state).contours.first?.points.count == 4)
        #expect(props[0].appearance.fills.count == 1 && props[0].appearance.strokes.count == 1)
        #expect(props[1].appearance.fills.count == 1 && props[1].appearance.strokes.isEmpty)
        // A: red fill; b: black fill and a stroke; c: no fill; the underline, a stroked path, at the top.
        #expect(props[2].appearance.fills.first?.settings.basic.color == red)
        #expect(props[3].appearance.strokes.count == 1 && props[3].appearance.fills.count == 1)
        #expect(props[4].appearance.fills.isEmpty)
        #expect(props.last?.appearance.strokes.first?.settings.basic.width == 1)
        // Zoom is dropped: A draws one path, no zoom copies.
        #expect(children.count == 1 + 1 + 4 + 1)
    }

    @Test func effectStrokesKeepTheirCapsAndJoinsAndMissingFontsAreNamed() throws {
        let pairs = [(LineCap.round, LineJoin.bevel), (LineCap.square, LineJoin.round), (LineCap.butt, LineJoin.miter)]
        for (cap, join) in pairs {
            let shape = TextToPaths.shape(TextShape(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)),
                                                    stroke: StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2, cap: cap, join: join, dash: [1, 1]))))
            let basic = shape.appearance.strokes[0].settings.basic
            #expect(basic.width == 2 && basic.dash.lengths == [1, 1])
            let expectedCap: Wiretuner_Doc_V1_LineCap = cap == LineCap.round ? .round : cap == LineCap.square ? .square : .butt
            let expectedJoin: Wiretuner_Doc_V1_LineJoin = join == LineJoin.round ? .round : join == LineJoin.bevel ? .bevel : .miter
            #expect(basic.cap == expectedCap && basic.join == expectedJoin)
        }
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Missing")
        try a.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixture.family("NoSuchFamilyTypm")))
        let conversion = try TextToPaths.conversion(node, in: a.state, engine: DocumentFontIndex(state: a.state).layoutEngine)
        #expect(conversion.substitutedFonts.contains("NoSuchFamilyTypm"))
    }

    @Test func inlineGraphicsMoveIntoTheGroupWhereTheyWereDrawn() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "ab", at: Point(x: 10, y: 10))
        let rect = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)))).createdObjects[0]
        try a.perform(PasteInlineGraphic(node: node, at: TextFixture.at(a, node, 1), payload: ClipboardPayload(copying: [rect], from: a.state)))
        let graphic = try #require(InlineGraphics.placements(TextFixture.text(a, node)).first?.graphic)
        let engine = DocumentFontIndex(state: a.state).layoutEngine
        let placement = try #require(TextLayoutReading.layout(TextFixture.text(a, node), engine: engine, state: a.state).inlineGraphics().first)
        let group = try Self.convert(&a, node)
        #expect(a.state.store.placement(graphic)?.parent == group)
        #expect(a.state.isLive(graphic))
        let moved = PathEditing.transform(a.state.props(graphic).rect.common.transform)
        let expected = placement.transform.concatenating(AffineTransform.translation(x: 10, y: 10))
        #expect(abs(moved.tx - expected.tx) < 0.001 && abs(moved.ty - expected.ty) < 0.001)
        // A graphic named twice moves once, from its first placeholder.
        var b = Replica(1)
        let twice = try TextFixture.block(&b, "x")
        let shape = try #require(try b.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 4, height: 4)))).createdObjects[0]
        try b.perform(PasteInlineGraphic(node: twice, at: .end, payload: ClipboardPayload(copying: [shape], from: b.state)))
        let child = try #require(InlineGraphics.placements(TextFixture.text(b, twice)).first?.graphic)
        try b.perform(TestPlaceholders(node: twice, graphics: [child]))
        let captured = try TextToPaths.conversion(twice, in: b.state, engine: DocumentFontIndex(state: b.state).layoutEngine)
        #expect(captured.graphics.count == 1)
    }

    @Test func linkedBlocksAndOtherNodesAreRefusedAndADeletedBlockIsSkipped() throws {
        var a = Replica(1)
        let first = try TextFixture.block(&a, "one")
        let second = try TextFixture.block(&a, "two")
        var link = Wiretuner_Doc_V1_NodeProps()
        link.text.nextLink.id = second.proto
        try a.perform(TestSet(node: first, path: RegisterPath([130, 4]), values: link))
        let engine = DocumentFontIndex(state: a.state).layoutEngine
        #expect(throws: TextToPathsError.linked(first)) { try TextToPaths.conversion(first, in: a.state, engine: engine) }
        #expect(throws: TextToPathsError.notText(WellKnown.layers)) { try TextToPaths.conversion(WellKnown.layers, in: a.state, engine: engine) }
        // Captured before the link was made, written after: refused too.
        let third = try TextFixture.block(&a, "three")
        let conversion = try TextToPaths.conversion(third, in: a.state, engine: engine)
        link.text.nextLink.id = second.proto
        try a.perform(TestSet(node: third, path: RegisterPath([130, 4]), values: link))
        #expect(throws: TextToPathsError.linked(third)) { try a.perform(ConvertTextToPaths([conversion])) }
        // A block someone deleted meanwhile: nothing written.
        let fourth = try TextFixture.block(&a, "four")
        let later = try TextToPaths.conversion(fourth, in: a.state, engine: engine)
        try a.perform(TestSet(node: fourth, delete: true))
        #expect(try a.perform(ConvertTextToPaths([later])) == nil)
        #expect(TextToPaths.name("\u{FFFC} a  b\tc d") == "a b c")
        #expect(later.substitutedFonts.isEmpty)
    }

    @Test func textOnAPathDeletesThePathItFollowed() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "on path")
        let path = try #require(try a.perform(PathFixture.open([(0, 0), (100, 0)]))).createdObjects[0]
        try a.perform(TestMove(node: path, parent: node))
        var onPath = Wiretuner_Doc_V1_NodeProps()
        onPath.text.onPath.mode = .along
        try a.perform(TestSet(node: node, path: RegisterPath([130, 6, 1]), values: onPath))
        _ = try Self.convert(&a, node)
        #expect(!a.state.isLive(node) && !a.state.isLive(path))
    }

    @Test func undoAfterEditingAConvertedPathRestoresTheText() throws {
        var a = Replica(1)
        let node = try TextFixture.block(&a, "Hi")
        let group = try Self.convert(&a, node)
        let glyph = try #require(a.state.liveChildren(group).first)
        try a.perform(SetTransforms([(glyph, .translation(x: 5, y: 0))]))
        a.undo()
        a.undo()
        #expect(a.state.isLive(node))
        #expect(!a.state.isLive(group))
        #expect(TextFixture.text(a, node).string == "Hi")
    }

    // MARK: Merge

    @Test func convertVersusConcurrentTypingThenRestore() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "abc")
        pair.sync()
        let group = try Self.convert(&pair.a, node)
        try pair.b.perform(InsertText(node: node, text: "XYZ", at: .end))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.b.state.isLive(node))
        // The paths are the text as the converter saw it.
        #expect(pair.b.state.liveChildren(group).count == 3)
        try pair.b.perform(TestUndelete(node: node))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(node) && replica.state.isLive(group))
            #expect(TextFixture.text(replica, node).string == "abcXYZ")
        }
    }
}

/// `deleted = false` on a node: the *Restore* notice's write.
struct TestUndelete: Command {
    var node: OpID
    var label: String { "Restore" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.setDeleted(node, false))
    }
}

/// A raw `MoveNode`.
struct TestMove: Command {
    var node: OpID
    var parent: OpID
    var label: String { "Move" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.move(node, parent: parent, position: [0x80]))
    }
}
