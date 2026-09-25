import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// `CopiesBehind` (FX-033's change): copies grouped behind the object, recoloured, and the merge
/// with a concurrent delete.
@Suite struct CopiesBehindTests {
    static func fill(_ node: OpID, in state: EngineState) -> Color? {
        ColorResolver(state).color(state.props(node).rect.appearance.fills[0].settings.basic.color)
    }

    static func rect(_ a: inout Replica) throws -> OpID {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        return try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .identity, appearance: appearance))!.createdObjects[0]
    }

    @Test func copiesGoBehindTheObjectInOneGroupWithTheirPaints() throws {
        var a = Replica(0xA)
        let rect = try Self.rect(&a)
        let layer = Objects.parent(of: rect, in: a.state)!
        let copies = [
            CopiesBehind.Copy(matrix: .translation(Vector(dx: 5, dy: 0)), fill: .toward(.black, amount: 1), stroke: .none),
            CopiesBehind.Copy(matrix: .translation(Vector(dx: 2, dy: 0)), fill: .then(.toward(.white, amount: 0.5), .toward(.black, amount: 0)), stroke: .keep),
        ]
        let change = try #require(try a.perform(CopiesBehind("Add shadow", copies: [(rect, copies), (OpID(counter: 99, replica: 9), copies)])))
        #expect(change.label == "Add shadow")
        let group = try #require(Objects.parent(of: rect, in: a.state))
        #expect(group != layer && a.state.nodeKind(group) == .group)
        let members = a.state.liveChildren(group)
        #expect(members.count == 3 && members[2] == rect)
        #expect(Objects.transform(of: members[0], in: a.state).tx == 5)
        #expect(Self.fill(members[0], in: a.state)?.converted(to: .cmyk).components.w ?? 0 > 0.99)
        #expect(a.state.props(members[0]).rect.appearance.strokes[0].settings.basic.color.none)
        #expect(Self.fill(members[1], in: a.state)?.space == .cmyk)
        #expect(CopiesBehind.objectCount(group, copies: 2, in: a.state) == 8)
        // No copies: nothing written.
        #expect(try a.perform(CopiesBehind("Smudge", copies: [(rect, [])])) == nil)
        // Mixing: the ends stay themselves; spot inks give process intermediates.
        #expect(CopiesBehind.mix(.white, .black, amount: 0) == .white && CopiesBehind.mix(.white, .black, amount: 1) == .black)
        let spot = Color(cyan: 0, magenta: 1, yellow: 0, black: 0).asSpot(SpotInk(.registration, name: "Ink"))
        #expect(CopiesBehind.mix(spot, .white, amount: 0).spot == nil && CopiesBehind.mix(.white, spot, amount: 1).spot == nil)
        #expect(CopiesBehind.painted(Wiretuner_Doc_V1_ColorRef(), .toward(.black, amount: 1), resolver: ColorResolver(a.state)) == Wiretuner_Doc_V1_ColorRef())
    }

    @Test func aConcurrentDeleteLeavesTheCopies() throws {
        var pair = Pair()
        let rect = try Self.rect(&pair.a)
        pair.sync()
        try pair.b.perform(DeleteNodes([rect]))
        try pair.a.perform(CopiesBehind("Add shadow", copies: [(rect, [CopiesBehind.Copy(matrix: .translation(Vector(dx: 3, dy: 3)))])]))
        pair.sync()
        for state in [pair.a.state, pair.b.state] {
            let group = try #require(Objects.parent(of: rect, in: state))
            #expect(!state.isLive(rect) && state.liveChildren(group).count == 1)
        }
    }
}
