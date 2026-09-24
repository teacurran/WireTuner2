import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// menu:File[Duplicate] (IO-004) and what Spotlight indexes (IO-035).
@Suite struct DocumentDuplicateTests {
    @Test func theCopyReadsLikeTheOriginalAtTheDuplicationPointAndTakesNothingAfter() throws {
        var pair = Pair()
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &pair.a)
        pair.sync()
        // The plan captures the original as it is now.
        let plan = try DocumentDuplicate.plan(pair.a.state)
        let atDuplication = CanonicalReadout.of(pair.a.state)
        // The original keeps receiving remote changes while the copy is written.
        let contour = pair.b.path(path).contours[0]
        try pair.b.perform(MovePoints(node: path, contour: contour.id, point: contour.points[0].id, to: Point(x: 9, y: 9)))
        try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.b)
        pair.sync()
        var copy = Replica(0xC)
        var changes: [Wiretuner_Doc_V1_Change] = []
        while !plan.isFinished {
            changes.append(try #require(try copy.perform(DuplicateChunk(plan))))
        }
        #expect(changes.allSatisfy { $0.label == DocumentDuplicate.label })
        #expect(CanonicalReadout.of(copy.state) == atDuplication, "the copy is the original at the duplication point")
        #expect(CanonicalReadout.of(pair.a.state) != atDuplication, "the original moved on")
        let ids = Set(copy.state.store.nodes.filter { $0.replica != 0 })
        #expect(ids.allSatisfy { $0.replica == 0xC }, "no OpId of the original")
        #expect(DocumentDuplicate.name(for: "Logo") == "Logo copy")
    }

    @Test func spotlightReadsDescriptionKeywordsAndTextInTreeOrder() throws {
        var a = Replica(0xA)
        try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 100, height: 20)), text: "The quokka"))
        try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 40, width: 100, height: 20)), text: "smiles"))
        try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 80, width: 100, height: 20)), text: ""))
        var keywords = Wiretuner_Doc_V1_NodeProps()
        keywords.settings.info.keywords = ["marsupial", "animal"]
        try a.perform(OpsCommand("Keywords", ops: [Ops.setAdd(WellKnown.settings, RegisterPath([2, 130, 4]), values: keywords)]))
        var info = Wiretuner_Doc_V1_NodeProps()
        info.settings.info.description_p = "A poster"
        try a.perform(OpsCommand("Describe", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 130, 3])], values: info)]))
        let content = SpotlightContent.of(a.state)
        #expect(content == SpotlightContent(description: "A poster", keywords: ["animal", "marsupial"], text: "The quokka\nsmiles"))
        #expect(SpotlightContent.of(EngineState()) == SpotlightContent())
    }

    @Test func spotlightTextIsCappedOnACharacterBoundary() {
        #expect(SpotlightContent.capped("abc", limit: 5) == "abc")
        #expect(SpotlightContent.capped("aéb", limit: 2) == "a", "é is two bytes")
        #expect(SpotlightContent.capped("aéb", limit: 3) == "aé")
        #expect(SpotlightContent.textLimit == 1_048_576)
    }
}
