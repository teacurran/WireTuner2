import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-019/020: style-driven appearance in the scene (`StyleAppearance`, hooked into
/// `DocumentDisplayListBuilder`) and the style-to-objects index kept change by change
/// (`GraphicStyleIndex`).
@Suite struct StyleSceneTests {
    typealias F = StyleCommandFixture

    static func paints(_ scene: DocumentScene, _ node: OpID) -> [AppearanceItem] {
        guard case .path(let item)? = scene.object(node)?.item else { return [] }
        return item.appearance.items
    }

    static func fill(_ scene: DocumentScene, _ node: OpID) -> Color? {
        for case .fill(let paint) in paints(scene, node) { return paint.paint.color }
        return nil
    }

    static func strokeWidth(_ scene: DocumentScene, _ node: OpID) -> Double? {
        for case .stroke(let paint) in paints(scene, node) { return paint.style.width }
        return nil
    }

    @Test func styledObjectsDrawTheirLookAndRedrawWhenTheStyleChanges() throws {
        var (a, layer) = try F.document()
        let ids = try StyleFixture.create([StyleFixture.props("Root", fill: 0.25, stroke: 3), StyleFixture.props("Kid", behavior: [.strokes])], on: &a)
        try a.perform(OpsCommand("Parent", ops: [StyleFixture.setParent(ids[1], ids[0])]))
        let objects = try F.objects([(ids[0], nil, false), (ids[1], 0.75, false), (nil, 0.5, false)], layer: layer, on: &a)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        #expect(Self.fill(scene, objects[0])?.red == 0.25 && Self.strokeWidth(scene, objects[0]) == 3)
        #expect(Self.fill(scene, objects[1])?.red == 0.75 && Self.strokeWidth(scene, objects[1]) == 3, "an override over the chain")
        #expect(Self.fill(scene, objects[2])?.red == 0.5 && Self.strokeWidth(scene, objects[2]) == nil, "no style: its own registers")
        // Redefining the root redraws both styled objects (through the chain) and not the plain one.
        try F.stroke(8, on: objects[2], &a)
        builder.rebuild(a.state)
        let change = try #require(try a.perform(RedefineGraphicStyle(ids[0], from: .object(objects[2]))))
        let (redrawn, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(Self.fill(redrawn, objects[0])?.red == 0.5 && Self.strokeWidth(redrawn, objects[0]) == 8)
        #expect(Self.strokeWidth(redrawn, objects[1]) == 8)
        #expect(summary.touchedNodes.contains(NodeID(objects[0])) && summary.touchedNodes.contains(NodeID(objects[1])))
        #expect(!summary.touchedNodes.contains(NodeID(objects[2])))
    }

    @Test func defaultsAndFullOverridesInTheScene() throws {
        var (a, layer) = try F.document()
        let style = try StyleFixture.create([StyleFixture.props("Fills", behavior: [.fills], fill: 0.4)], on: &a)[0]
        let objects = try F.objects([(style, nil, false), (style, 0.6, false)], layer: layer, on: &a)
        try F.stroke(2, on: objects[1], &a)
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .bend
        try a.perform(AddAppearance.effect([objects[1]], effect))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        // The style sets only fills: the stroke comes from the (built-in) defaults.
        #expect(Self.fill(scene, objects[0])?.red == 0.4 && Self.strokeWidth(scene, objects[0]) == 1)
        #expect(builder.dependencies.dependents(of: [NodeID(WellKnown.settings)]).contains(NodeID(objects[0])))
        // Every category its own: drawn from its registers as they are.
        #expect(Self.fill(scene, objects[1])?.red == 0.6 && Self.strokeWidth(scene, objects[1]) == 2)
        // A defaults edit redraws the object that falls back to them.
        let change = try #require(try a.perform(AddAppearance.stroke([WellKnown.settings], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 5))))
        let (redrawn, _) = builder.apply(change, state: a.state, origin: .local)
        #expect(Self.strokeWidth(redrawn, objects[0]) == 5)
    }

    @Test func applyVersusStackOrderAcrossSources() throws {
        // An object whose fill comes from its style and whose stroke is its own draws the fill
        // below the stroke; with both from one style, that style's order.
        var props = StyleFixture.props("Both", fill: 0.3, stroke: 4)
        props.style.appearance.fills.append(Appearances.basicFill(red: 0.9, green: 0, blue: 0))
        var (a, layer) = try F.document()
        let style = try StyleFixture.create([props], on: &a)[0]
        let objects = try F.objects([(style, nil, false)], layer: layer, on: &a)
        try F.stroke(6, on: objects[0], &a)
        let scene = DocumentDisplayListBuilder(canvas: "c").rebuilding(a.state)
        let items = Self.paints(scene, objects[0])
        #expect(items.count == 3)
        if case .stroke(let top)? = items.last { #expect(top.style.width == 6) } else { Issue.record("the stroke is on top") }
    }

    @Test func attachmentsAcrossSourcesAndNodesWithoutAStack() throws {
        var (a, layer) = try F.document()
        // The style's effect is attached to the style's fill; an object overriding the fill keeps
        // the style's effect, which then applies to the whole object.
        let style = try StyleFixture.create([StyleFixture.props("FX", fill: 0.2)], on: &a)[0]
        let fill = try #require(a.state.liveElements(style, RegisterPath([154, 6, 1])).first)
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .bend
        effect.attachedTo = Ops.elementID(fill)
        try a.perform(OpsCommand("Effect", ops: [Ops.elementInsert(style, RegisterPath([154, 6, 3]), positions: [[0xC0]],
                                                                   values: Wiretuner_Doc_V1_NodeProps.with { $0.style.appearance.effects = [effect] })]))
        let objects = try F.objects([(style, nil, false), (style, 0.9, false)], layer: layer, on: &a)
        let styled = F.look(objects[0], a.state)
        guard case .effect(let attached)? = styled.stack.last else { Issue.record("no effect"); return }
        #expect(attached.attachedTo.counter == 1, "attached to the fill's place")
        guard case .effect(let loose)? = F.look(objects[1], a.state).stack.last else { Issue.record("no effect"); return }
        #expect(!loose.hasAttachedTo, "the fill is the object's own: the attachment is dropped")
        let scene = DocumentDisplayListBuilder(canvas: "c").rebuilding(a.state)
        guard case .path(let drawn)? = scene.object(objects[0])?.item else { Issue.record("not drawn"); return }
        #expect(drawn.appearance.effects.count == 1, "the style's effect is drawn")
        // A node without a stack that names a style is drawn from its registers.
        var placed = Wiretuner_Doc_V1_NodeProps()
        placed.placedFile.common.style.id = style.proto
        let file = try #require(try a.perform(CreateTrees([(layer, [0x90], placed)]))).createdNodes[0]
        var props = a.state.props(file)
        var order: [AppearanceRow] = []
        #expect(StyleAppearance.apply(GraphicStyleResolver(a.state), to: &props, order: &order, node: file, state: a.state).isEmpty)
        #expect(props == a.state.props(file))
    }

    // MARK: Index

    @Test func theIndexFollowsChangesLikeAFullRead() throws {
        var (a, layer) = try F.document()
        let ids = try StyleFixture.create([StyleFixture.props("A", fill: 0.1), StyleFixture.props("B", fill: 0.2)], on: &a)
        var styles = GraphicStyleResolver(a.state)
        var index = GraphicStyleIndex(a.state, styles: styles)
        #expect(index.objects.isEmpty && !index.isUsed(ids[0]))
        func step(_ command: any Command) throws {
            let change = try #require(try a.perform(command))
            styles.update(a.state)
            index.refresh(GraphicStyleIndex.touched(by: change), in: a.state, styles: styles)
            #expect(index == GraphicStyleIndex(a.state, styles: styles))
        }
        try step(CreateTrees([StyleFixture.object(on: layer, style: ids[0], key: [0x81]), StyleFixture.object(on: layer, style: nil, key: [0x82])]))
        let objects = a.state.liveChildren(layer)
        #expect(index.objects(using: ids[0]) == [objects[0]] && index.style(of: objects[0]) == ids[0])
        try step(ApplyGraphicStyle(ids[1], to: objects))
        #expect(index.objects(using: ids[1]) == objects.sorted() && !index.isUsed(ids[0]))
        try step(RenameGraphicStyle(ids[0], to: "Unused"))
        #expect(index.objects(using: ids[0]).isEmpty)
        try step(GroupObjects(objects))
        let group = try #require(a.state.liveChildren(layer).first)
        try step(OpsCommand("Delete group", ops: [Ops.setDeleted(group)]))
        #expect(index.objects.isEmpty, "a deleted group takes its members out")
        try step(OpsCommand("Restore group", ops: [Ops.setDeleted(group, false)]))
        #expect(index.objects(using: ids[1]).count == 2)
        try step(RemoveGraphicStyle(ids[1]))
        #expect(!index.isUsed(ids[1]))
        // A style arriving after an object that names it: the object enters the index when it does.
        var b = Replica(0xB)
        let bLayer = try LayerFixture.layers(["L"], on: &b)[0]
        let future = OpID(counter: 50, replica: 0xB)
        let early = try #require(try b.perform(CreateTrees([StyleFixture.object(on: bLayer, style: future, key: [0x81])]))).createdNodes[0]
        var bStyles = GraphicStyleResolver(b.state)
        var bIndex = GraphicStyleIndex(b.state, styles: bStyles)
        #expect(!bIndex.isUsed(future))
        var builder = ChangeBuilder(replica: 0xB, startCounter: 50)
        builder.append(Ops.create(parent: GraphicStyleResolver.collection, position: [0x80], props: StyleFixture.props("Late")))
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 0xB
        change.startCounter = 50
        change.ops = builder.ops
        change.seq = 99
        b.receive([change])
        bStyles.update(b.state)
        bIndex.refresh(GraphicStyleIndex.touched(by: change), in: b.state, styles: bStyles)
        #expect(bIndex.objects(using: future) == [early])
        #expect(bIndex == GraphicStyleIndex(b.state, styles: bStyles))
    }

    @Test func theIndexCoversSymbolArtworkOnly() throws {
        var (a, layer) = try F.document()
        let style = try StyleFixture.create([StyleFixture.props("A", fill: 0.1)], on: &a)[0]
        let object = try F.objects([(style, nil, false)], layer: layer, on: &a)[0]
        #expect(GraphicStyleIndex.isIndexed(object, in: a.state))
        #expect(!GraphicStyleIndex.isIndexed(layer, in: a.state), "a layer is not an object")
        #expect(!GraphicStyleIndex.isIndexed(style, in: a.state), "a style is not on a layer")
        var symbol = Wiretuner_Doc_V1_NodeProps()
        symbol.symbol.common.name = "Sym"
        let made = try #require(try a.perform(OpsCommand("Symbol", ops: [Ops.create(parent: WellKnown.symbols, position: [0x80], props: symbol)])))
        let symbolID = made.createdNodes[0]
        let art = try #require(try a.perform(CreateTrees([StyleFixture.object(on: symbolID, style: style, key: [0x80])]))).createdNodes[0]
        #expect(GraphicStyleIndex.isIndexed(art, in: a.state) && !GraphicStyleIndex.isIndexed(symbolID, in: a.state))
        var folder = Wiretuner_Doc_V1_NodeProps()
        folder.symbolFolder.common.name = "F"
        let folderID = try #require(try a.perform(OpsCommand("Folder", ops: [Ops.create(parent: WellKnown.symbols, position: [0x81], props: folder)]))).createdNodes[0]
        let inFolder = try #require(try a.perform(OpsCommand("Sym", ops: [Ops.create(parent: folderID, position: [0x80], props: symbol)]))).createdNodes[0]
        let nested = try #require(try a.perform(CreateTrees([StyleFixture.object(on: inFolder, style: style, key: [0x80])]))).createdNodes[0]
        #expect(GraphicStyleIndex.isIndexed(nested, in: a.state))
        // A symbol node on a layer is walked like a group (as the full read walks it); a node
        // under something that is neither a layer nor a symbol is not indexed.
        let misplaced = try #require(try a.perform(OpsCommand("Sym", ops: [Ops.create(parent: layer, position: [0x90], props: symbol)]))).createdNodes[0]
        let onLayer = try #require(try a.perform(CreateTrees([StyleFixture.object(on: misplaced, style: style, key: [0x80])]))).createdNodes[0]
        #expect(GraphicStyleIndex.isIndexed(onLayer, in: a.state))
        let stray = try #require(try a.perform(CreateTrees([StyleFixture.object(on: style, style: style, key: [0x80])]))).createdNodes[0]
        #expect(!GraphicStyleIndex.isIndexed(stray, in: a.state))
        let index = GraphicStyleIndex(a.state, styles: GraphicStyleResolver(a.state))
        #expect(index.objects(using: style) == [object, art, nested, onLayer].sorted())
        // An object naming a node that is not a style is not indexed under it, but re-read when
        // that node changes.
        var styles = GraphicStyleResolver(a.state)
        var live = index
        let odd = try #require(try a.perform(CreateTrees([StyleFixture.object(on: layer, style: layer, key: [0xA0])])))
        styles.update(a.state)
        live.refresh(GraphicStyleIndex.touched(by: odd), in: a.state, styles: styles)
        let rename = try #require(try a.perform(RenameGraphicStyle(style, to: "Renamed")))
        styles.update(a.state)
        live.refresh(GraphicStyleIndex.touched(by: rename), in: a.state, styles: styles)
        #expect(live == GraphicStyleIndex(a.state, styles: styles) && live.style(of: odd.createdNodes[0]) == nil)
    }
}

extension DocumentDisplayListBuilder {
    /// The scene of `state` built afresh.
    func rebuilding(_ state: EngineState) -> DocumentScene {
        var copy = self
        return copy.rebuild(state)
    }
}
