import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// The "placed an instance of a removed symbol" and "uses a removed style" rows (library.adoc,
/// styles.adoc), measured on reconnect, with their choices as single changes.
@Suite struct RemovedTargetReviewTests {
    static func rect(_ x: Double) -> CreateShape {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        return CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .translation(x: x, y: 0), appearance: appearance)
    }

    @Test func placingAnInstanceOfASymbolRemovedMeanwhileIsListed() throws {
        var world = Reconnect()
        let shape = try #require(try world.shared(Self.rect(0))).createdObjects[0]
        let converted = try #require(try world.shared(ConvertToSymbol([shape], name: "Dot")))
        let symbol = converted.createdNodes[0]
        try world.byThem(RemoveSymbols([symbol], instances: .delete, in: world.theirs.state))
        let placed = try #require(try world.byMe(PlaceInstance(symbol, at: Point(x: 100, y: 100)))).createdNodes[0]
        let divergence = world.measure()
        let row = try #require(divergence.removedTargets.first)
        #expect(divergence.removedTargets.count == 1 && divergence.decision(.standard).holdsOutbox)
        #expect(row.kind == .removedSymbol && row.object == placed && row.target == symbol && row.authors == [world.theirs.replica])
        #expect(row.id == "removed-target:\(placed)" && row.kind.title == "Placed an instance of a removed symbol")
        #expect(row.choices == [.restore, .release] && RemovedTargetEntry.Choice.allCases.map(\.title) == ["Restore", "Release", "Keep look"])
        #expect(ReviewModel(divergence, decision: .perObject).removedTargets == [row])
        #expect(try row.command(.keepLook, in: world.mine.state) == nil)

        // *Release*: the placeholder becomes the artwork as it was.
        let release = try #require(try row.command(.release, in: world.mine.state))
        var released = world
        let change = try #require(try released.byMe(release))
        #expect(change.label == "Release Instance" && !released.mine.state.isLive(placed))
        #expect(change.createdObjects.contains { released.mine.state.nodeKind($0) == .group })
        // *Restore symbol*: the symbol and its artwork come back, and the instance draws it.
        let restore = try #require(try row.command(.restore, in: world.mine.state))
        try world.byMe(restore)
        #expect(world.mine.state.isLive(symbol) && Symbols.symbol(of: placed, in: world.mine.state) == symbol)
        #expect(try row.command(.restore, in: world.mine.state) == nil)
        world.upload()
    }

    @Test func applyingAStyleRemovedMeanwhileIsListedWithKeepLook() throws {
        var world = Reconnect()
        let shape = try #require(try world.shared(Self.rect(0))).createdObjects[0]
        let styled = try #require(try world.shared(CreateGraphicStyle(.selection(shape), name: "Blue")))
        let style = try #require(styled.createdNodes.first { NavigationFields.common(of: $0, in: world.theirs.state)?.name == "Blue" })
        let other = try #require(try world.shared(Self.rect(40))).createdObjects[0]
        try world.byThem(RemoveGraphicStyle(style, in: world.theirs.state))
        try world.byMe(ApplyGraphicStyle(style, to: [other], in: world.mine.state))
        let divergence = world.measure()
        let row = try #require(divergence.removedTargets.first)
        #expect(row.kind == .removedStyle && row.object == other && row.target == style && row.kind.title == "Uses a removed style")
        #expect(row.choices == [.restore, .keepLook])
        #expect(try row.command(.release, in: world.mine.state) == nil)
        let keep = try #require(try row.command(.keepLook, in: world.mine.state))
        var kept = world
        try kept.byMe(keep)
        let common = try #require(NavigationFields.common(of: other, in: kept.mine.state))
        #expect(!common.hasStyle || OpID(common.style.id) != style)
        let restore = try #require(try row.command(.restore, in: world.mine.state))
        #expect(restore.label == "Restore Style")
        try world.byMe(restore)
        #expect(world.mine.state.isLive(style))
    }

    @Test func nothingIsListedWithoutARemoval() throws {
        var world = Reconnect()
        let shape = try #require(try world.shared(Self.rect(0))).createdObjects[0]
        let symbol = try #require(try world.shared(ConvertToSymbol([shape], name: "Dot"))).createdNodes[0]
        try world.byThem(OpsCommand("Delete", ops: [Ops.setDeleted(OpID(counter: 9_999, replica: 1), true)]))
        try world.byMe(PlaceInstance(symbol, at: .zero))
        #expect(world.measure().removedTargets.isEmpty)
        #expect(try RemovedTargetReview.against(restored: [], in: EngineState(), OpsCommand("x", ops: [])) == nil)
    }
}
