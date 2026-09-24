import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The Find & Replace Graphics query (OBJ-022, find-replace.adoc "Select tab").
@Suite struct AttributeQueryTests {
    static let red = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
    static let blue = ColorResolver.inline(Color(red: 0, green: 0, blue: 1))

    /// The fixture document: one Letter page, and on the layer "Art" --
    /// `logo`: a rectangle named "Logo mark" with a red fill (on the page);
    /// `ring`: an ellipse with a 2 pt blue stroke, far off the page;
    /// `star`: a polygon; `composite`: a path of two contours;
    /// `group` holding `member`, a triangle; and objects on a hidden and on a locked layer that are
    /// never found.
    struct Fixture {
        var a = Replica(0xA)
        var page: OpID
        var art: OpID
        var logo: OpID, ring: OpID, star: OpID, composite: OpID, group: OpID, member: OpID
        var hidden: OpID, locked: OpID

        init() throws {
            page = try PageFixture.onePage(&a)
            let layers = try LayerFixture.layers(["Hidden", "Locked", "Art"], on: &a)
            art = layers[2]
            hidden = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
            locked = try LayerFixture.object(LayerFixture.rect(on: layers[1]), on: &a)
            try a.perform(SetLayerFlag([layers[0]], .visible, false))
            try a.perform(SetLayerFlag([layers[1]], .locked, true))
            logo = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 40, height: 20),
                                                       transform: .translation(x: 100, y: 100), layer: art), on: &a)
            try a.perform(SetNameOrNote([logo], .name, "Logo mark"))
            try a.perform(AddAppearance.fill([logo], .with { $0.settings.kind = .basic; $0.settings.basic.color = AttributeQueryTests.red }))
            ring = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 30, height: 30), transform: .translation(x: 2000, y: 0),
                                                       layer: art), on: &a)
            let stroke = AppearanceEditing.stack(ring, in: a.state).first { $0.list == .strokes }!
            try a.perform(SetAppearanceColor([(ring, stroke)], color: AttributeQueryTests.blue))
            try a.perform(SetStrokeWidth([(ring, stroke.element)], width: 2))
            star = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 10, autoInner: true), center: Point(x: 300, y: 300),
                                                         layer: art), on: &a)
            let left = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
            let right = try LayerFixture.object(PathFixture.closed([(20, 0), (30, 0), (30, 10)]), on: &a)
            composite = try a.perform(JoinObjects([left, right]))!.createdRoots[0]
            member = try LayerFixture.object(PathFixture.closed([(400, 400), (420, 400), (410, 420)]), on: &a)
            group = try a.perform(GroupObjects([member]))!.createdObjects[0]
        }

        func find(_ criterion: AttributeQuery.Criterion, in scope: AttributeQuery.Scope = .document) -> Set<OpID> {
            Set(AttributeQuery(criterion, in: scope).run(in: a.state))
        }
    }

    @Test func colorFindsFillsStrokesAndGradientStops() throws {
        var f = try Fixture()
        #expect(f.find(.color(Self.red)) == [f.logo])
        #expect(f.find(.color(Self.blue)) == [f.ring])
        let fill = try Self.fill(of: f.star, on: &f.a)
        try f.a.perform(ChooseGradient([(f.star, fill)]))
        let stops = f.a.state.props(f.star).polygon.appearance.fills[0].settings.gradient.stops
        try f.a.perform(RecolorGradientStop(node: f.star, row: fill, stop: OpID(element: stops[0].id)!, color: Self.red))
        #expect(f.find(.color(Self.red)) == [f.logo, f.star])
        // A swatch reference matches by swatch, a tint by base and strength, none by none.
        let swatch = Wiretuner_Doc_V1_ColorRef.with { $0.swatch.id = OpID(counter: 5, replica: 1).proto }
        let otherSwatch = Wiretuner_Doc_V1_ColorRef.with { $0.swatch.id = OpID(counter: 6, replica: 1).proto }
        let tint = Wiretuner_Doc_V1_ColorRef.with { $0.tint.base.id = OpID(counter: 5, replica: 1).proto; $0.tint.percent = 40 }
        #expect(ColorMatching.same(swatch, swatch) && !ColorMatching.same(swatch, otherSwatch))
        #expect(ColorMatching.same(tint, tint) && !ColorMatching.same(tint, swatch))
        #expect(ColorMatching.same(.with { $0.none = true }, Wiretuner_Doc_V1_ColorRef()))
        #expect(ColorMatching.same(Wiretuner_Doc_V1_ColorRef(), .with { $0.none = true }))
        #expect(ColorMatching.same(Wiretuner_Doc_V1_ColorRef(), Wiretuner_Doc_V1_ColorRef()))
        #expect(!ColorMatching.same(Self.red, Self.blue))
    }

    @Test func lockedAndHiddenLayersAreNeverSearched() throws {
        let f = try Fixture()
        let all = f.find(.objectType(.rectangle))
        #expect(all == [f.logo])
        #expect(!all.contains(f.hidden) && !all.contains(f.locked))
        #expect(f.find(.objectType(.rectangle), in: .selection([f.hidden, f.locked])).isEmpty)
    }

    @Test func objectTypesNameEachKind() throws {
        var f = try Fixture()
        #expect(f.find(.objectType(.ellipse)) == [f.ring])
        #expect(f.find(.objectType(.polygon)) == [f.star])
        #expect(f.find(.objectType(.compositePath)) == [f.composite])
        #expect(f.find(.objectType(.path)) == [f.member])
        #expect(f.find(.objectType(.group)) == [f.group])
        let text = try LayerFixture.object(CreateTextBlock(.area(Rect(x: 10, y: 10, width: 100, height: 20)), text: "Hi", layer: f.art), on: &f.a)
        #expect(f.find(.objectType(.textBlock)) == [text])
        let clip = try f.a.perform(PasteContents(ClipboardPayload(copying: [f.logo], from: f.a.state), into: f.star))!.createdObjects[0]
        #expect(f.find(.objectType(.clippingPath)) == [clip])
        let raw: [(UInt32, AttributeQuery.ObjectType?)] = [(100, .blend), (170, .bitmap), (171, .embeddedFile), (102, .envelope), (101, .extrusion),
                                                             (25, .connectorLine), (153, .symbolInstance), (24, nil)]
        for (kind, type) in raw {
            var props = Wiretuner_Doc_V1_NodeProps()
            switch kind {
            case 100: props.blend = .init()
            case 170: props.image = .init()
            case 171: props.placedFile = .init()
            case 102: props.envelope = .init()
            case 101: props.extrude = .init()
            case 25: props.connector = .init()
            case 153: props.instance = .init()
            default: props.chart = .init()
            }
            let node = try f.a.perform(OpsCommand("raw", ops: [Ops.create(parent: f.art, position: [0xF0], props: props)]))!.createdNodes[0]
            #expect(AttributeMatcher.type(of: node, in: f.a.state) == type)
            if let type, kind == 170 || kind == 102 { #expect(f.find(.objectType(type)).contains(node)) }
        }
        #expect(AttributeQuery.ObjectType.allCases.count == 15)
    }

    @Test func scopesNarrowTheSearch() throws {
        let f = try Fixture()
        // Selection: the selected objects and everything inside them.
        #expect(f.find(.objectType(.path), in: .selection([f.group])) == [f.member])
        #expect(AttributeQuery(.objectType(.path), in: .selection([f.group, f.member])).run(in: f.a.state) == [f.member])
        #expect(f.find(.objectType(.ellipse), in: .selection([f.logo])).isEmpty)
        // Page: bounds intersection with the page rectangle; the ring is far off it.
        #expect(f.find(.objectType(.ellipse), in: .page(f.page)).isEmpty)
        #expect(f.find(.objectType(.rectangle), in: .page(f.page)) == [f.logo])
        #expect(f.find(.objectType(.rectangle), in: .page(OpID(counter: 999, replica: 9))).isEmpty)
        // A caller's bounds (the scene's) replace the geometry bounds.
        let everywhere = AttributeQuery(.objectType(.ellipse), in: .page(f.page)).run(in: f.a.state) { _ in Rect(x: 0, y: 0, width: 1, height: 1) }
        #expect(everywhere == [f.ring])
        // Find with Add to selection keeps what was selected.
        #expect(AttributeQuery(.objectType(.ellipse)).select(in: f.a.state, adding: [f.logo, f.ring]) == [f.logo, f.ring])
        #expect(AttributeQuery(.objectType(.ellipse)).select(in: f.a.state, adding: [f.logo]) == [f.logo, f.ring])
        #expect(AttributeQuery(.objectType(.ellipse)).select(in: f.a.state) == [f.ring])
    }

    @Test func sizeStrokeAndFillSettings() throws {
        var f = try Fixture()
        #expect(f.find(.size(width: ValueRange(min: 39, max: 41), height: ValueRange(min: 19, max: 21))) == [f.logo])
        #expect(f.find(.size(width: .exactly(30), height: .exactly(30))) == [f.ring])
        #expect(f.find(.strokeWidth(ValueRange(min: 1.5, max: 3))) == [f.ring])
        #expect(f.find(.strokeWidth(.exactly(2))) == [f.ring])
        #expect(f.find(.fillType(.basic)).contains(f.logo))
        #expect(f.find(.fillType(.gradient)).isEmpty)
        let stroke = AppearanceEditing.stack(f.ring, in: f.a.state).first { $0.list == .strokes }!
        try f.a.perform(SetAttributeKind([(f.ring, stroke)], stroke: .calligraphic))
        #expect(f.find(.strokeType(.calligraphic)) == [f.ring])
        #expect(!f.find(.strokeType(.basic)).contains(f.ring))
        #expect(ValueRange(min: 1).contains(5) && !ValueRange(max: 1).contains(5) && ValueRange().contains(-3))
        // Overprint on a stroke and on a fill; a custom halftone.
        try f.a.perform(EditAttribute.stroke([(f.logo, AppearanceEditing.stack(f.logo, in: f.a.state).first { $0.list == .strokes }!)], "Overprint",
                                             [AttributeFields.Basic.overprint]) { $0.basic.overprint = true })
        try f.a.perform(EditAttribute.fill([(f.star, try Self.fill(of: f.star, on: &f.a))], "Overprint", [AttributeFields.Basic.fillOverprint]) {
            $0.basic.overprint = true
        })
        #expect(f.find(.overprint) == [f.logo, f.star])
        var halftone = Wiretuner_Doc_V1_NodeProps()
        halftone.path.common.halftone.frequency = 85
        try f.a.perform(OpsCommand("halftone", ops: [Ops.set(f.member, [RegisterPath([20, 1, 11])], values: halftone)]))
        #expect(f.find(.halftone) == [f.member])
    }

    static func fill(of node: OpID, on a: inout Replica) throws -> AppearanceRow {
        if let row = AppearanceEditing.stack(node, in: a.state).first(where: { $0.list == .fills }) { return row }
        try a.perform(AddAppearance.fill([node]))
        return AppearanceEditing.stack(node, in: a.state).first { $0.list == .fills }!
    }

    @Test func namesStylesAndSameAsSelection() throws {
        var f = try Fixture()
        #expect(f.find(.name("logo")) == [f.logo])
        #expect(f.find(.name("MARK")) == [f.logo])
        #expect(f.find(.name("")).isEmpty)
        #expect(f.find(.name("nothing")).isEmpty)
        // Same as selection: equal fills and strokes, the reference itself left out.
        let twin = try LayerFixture.object(LayerFixture.rect(on: f.art, x: 500), on: &f.a)
        try f.a.perform(PasteAttributes(AttributePayload(copying: f.logo, from: f.a.state)!, to: [twin]))
        #expect(f.find(.sameAs(f.logo)) == [twin])
        #expect(f.find(.sameAs(OpID(counter: 999, replica: 9))).isEmpty)
        // A graphic style.
        let style = OpID(counter: 77, replica: 1)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.ellipse.common.style.id = style.proto
        try f.a.perform(OpsCommand("style", ops: [Ops.set(f.ring, [RegisterPath([22, 1, 7])], values: props)]))
        #expect(f.find(.style(style)) == [f.ring])
    }

    @Test func textFontsEffectsColorsAndStyles() throws {
        var f = try Fixture()
        let paragraphStyle = OpID(counter: 88, replica: 1), characterStyle = OpID(counter: 89, replica: 1)
        var shadow = Wiretuner_Doc_V1_TextMarkValue()
        shadow.effect.shadow = .init()
        var red = Wiretuner_Doc_V1_TextMarkValue()
        red.fill = Self.red
        var style = Wiretuner_Doc_V1_TextMarkValue()
        style.style.id = characterStyle.proto
        let text = try LayerFixture.object(CreateTextBlock(.area(Rect(x: 10, y: 700, width: 100, height: 20)), text: "Hi",
                                                           marks: [.with { $0.fontFamily = "Helvetica" }, .with { $0.fontStyle = "Bold" },
                                                                   .with { $0.size = 18 }, shadow, red, style, .with { $0.overprint = true }],
                                                           paragraph: .with { $0.style.id = paragraphStyle.proto }, layer: f.art), on: &f.a)
        #expect(f.find(.font(family: "helvetica", style: nil, size: ValueRange())) == [text])
        #expect(f.find(.font(family: "Helvetica", style: "Bold", size: ValueRange(min: 12, max: 24))) == [text])
        #expect(f.find(.font(family: "Times", style: nil, size: ValueRange())).isEmpty)
        #expect(f.find(.font(family: nil, style: nil, size: ValueRange(max: 12))).isEmpty)
        #expect(f.find(.textEffect(nil)) == [text])
        #expect(f.find(.textEffect(.shadow)) == [text])
        #expect(f.find(.textEffect(.underline)).isEmpty)
        #expect(f.find(.color(Self.red)).contains(text))
        #expect(f.find(.style(paragraphStyle)) == [text])
        #expect(f.find(.style(characterStyle)) == [text])
        #expect(f.find(.overprint) == [text])
        // A text block's frame is its default bounds: it is on the page.
        #expect(f.find(.objectType(.textBlock), in: .page(f.page)) == [text])
        let kinds: [(Wiretuner_Doc_V1_TextEffect, AttributeQuery.TextEffectKind?)] = [
            (.with { $0.highlight = .init() }, .highlight), (.with { $0.underline = .init() }, .underline),
            (.with { $0.strikethrough = .init() }, .strikethrough), (.with { $0.inline = .init() }, .inline),
            (.with { $0.zoom = .init() }, .zoom), (.init(), nil),
        ]
        for (effect, kind) in kinds { #expect(AttributeMatcher.kind(effect) == kind) }
    }

    @Test func pathShapeMatchesScaledAndRotatedCopies() throws {
        var f = try Fixture()
        let sample = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (10, 20)]), on: &f.a)
        let copy = try f.a.perform(DuplicateObjects.clone([sample]))!.createdRoots[0]
        try f.a.perform(TransformObjects([copy], matrix: .rotation(radians: 1.1).concatenating(.scale(2.5)), about: Point(x: 5, y: 5), kind: .rotate))
        let other = try LayerFixture.object(PathFixture.closed([(0, 0), (30, 0), (20, 20)]), on: &f.a)
        let recolored = try f.a.perform(DuplicateObjects.clone([sample]))!.createdRoots[0]
        try f.a.perform(AddAppearance.fill([recolored]))
        let shape = try #require(PathShape(sample, in: f.a.state))
        #expect(shape.contours.count == 1 && shape.contours[0].closed && shape.contours[0].points.count == 9)
        #expect(f.find(.pathShape(shape)) == [sample, copy])
        #expect(!shape.matches(other, in: f.a.state) && !shape.matches(recolored, in: f.a.state))
        // The similarity maps the sample onto the copy: *Transform to fit original* semantics for
        // OBJ-023 use `fit`, which scales each axis from the replacement's bounds to the match's.
        let similarity = try #require(shape.similarity(to: PathShape(copy, in: f.a.state)!))
        #expect(abs(abs(similarity.determinant) - 6.25) < 1e-6)
        let fit = PathShape.fit(Rect(x: 0, y: 0, width: 10, height: 5), into: Rect(x: 100, y: 50, width: 40, height: 10))
        #expect(Rect(x: 0, y: 0, width: 10, height: 5).applying(fit) == Rect(x: 100, y: 50, width: 40, height: 10))
        #expect(PathShape.fit(Rect(x: 0, y: 0, width: 0, height: 5), into: Rect(x: 1, y: 1, width: 1, height: 1)) == .identity)
        // From the native pasteboard (Paste In): the copied object's pasteboard geometry.
        let pasted = try #require(PathShape(ClipboardPayload(copying: [copy], from: f.a.state)))
        #expect(pasted.similarity(to: shape) != nil)
        #expect(PathShape(ClipboardPayload(copying: [f.star], from: f.a.state)) != nil)
        #expect(PathShape(ClipboardPayload(copying: [f.ring], from: f.a.state)) != nil)
        #expect(PathShape(ClipboardPayload(copying: [f.logo], from: f.a.state)) != nil)
        #expect(PathShape(ClipboardPayload(copying: [f.group], from: f.a.state)) == nil)
        #expect(PathShape(ClipboardPayload(nodes: [])) == nil)
        #expect(PathShape(f.group, in: f.a.state) == nil)
        // Degenerate shapes: a single point matches itself moved, not a real shape.
        let dot = PathShape(VectorPath(contours: [VectorContour(points: PathFixture.points([(1, 1), (1, 1)]))]), transform: .identity, look: shape.look)
        let moved = PathShape(VectorPath(contours: [VectorContour(points: PathFixture.points([(4, 4), (4, 4)]))]), transform: .identity, look: shape.look)
        let line = PathShape(VectorPath(contours: [VectorContour(points: PathFixture.points([(0, 0), (4, 4)]))]), transform: .identity, look: shape.look)
        #expect(dot.similarity(to: moved) == .translation(x: 3, y: 3))
        #expect(dot.similarity(to: line) == nil)
        #expect(PathShape(VectorPath(contours: []), transform: .identity, look: shape.look).similarity(to: dot) == nil)
    }

    @Test func theDesignPointDocumentIsQueriedWithinBudget() throws {
        let count = PerfBudget.isMeasuring ? 50_000 : 2_000
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        var ops: [Wiretuner_Doc_V1_Op] = []
        let keys = try PathEditing.keys(between: nil, and: nil, count: count)
        for index in 0..<count {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.rect.common.name = "Object \(index)"
            props.rect.size.width = 10
            props.rect.size.height = 10
            props.rect.common.transform = PathEditing.proto(.translation(x: Double(index % 300) * 12, y: Double(index / 300) * 12))
            ops.append(Ops.create(parent: layer, position: keys[index], props: props))
        }
        try a.perform(OpsCommand("Design point", ops: ops))
        let clock = ContinuousClock()
        var found: [OpID] = []
        // The panel holds the candidates per document revision; walking the tree for them is
        // timed on its own (NodeStore sorts a parent's children on every read).
        var candidates: [OpID] = []
        let walk = clock.measure { candidates = AttributeQuery.candidates(.document, in: a.state) }
        #expect(AttributeQuery(.name("object 1234")).run(in: a.state) == AttributeQuery(.name("object 1234")).run(in: a.state, candidates: candidates))
        PerfBudget.expect(walk, within: .milliseconds(400), "attribute query candidates, \(count) objects")
        let elapsed = clock.measure { found = AttributeQuery(.name("object 1234")).run(in: a.state, candidates: candidates) }
        #expect(found.count == (count > 12_340 ? 11 : 1))
        PerfBudget.expect(elapsed, within: .milliseconds(100), "attribute query by name, \(count) objects")
        let typed = clock.measure { found = AttributeQuery(.objectType(.rectangle)).run(in: a.state, candidates: candidates) }
        #expect(found.count == count)
        PerfBudget.expect(typed, within: .milliseconds(100), "attribute query by type, \(count) objects")
    }

    @Test func theQueryWritesNothing() throws {
        let f = try Fixture()
        let hash = f.a.state.stateHash
        let sent = f.a.sent.count
        _ = AttributeQuery(.color(Self.red)).run(in: f.a.state)
        _ = AttributeQuery(.objectType(.path), in: .page(f.page)).select(in: f.a.state, adding: [f.logo])
        #expect(f.a.state.stateHash == hash && f.a.sent.count == sent)
    }
}
