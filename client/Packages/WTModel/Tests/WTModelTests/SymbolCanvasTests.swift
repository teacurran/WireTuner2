import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-012's model half: a symbol's canvas draws its artwork, and commands performed on it create
/// into the symbol.
@Suite struct SymbolCanvasTests {
    /// A command creating a group on the drawing layer with one member inside it.
    struct GroupWithMember: Command {
        var label: String { "Group with member" }

        func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
            let layer = try PathEditing.ensureLayer(&builder, state: state)
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group.common.name = "Pair"
            let id = builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: group))
            var rect = Wiretuner_Doc_V1_NodeProps()
            rect.rect.size.width = 5
            rect.rect.size.height = 5
            builder.append(Ops.create(parent: id, position: [0x80], props: rect))
        }
    }

    static func builder(_ symbol: OpID?, _ state: EngineState) -> DocumentDisplayListBuilder {
        var builder = DocumentDisplayListBuilder(canvas: "symbol")
        builder.canvasNode = symbol
        builder.rebuild(state)
        return builder
    }

    @Test func aSymbolCanvasDrawsTheArtworkAsTopLevelObjects() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        let canvas = Self.builder(symbol, a.state)
        #expect(canvas.scene.topLevel == masters.map(NodeID.init))
        #expect(masters.allSatisfy { canvas.scene.object($0)?.layer == symbol && canvas.scene.object($0)?.isEffectivelyLocked == false })
        #expect(canvas.scene.object(instance) == nil, "the instance is on the pasteboard, not in the symbol")
        #expect(canvas.scene.object(masters[1])?.bounds == Rect(x: 18, y: -2, width: 14, height: 14), "symbol space is pasteboard space (painted bounds)")
        let pasteboard = Self.builder(nil, a.state)
        #expect(pasteboard.scene.topLevel == [NodeID(instance)])
        // Output draws the same artwork.
        var output = canvas
        #expect(output.outputDisplayList(a.state).items.count == 2)
        // A deleted symbol's canvas is empty.
        try a.perform(RemoveSymbols([symbol], instances: .release, in: a.state))
        #expect(Self.builder(symbol, a.state).scene.topLevel.isEmpty)
    }

    @Test func drawingOnTheCanvasCreatesIntoTheSymbolAndReachesEveryInstance() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        var canvas = Self.builder(symbol, a.state)
        var pasteboard = Self.builder(nil, a.state)
        let before = try #require(pasteboard.scene.object(instance)?.bounds)
        let command = SymbolPlacedCommand.placing(SymbolFixture.rect(x: 40), in: symbol)
        #expect(SymbolPlacedCommand.placing(command, in: symbol) is SymbolPlacedCommand)
        #expect(command.label == "Rectangle" && command.coalescing == .none && command.recordsUndo)
        let change = try #require(try a.perform(command))
        let created = try #require(change.createdObjects.first)
        #expect(a.state.liveChildren(symbol) == masters + [created], "on top of the artwork")
        let (scene, summary) = canvas.apply(change, state: a.state, origin: .local)
        #expect(scene.topLevel.last == NodeID(created) && summary.touchedNodes.contains(NodeID(created)))
        let (main, mainSummary) = pasteboard.apply(change, state: a.state, origin: .local)
        #expect(mainSummary.touchedNodes.contains(NodeID(instance)), "the instance repaints in the same change")
        #expect(main.object(instance)?.bounds?.width ?? 0 > before.width)
        a.undo()
        #expect(a.state.liveChildren(symbol) == masters)
    }

    @Test func nestedCreationsKeepTheirParentAndAMissingSymbolPlacesNothing() throws {
        var a = Replica(0xA)
        // An empty document: the command makes its own layer, whose objects still go in the symbol.
        let symbol = try #require(try a.perform(CopyToSymbol([try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]]))?.createdNodes.first)
        try a.perform(SymbolPlacedCommand(base: GroupWithMember(), symbol: symbol))
        let group = try #require(a.state.liveChildren(symbol).last)
        #expect(a.state.props(group).group.common.name == "Pair" && a.state.liveChildren(group).count == 1)
        var fresh = Replica(0xB)
        let orphan = OpID(counter: 999, replica: 9)
        let change = try #require(try fresh.perform(SymbolPlacedCommand(base: GroupWithMember(), symbol: orphan)))
        let made = try #require(change.createdNodes.first { fresh.state.nodeKind($0) == .layer })
        #expect(fresh.state.liveChildren(made).count == 1, "no symbol: drawn on the layer")
        #expect(Symbols.canvasBounds(of: orphan, in: fresh.state) == Rect(x: -36, y: -36, width: 72, height: 72))
        let layerChange = try #require(try fresh.perform(SymbolPlacedCommand(base: GroupWithMember(), symbol: made)))
        #expect(layerChange.createdObjects.allSatisfy { fresh.state.nodeKind(Objects.parent(of: $0, in: fresh.state) ?? .zero) != .symbol })
    }

    @Test func canvasBoundsFitTheArtworkOrTheOrigin() throws {
        var a = Replica(0xA)
        let (symbol, _, masters) = try SymbolFixture.converted(on: &a)
        #expect(Symbols.canvasBounds(of: symbol, in: a.state) == Rect(x: 0, y: 0, width: 30, height: 10))
        try a.perform(ClearObjects(masters))
        #expect(Symbols.canvasBounds(of: symbol, in: a.state) == Rect(x: -21, y: -31, width: 72, height: 72))
        guard case .group(let background)? = Symbols.canvasBackground(of: symbol, in: a.state).first,
              case .stroke(let cross)? = background.children.last else { Issue.record("no background"); return }
        #expect(DisplayItem.stroke(cross).bounds?.center == Point(x: 15, y: 5) && cross.paint == .solid(Symbols.originColor))
        #expect(Symbols.canvasBackground(of: masters[0], in: a.state).isEmpty, "not a symbol")
        try a.perform(RemoveSymbols([symbol], instances: .delete, in: a.state))
        #expect(Symbols.canvasBackground(of: symbol, in: a.state).isEmpty, "gone")
    }

    @Test func twoEditorsOfOneSymbolConverge() throws {
        var pair = Pair()
        let (symbol, _, masters) = try SymbolFixture.converted(on: &pair.a)
        pair.sync()
        try pair.a.perform(SymbolPlacedCommand(base: SymbolFixture.rect(x: 40), symbol: symbol))
        try pair.b.perform(SymbolPlacedCommand(base: SymbolFixture.rect(x: 60), symbol: symbol))
        try pair.b.perform(MoveObjects([masters[0]], by: Vector(dx: 5, dy: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.liveChildren(symbol).count == 4)
        #expect(Self.builder(symbol, pair.a.state).scene.displayList == Self.builder(symbol, pair.b.state).scene.displayList)
    }
}
