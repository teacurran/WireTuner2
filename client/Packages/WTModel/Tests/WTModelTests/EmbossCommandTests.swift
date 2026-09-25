import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-034: the Emboss kernel's five styles on a rounded square and the change that groups the facets.
@Suite struct EmbossCommandTests {
    static func roundedSquare(_ replica: inout Replica, fill: Wiretuner_Doc_V1_Fill = Appearances.basicFill(red: 0.2, green: 0.4, blue: 0.8)) throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [fill]
        return try LayerFixture.object(CreateShape(.rectangle(CornerRadii(topLeft: 10, topRight: 10, bottomRight: 10, bottomLeft: 10)), size: Size(width: 100, height: 100),
                                                   transform: .translation(x: 50, y: 50), appearance: appearance), on: &replica)
    }

    static func area(_ facets: [EmbossFacet]) -> Double {
        facets.map { facet in abs(FilledPath(contours: facet.contours).signedArea()) }.reduce(0, +)
    }

    @Test func everyStyleBuildsFacetsInsideTheShape() throws {
        var a = Replica(0xA)
        let square = try Self.roundedSquare(&a)
        #expect(EmbossKernel.isEligible(square, in: a.state))
        let shape = EmbossKernel.shape(square, in: a.state)
        let base = EmbossKernel.baseColor(square, in: a.state)
        let whole = abs(shape.signedArea())
        for style in EmbossStyle.allCases {
            let facets = EmbossKernel.facets(shape, base: base, settings: EmbossSettings(style: style, depth: 8))
            #expect(!facets.isEmpty, "\(style)")
            #expect(Self.area(facets) < whole && Self.area(facets) > 0, "\(style) stays inside")
            // Contrast facets are process CMYK for an RGB object.
            #expect(facets.allSatisfy { $0.color.space == .cmyk }, "\(style)")
            #expect(!style.title.isEmpty)
        }
        // Emboss lights the facing edge, Deboss the other; soft edge makes steps.
        let emboss = EmbossKernel.facets(shape, base: base, settings: EmbossSettings(style: .emboss, depth: 8))
        let deboss = EmbossKernel.facets(shape, base: base, settings: EmbossSettings(style: .deboss, depth: 8))
        #expect(emboss[0].color == deboss[1].color && emboss.count == 2)
        let soft = EmbossKernel.facets(shape, base: base, settings: EmbossSettings(style: .emboss, depth: 8, softEdge: true))
        #expect(soft.count == 8)
        // Colors: the two boxes.
        let colors = EmbossKernel.facets(shape, base: base, settings: EmbossSettings(style: .chisel, varyColors: true, highlight: .white, shadow: .black, depth: 8))
        #expect(colors.map(\.color) == [.white, .black])
        #expect(EmbossKernel.facets(.empty, base: base, settings: EmbossSettings()).isEmpty)
        // Too deep for the shape: the collapsed insets give no facets of their own.
        let small = FilledPath(Contour(polygon: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 10)]))
        let deep = EmbossKernel.facets(small, base: base, settings: EmbossSettings(style: .quilt, depth: 72))
        #expect(deep.count < 4)
        #expect(EmbossKernel.bounds(.empty) == nil)
    }

    @Test func theChangeGroupsTheFacetsAboveTheObject() throws {
        var a = Replica(0xA)
        let square = try Self.roundedSquare(&a)
        let facets = EmbossKernel.facets(EmbossKernel.shape(square, in: a.state), base: .black, settings: EmbossSettings(style: .ridge, depth: 6))
        let change = try #require(try a.perform(EmbossObjects([(square, facets)])))
        #expect(change.label == "Emboss")
        let group = try #require(Objects.parent(of: square, in: a.state))
        #expect(a.state.nodeKind(group) == .group)
        let members = a.state.liveChildren(group)
        #expect(members.count == facets.count + 1 && members.first == square)
        // Each facet draws where the kernel put it, filled, unstroked.
        let facet = members[1]
        let bounds = try #require(Objects.bounds(of: facet, in: a.state))
        #expect(bounds.minX >= 49 && bounds.maxX <= 151)
        #expect(NodeValues.appearance(a.state.props(facet))?.strokes.isEmpty == true)
        // Nothing for objects without facets or that are not objects.
        #expect(try a.perform(EmbossObjects([(square, [])])) == nil)
        let other = try Self.roundedSquare(&a)
        try a.perform(EmbossObjects([(other, facets), (other, [])]))
        #expect(a.state.nodeKind(try #require(Objects.parent(of: other, in: a.state))) == .group)
        #expect(try a.perform(EmbossObjects([(WellKnown.layers, facets)])) == nil)
    }

    @Test func eligibilityAndBaseColors() throws {
        var a = Replica(0xA)
        let open = try a.perform(CreatePath(contours: [NewContour(points: [VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 10, y: 0))])]))!.createdObjects[0]
        #expect(!EmbossKernel.isEligible(open, in: a.state) && EmbossKernel.baseColor(open, in: a.state) == .black)
        #expect(EmbossKernel.shape(WellKnown.layers, in: a.state).isEmpty)
        var gradient = Wiretuner_Doc_V1_Fill()
        gradient.settings.kind = .gradient
        gradient.settings.gradient = EffectPreset.startingMask
        let graded = try Self.roundedSquare(&a, fill: gradient)
        #expect(EmbossKernel.isEligible(graded, in: a.state) && EmbossKernel.baseColor(graded, in: a.state).srgb.x < 0.01)
        var pattern = Wiretuner_Doc_V1_Fill()
        pattern.settings.kind = .pattern
        pattern.settings.pattern.color = ColorResolver.inline(.white)
        let patterned = try Self.roundedSquare(&a, fill: pattern)
        #expect(EmbossKernel.baseColor(patterned, in: a.state) == .white)
        var lens = Wiretuner_Doc_V1_Fill()
        lens.settings.kind = .lens
        #expect(!EmbossKernel.isEligible(try Self.roundedSquare(&a, fill: lens), in: a.state))
        var empty = Wiretuner_Doc_V1_Fill()
        empty.settings.kind = .gradient
        #expect(EmbossKernel.baseColor(try Self.roundedSquare(&a, fill: empty), in: a.state) == .black)
        var none = Wiretuner_Doc_V1_Fill()
        none.settings.basic.color = Wiretuner_Doc_V1_ColorRef()
        #expect(EmbossKernel.baseColor(try Self.roundedSquare(&a, fill: none), in: a.state) == .black)
        var unresolved = Wiretuner_Doc_V1_Fill()
        unresolved.settings.kind = .pattern
        #expect(EmbossKernel.baseColor(try Self.roundedSquare(&a, fill: unresolved), in: a.state) == .black)
        var evenOdd = VectorPath(contours: [VectorContour(closed: true, points: [VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 10, y: 0)), VectorPoint(anchor: Point(x: 0, y: 10))])])
        evenOdd.evenOdd = true
        let odd = try a.perform(CreatePath(contours: [NewContour(closed: true, points: evenOdd.contours[0].points)], evenOdd: true))!.createdObjects[0]
        #expect(EmbossKernel.shape(odd, in: a.state).fillRule == .evenOdd)
        let bare = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), appearance: Wiretuner_Doc_V1_AppearanceProps()), on: &a)
        #expect(EmbossKernel.baseColor(bare, in: a.state) == .black)
    }
}
