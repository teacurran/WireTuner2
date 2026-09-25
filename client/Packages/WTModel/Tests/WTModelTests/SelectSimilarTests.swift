import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// menu:Edit[Select > Similar] (OBJ-042, selecting.adoc "Select Similar").
@Suite struct SelectSimilarTests {
    /// A fixture page: `swatched` and `twin` fill with the swatch Brand, `literal` with an equal
    /// literal colour; `dashed` and `solid` both stroke 2 pt black, `dashed` with a dash; `far` is
    /// swatched too but off the page; `locked` is swatched and locked.
    struct Fixture {
        var a = Replica(0xA)
        var page: OpID
        var brand: OpID
        var swatched: OpID, twin: OpID, literal: OpID, dashed: OpID, solid: OpID, far: OpID, locked: OpID

        init() throws {
            page = try PageFixture.onePage(&a)
            let color = Color(red: 0.2, green: 0.4, blue: 0.6)
            let brand = try ColorFixture.add(&a, color, name: "Brand")
            self.brand = brand
            let swatch = Wiretuner_Doc_V1_ColorRef.with { $0.swatch.id = brand.proto }
            let inline = ColorResolver.inline(color)
            swatched = try Self.shape(&a, at: 10, fill: swatch)
            twin = try Self.shape(&a, at: 40, fill: swatch)
            literal = try Self.shape(&a, at: 70, fill: inline)
            dashed = try Self.shape(&a, at: 100, fill: nil, stroke: 2, dash: [4, 2])
            solid = try Self.shape(&a, at: 130, fill: nil, stroke: 2)
            far = try Self.shape(&a, at: 5000, fill: swatch)
            locked = try Self.shape(&a, at: 160, fill: swatch)
            try a.perform(SetLocked([locked], locked: true))
        }

        static func shape(_ replica: inout Replica, at x: Double, fill: Wiretuner_Doc_V1_ColorRef?, stroke width: Double? = nil,
                          dash: [Double] = []) throws -> OpID {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            if let fill {
                appearance.fills = [.with { $0.settings.kind = .basic; $0.settings.basic.color = fill }]
            }
            if let width {
                appearance.strokes = [.with { stroke in
                    stroke.settings.kind = .basic
                    stroke.settings.basic.color = ColorResolver.inline(Color(red: 0, green: 0, blue: 0))
                    stroke.settings.basic.width = width
                    if !dash.isEmpty { stroke.settings.basic.dash.lengths = dash }
                }]
            }
            let points = [(0.0, 0.0), (10, 0), (10, 10), (0, 10)].map { VectorPoint(anchor: Point(x: x + $0.0, y: 50 + $0.1)) }
            return try replica.perform(CreatePath(contours: [NewContour(closed: true, points: points)], appearance: appearance))!.createdObjects[0]
        }

        func run(_ attribute: SelectSimilar.Attribute, _ selection: [OpID], adding: Bool = false,
                 classifier: (any ShapeClassifying)? = nil) -> SelectSimilar.Outcome? {
            SelectSimilar.run(attribute, selection: selection, page: page, adding: adding, classifier: classifier, in: a.state)
        }
    }

    @Test func fillMatchesTheSwatchReferenceNotAnEqualLiteral() throws {
        let f = try Fixture()
        let outcome = try #require(f.run(.fill, [f.swatched]))
        #expect(outcome.selection == [f.swatched, f.twin], "not the literal, not off the page, not locked")
        #expect(outcome.found == 2 && outcome.status == "2 objects selected")
        #expect(f.run(.fill, [f.literal])?.selection == [f.literal])
        #expect(f.run(.fill, [f.literal])?.status == "1 object selected")
    }

    @Test func strokeTellsADashFromASolidStroke() throws {
        let f = try Fixture()
        #expect(f.run(.stroke, [f.dashed])?.selection == [f.dashed])
        #expect(f.run(.stroke, [f.solid])?.selection == [f.solid])
        // The swatched shapes have no stroke: equal to one another's stroke (none) and to the literal's.
        #expect(f.run(.stroke, [f.swatched])?.selection == [f.swatched, f.twin, f.literal])
        #expect(f.run(.fillAndStroke, [f.swatched])?.selection == [f.swatched, f.twin])
        #expect(f.run(.fillAndStroke, [f.dashed])?.selection == [f.dashed])
    }

    @Test func shiftAddsToTheSelection() throws {
        let f = try Fixture()
        let outcome = try #require(SelectSimilar.run(.fill, selection: [f.swatched], page: f.page, adding: true, in: f.a.state))
        #expect(outcome.selection == [f.swatched, f.twin])
        // Adding keeps an earlier selection first (the commands need exactly one object, so the
        // earlier selection is the sample).
        let unpaged = try #require(SelectSimilar.run(.fill, selection: [f.twin], page: nil, adding: true, in: f.a.state))
        #expect(unpaged.selection == [f.twin, f.swatched, f.far], "an unpaged scope is the document")
    }

    @Test func disabledWithNoneOrSeveralSelected() throws {
        let f = try Fixture()
        #expect(f.run(.fill, []) == nil)
        #expect(f.run(.fill, [f.swatched, f.twin]) == nil)
        #expect(f.run(.fill, [f.page]) == nil, "a page is not an object")
        #expect(SelectSimilar.run(.fill, selection: [f.swatched], page: OpID(counter: 999, replica: 9), in: f.a.state) == nil)
        #expect(SelectSimilar.sample([f.swatched], in: f.a.state) == f.swatched)
    }

    @Test func nothingIsWrittenToTheDocument() throws {
        let f = try Fixture()
        let before = StateHash.of(f.a.state.store)
        let log = f.a.sent.count
        for attribute in SelectSimilar.Attribute.allCases {
            _ = f.run(attribute, [f.swatched], adding: true, classifier: Classes())
        }
        #expect(StateHash.of(f.a.state.store) == before && f.a.sent.count == log)
    }

    struct Classes: ShapeClassifying {
        func shapeClass(of node: OpID, in state: EngineState) -> String? {
            state.nodeKind(node) == .path ? "rectangle" : nil
        }
    }

    struct Silent: ShapeClassifying {
        func shapeClass(of node: OpID, in state: EngineState) -> String? { nil }
    }

    @Test func shapeIsOfferedOnlyWithAClassifier() throws {
        let f = try Fixture()
        #expect(SelectSimilar.items(classifier: nil) == [.fill, .stroke, .fillAndStroke])
        #expect(SelectSimilar.items(classifier: Classes()) == SelectSimilar.Attribute.allCases)
        #expect(SelectSimilar.Attribute.allCases.map(\.title) == ["Fill", "Stroke", "Fill and Stroke", "Shape"])
        #expect(f.run(.shape, [f.swatched]) == nil)
        #expect(f.run(.shape, [f.swatched], classifier: Silent()) == nil)
        let shaped = try #require(f.run(.shape, [f.swatched], classifier: Classes()))
        #expect(shaped.selection == [f.swatched, f.twin, f.literal, f.dashed, f.solid])
    }

    @Test func aGroupComparesItsOwnStackAndAnOffPageSampleStaysSelected() throws {
        var f = try Fixture()
        let group = try f.a.perform(GroupObjects([f.twin]))!.createdObjects[0]
        // A group's own stack has no fill: it matches the unfilled objects on the page.
        let outcome = try #require(f.run(.fill, [group]))
        #expect(Set(outcome.selection) == [group, f.dashed, f.solid])
        // A sample off the page is still in the result, after the page's matches.
        #expect(f.run(.fill, [f.far])?.selection == [f.swatched, group, f.far] || f.run(.fill, [f.far])?.selection.last == f.far)
    }
}
