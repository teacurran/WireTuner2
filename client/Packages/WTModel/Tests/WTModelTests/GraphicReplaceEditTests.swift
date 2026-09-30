import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The Find & Replace tab's edits beyond one register per row (OBJ-023): *Include tints* and
/// gradient stops in *Color*, *Remove > Overprinting* and *Contents*, and *Path shape*.
@Suite struct GraphicReplaceEditTests {
    static func swatch(_ color: Color, _ name: String, on a: inout Replica) throws -> OpID {
        try a.perform(AddSwatch(color, name: name))!.createdNodes[0]
    }

    static func fill(_ node: OpID, _ color: Wiretuner_Doc_V1_ColorRef, on a: inout Replica) throws {
        try a.perform(AddAppearance.fill([node], .with { $0.settings.kind = .basic; $0.settings.basic.color = color }))
    }

    static func topFill(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_ColorRef? {
        AppearanceEditing.entries(node, in: state).last { $0.kind == .fill(.basic) }.flatMap(AttributeFields.color)
    }

    @Test func colorsIncludeTintsAndGradientStops() throws {
        var a = Replica(0xA)
        let art = try LayerFixture.layers(["Art"], on: &a)[0]
        let grape = try Self.swatch(Color(red: 0.5, green: 0, blue: 0.5), "Grape", on: &a)
        let lime = try Self.swatch(Color(red: 0.5, green: 1, blue: 0), "Lime", on: &a)
        let resolver = SwatchList(a.state).resolver
        let namedGrape = try a.perform(AddTintSwatch(of: grape, percent: 40))!.createdNodes[0]
        let namedLime = try a.perform(AddTintSwatch(of: lime, percent: 40))!.createdNodes[0]
        let namedGrape60 = try a.perform(AddTintSwatch(of: grape, percent: 60))!.createdNodes[0]
        let solid = try LayerFixture.object(LayerFixture.rect(on: art, x: 0), on: &a)
        let unnamed = try LayerFixture.object(LayerFixture.rect(on: art, x: 50), on: &a)
        let named = try LayerFixture.object(LayerFixture.rect(on: art, x: 100), on: &a)
        let named60 = try LayerFixture.object(LayerFixture.rect(on: art, x: 150), on: &a)
        let other = try LayerFixture.object(LayerFixture.rect(on: art, x: 200), on: &a)
        let gradient = try LayerFixture.object(LayerFixture.rect(on: art, x: 250), on: &a)
        try Self.fill(solid, resolver.reference(to: grape), on: &a)
        try Self.fill(unnamed, resolver.tint(of: grape, percent: 25), on: &a)
        try Self.fill(named, resolver.reference(to: namedGrape), on: &a)
        try Self.fill(named60, resolver.reference(to: namedGrape60), on: &a)
        try Self.fill(other, resolver.tint(of: lime, percent: 25), on: &a)
        try Self.fill(gradient, AttributeQueryTests.red, on: &a)
        let row = try #require(AppearanceEditing.stack(gradient, in: a.state).last { $0.list == .fills })
        try a.perform(ChooseGradient([(gradient, row)]))
        let stops = GradientReading.ramp(AppearanceEditing.entries(gradient, in: a.state).first { $0.kind == .fill(.gradient) }!.fill.settings.gradient)
        try a.perform(RecolorGradientStop(node: gradient, row: row, stop: stops[1].id, color: resolver.reference(to: grape)))
        let text = try TextFixture.block(&a, "grape words")
        try a.perform(TextColor.fill(node: text, from: .start, to: .end, resolver.tint(of: grape, percent: 10)))
        let candidates = AttributeQuery.candidates(.document, in: a.state)

        // Without *Include tints* only the swatch itself: the solid fill and the stop.
        let plain = GraphicEdit.color(from: resolver.reference(to: grape), to: resolver.reference(to: lime))
        #expect(Set(ReplaceGraphics.matches(plain, in: candidates, state: a.state)) == [solid, gradient])
        // With it, every tint of Grape becomes that tint of Lime; Lime's own tints are left alone.
        let tints = GraphicEdit.color(from: resolver.reference(to: grape), to: resolver.reference(to: lime), tints: true)
        let parts = ReplaceGraphics.chunks(tints, candidates: candidates, in: a.state)
        #expect(parts.count == 1 && parts[0].label == "Replace color in 6 objects")
        try a.perform(parts[0])
        let lists = SwatchList(a.state)
        #expect(Self.topFill(solid, in: a.state) == lists.resolver.reference(to: lime))
        #expect(Self.topFill(unnamed, in: a.state).map { ColorMatching.same($0, lists.resolver.tint(of: lime, percent: 25)) } == true)
        #expect(Self.topFill(named, in: a.state) == lists.resolver.reference(to: namedLime), "the named 40% tint of Lime")
        #expect(Self.topFill(named60, in: a.state).map { ColorMatching.same($0, lists.resolver.tint(of: lime, percent: 60)) } == true,
                "no named 60% Lime: an unnamed tint")
        #expect(Self.topFill(other, in: a.state).map { ColorMatching.same($0, lists.resolver.tint(of: lime, percent: 25)) } == true)
        let ramp = GradientReading.ramp(AppearanceEditing.entries(gradient, in: a.state).first { $0.kind == .fill(.gradient) }!.fill.settings.gradient)
        #expect(ColorMatching.same(ramp[1].color, lists.resolver.reference(to: lime)))
        #expect(AttributeQuery(.color(lists.resolver.tint(of: lime, percent: 10)), in: .document).run(in: a.state) == [text])
        // An inline To takes the colour but not the tints.
        let inline = ColorReplacement(from: lists.resolver.reference(to: lime), to: AttributeQueryTests.blue, tints: true, state: a.state)
        #expect(inline.replacement(for: lists.resolver.tint(of: lime, percent: 25)) == nil)
        #expect(inline.replacement(for: lists.resolver.reference(to: lime)) == AttributeQueryTests.blue)
        let unrelated = ColorReplacement(from: lists.resolver.reference(to: lime), to: lists.resolver.reference(to: grape), tints: true, state: a.state)
        #expect(unrelated.replacement(for: lists.resolver.reference(to: namedGrape60)) == nil, "a tint of another base")
        #expect(unrelated.replacement(for: AttributeQueryTests.red) == nil)
        // A fill and a stroke of the same colour become one write over both rows.
        let both = try LayerFixture.object(LayerFixture.rect(on: art, x: 400), on: &a)
        try Self.fill(both, AttributeQueryTests.red, on: &a)
        let strokeRow = try #require(AppearanceEditing.stack(both, in: a.state).first { $0.list == .strokes })
        try a.perform(SetAppearanceColor([(both, strokeRow)], color: AttributeQueryTests.red))
        let red = ColorReplacement(from: AttributeQueryTests.red, to: AttributeQueryTests.blue, tints: false, state: a.state)
        let writes = red.commands(both, entries: AppearanceEditing.entries(both, in: a.state), state: a.state)
        #expect(writes.count == 1 && (writes[0] as? SetAppearanceColor)?.rows.count == 2)
    }

    @Test func removeOverprintingAndContents() throws {
        var a = Replica(0xA)
        let art = try LayerFixture.layers(["Art"], on: &a)[0]
        let shape = try LayerFixture.object(LayerFixture.rect(on: art, x: 0), on: &a)
        try Self.fill(shape, AttributeQueryTests.red, on: &a)
        let fill = try #require(AppearanceEditing.stack(shape, in: a.state).last { $0.list == .fills })
        let stroke = try #require(AppearanceEditing.stack(shape, in: a.state).first { $0.list == .strokes })
        try a.perform(EditAttribute.fill([(shape, fill)], "Overprint", [AttributeFields.Basic.fillOverprint]) { $0.basic.overprint = true })
        try a.perform(EditAttribute.stroke([(shape, stroke)], "Overprint", [AttributeFields.Basic.overprint]) { $0.basic.overprint = true })
        let text = try TextFixture.block(&a, "overprinted")
        try a.perform(ApplyMark(node: text, from: .start, to: TextFixture.at(a, text, 4), value: .with { $0.overprint = true }))
        let plain = try LayerFixture.object(LayerFixture.rect(on: art, x: 100), on: &a)
        var candidates = AttributeQuery.candidates(.document, in: a.state)
        #expect(Set(AttributeQuery(.overprint, in: .document).run(in: a.state)) == [shape, text])
        let edit = GraphicEdit.remove(.overprinting)
        #expect(edit.noun == "overprinting" && GraphicEdit.remove(.contents).noun == "contents")
        try a.perform(ReplaceGraphics(edit, candidates: ReplaceGraphics.matches(edit, in: candidates, state: a.state)))
        #expect(AttributeQuery(.overprint, in: .document).run(in: a.state).isEmpty)
        #expect(ReplaceGraphics.matches(edit, in: candidates, state: a.state).isEmpty)

        // Contents: a clip group keeps its clip path and loses what was inside.
        let clip = try LayerFixture.object(PathFixture.closed([(300, 0), (400, 0), (400, 100), (300, 100)]), on: &a)
        let inside = try LayerFixture.object(LayerFixture.rect(on: art, x: 320), on: &a)
        let group = try a.perform(PasteContents(try ClippingTests.cut([inside], on: &a), into: clip))!.createdObjects[0]
        candidates = AttributeQuery.candidates(.document, in: a.state)
        let contents = GraphicEdit.remove(.contents)
        #expect(ReplaceGraphics.matches(contents, in: candidates, state: a.state) == [group])
        try a.perform(ReplaceGraphics(contents, candidates: [group, plain]))
        #expect(ClipGroups.contents(of: group, in: a.state).isEmpty && ClipGroups.clipPath(of: group, in: a.state) == clip)
        #expect(ReplaceGraphics.matches(contents, in: AttributeQuery.candidates(.document, in: a.state), state: a.state).isEmpty)
    }

    @Test func pathShapeReplacesEachMatchInPlace() throws {
        var a = Replica(0xA)
        let art = try LayerFixture.layers(["Art"], on: &a)[0]
        let sample = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (10, 20)]), on: &a)
        let copy = try a.perform(DuplicateObjects.clone([sample]))!.createdRoots[0]
        try a.perform(TransformObjects([copy], matrix: .rotation(radians: 0.5).concatenating(.scale(2)).concatenating(.translation(x: 200, y: 0)),
                                       about: Point(x: 0, y: 0), kind: .rotate))
        let different = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (20, 20)]), on: &a)
        // The replacement: a red square 10 × 10 at (0, 0).
        let square = try LayerFixture.object(LayerFixture.rect(on: art, x: 500), on: &a)
        try Self.fill(square, AttributeQueryTests.red, on: &a)
        let replacement = ClipboardPayload(copying: [square], from: a.state)
        let shape = try #require(PathShape(ClipboardPayload(copying: [sample], from: a.state)))
        let before = a.state.liveChildren(art)
        let candidates = [sample, copy, different]

        // Placed by the similarity: the square lands on the rotated, doubled copy as it sat by the sample.
        let edit = GraphicEdit.pathShape(from: shape, to: replacement, fit: false)
        #expect(edit.noun == "path shape")
        #expect(ReplaceGraphics.matches(edit, in: candidates, state: a.state) == [sample, copy])
        let expected = try #require(shape.similarity(to: PathShape(copy, in: a.state)!))
        let squareBounds = try #require(Objects.bounds(of: square, in: a.state))
        let change = try #require(try a.perform(ReplaceGraphics(edit, candidates: ReplaceGraphics.matches(edit, in: candidates, state: a.state))))
        #expect(change.label == "Replace path shape in 2 objects")
        #expect(!a.state.isLive(sample) && !a.state.isLive(copy) && a.state.isLive(different))
        let added = a.state.liveChildren(art).filter { !before.contains($0) }
        #expect(added.count == 2)
        let onCopy = try #require(added.first { Objects.bounds(of: $0, in: a.state)!.center.distance(to: expected.apply(squareBounds.center)) < 1e-6 })
        #expect(Self.topFill(onCopy, in: a.state) == AttributeQueryTests.red)
        // Each copy sits where its match was in the stacking order: below `different`.
        let order = a.state.liveChildren(art)
        #expect(order.firstIndex(of: onCopy)! < order.firstIndex(of: different)!)

        // *Transform to fit original*: the replacement fills each match's bounds.
        let target = try LayerFixture.object(PathFixture.closed([(0, 300), (60, 300), (20, 340)]), on: &a)
        let fitted = GraphicEdit.pathShape(from: shape, to: replacement, fit: true)
        let targetBounds = try #require(Objects.bounds(of: target, in: a.state))
        let prior = a.state.liveChildren(art)
        try a.perform(ReplaceGraphics(fitted, candidates: [target]))
        let placed = try #require(a.state.liveChildren(art).first { !prior.contains($0) })
        let placedBounds = try #require(Objects.bounds(of: placed, in: a.state))
        #expect(abs(placedBounds.width - targetBounds.width) < 1e-6 && abs(placedBounds.height - targetBounds.height) < 1e-6)
        #expect(placedBounds.center.distance(to: targetBounds.center) < 1e-6)

        // A payload of several objects replaces with its first; an empty one or a group matches nothing.
        let two = try #require(PathShapeReplacement.first(of: ClipboardPayload(copying: [square, different], from: a.state)))
        #expect(two.nodes.count == 1 && two.bounds != nil)
        let pathFirst = try #require(PathShapeReplacement.first(of: ClipboardPayload(copying: [different, square], from: a.state)))
        #expect(pathFirst.bounds == PathShape.bounds(of: pathFirst.nodes[0]))
        // *Transform to fit original* without the replacement's bounds falls back to the similarity.
        var unbounded = replacement
        unbounded.bounds = nil
        let other = try LayerFixture.object(PathFixture.closed([(0, 500), (30, 500), (10, 520)]), on: &a)
        #expect(PathShapeReplacement(sample: shape, replacement: unbounded, fit: true).placement(on: other, state: a.state) == shape.similarity(to: PathShape(other, in: a.state)!))
        #expect(PathShapeReplacement.first(of: ClipboardPayload(nodes: [])) == nil)
        #expect(PathShapeReplacement(sample: shape, replacement: ClipboardPayload(nodes: []), fit: false).commands(different, state: a.state).isEmpty)
        #expect(PathShape.bounds(of: NodeTree(art, state: a.state)) == nil)
    }

    @Test func pathShapeResolvesAnotherDocumentsColorsOnce() throws {
        var source = Replica(0xB)
        let sourceArt = try LayerFixture.layers(["Art"], on: &source)[0]
        let plum = try Self.swatch(Color(red: 0.4, green: 0, blue: 0.3), "Plum", on: &source)
        let square = try LayerFixture.object(LayerFixture.rect(on: sourceArt, x: 0), on: &source)
        try Self.fill(square, SwatchList(source.state).resolver.reference(to: plum), on: &source)
        let replacement = ClipboardPayload(copying: [square], from: source.state, document: "other")
        #expect(!replacement.colors.isEmpty)

        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let one = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (10, 20)]), on: &a)
        let two = try a.perform(DuplicateObjects(([one]), offset: .translation(x: 100, y: 0), label: "Duplicate"))!.createdRoots[0]
        let shape = try #require(PathShape(one, in: a.state))
        try a.perform(ReplaceGraphics(.pathShape(from: shape, to: replacement, fit: false), candidates: [one, two]))
        let plums = SwatchList(a.state).swatches.filter { $0.plainName == "Plum" }
        #expect(plums.count == 1, "one swatch for both copies")
    }
}
