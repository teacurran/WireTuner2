import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// ATTR-008: brush commands, brush strokes and their drawing.
@Suite struct BrushCommandTests {
    /// A small filled triangle to make a brush from.
    static func motif(_ replica: inout Replica) throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 0.5, blue: 0)]
        return try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (4, 0), (2, 4)]))],
                                                  appearance: appearance), on: &replica)
    }

    /// A line with a basic stroke; its id and the stroke row.
    static func line(_ replica: inout Replica, y: Double = 50) throws -> BrushStrokeRow {
        let node = try LayerFixture.object(PathFixture.open([(0, y), (100, y)]), on: &replica)
        return BrushStrokeRow(node: node, element: AppearanceEditing.rows(node, .strokes, in: replica.state)[0])
    }

    static func stroke(_ row: BrushStrokeRow, _ state: EngineState) -> Wiretuner_Doc_V1_StrokeSettings {
        AppearanceEditing.entries(row.node, in: state).first { $0.row.element == row.element }!.stroke.settings
    }

    static func item(_ node: OpID, _ state: EngineState) -> DisplayItem? {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state).object(node)?.item
    }

    static func brushKind(_ item: DisplayItem?) -> BrushStroke? {
        guard case .path(let path)? = item else { return nil }
        for element in path.appearance.items {
            if case .stroke(let stroke) = element, case .brush(let brush) = stroke.kind { return brush }
        }
        return nil
    }

    @Test func createApplyAndDraw() throws {
        var a = Replica(0xA)
        let motif = try Self.motif(&a)
        let change = try a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))!
        #expect(change.label == "Create Brush")
        let brush = try #require(Brushes.list(a.state).first)
        #expect(brush.name == "Leaves" && brush.symbols.count == 1 && a.state.isLive(motif), "Copy leaves the objects")
        #expect(a.state.props(brush.symbols[0]).symbol.usage == .brushTip)
        #expect(Brushes.isBrush(brush.id, in: a.state) && !Brushes.isBrush(motif, in: a.state))

        let line = try Self.line(&a)
        let apply = try a.perform(ApplyBrush([line], brush: brush.id))!
        #expect(apply.label == "Apply Brush")
        let settings = Self.stroke(line, a.state)
        #expect(settings.kind == .brush && OpID(settings.brush.brush.id) == brush.id && settings.brush.widthPercent == 100 && settings.brush.seed != 0)
        let cached = try Wiretuner_Doc_V1_BasicStroke(serializedBytes: settings.brush.brush.cached)
        #expect(cached.width == 1, "the cached Basic stroke is the stroke as it was")
        // The scene paints the brush's symbol.
        let drawn = try #require(Self.brushKind(Self.item(line.node, a.state)))
        #expect(drawn.brush?.symbols.count == 1 && drawn.brush?.mode == .spray && drawn.seed == settings.brush.seed)
        // Re-applying keeps the seed and width.
        try a.perform(ApplyBrush([line], brush: brush.id))
        #expect(Self.stroke(line, a.state).brush.seed == settings.brush.seed)
        #expect(throws: BrushError.notABrush(motif)) { try a.perform(ApplyBrush([line], brush: motif)) }

        // Convert replaces the objects with an instance of the new symbol.
        let second = try Self.motif(&a)
        try a.perform(CreateBrush([second], source: .convert, name: "Stamps"))
        #expect(!a.state.isEffectivelyLive(second) || Objects.parent(of: second, in: a.state).map { a.state.nodeKind($0) == .symbol } == true)
        #expect(Brushes.list(a.state).map(\.name) == ["Leaves", "Stamps"])
        #expect(throws: BrushError.noSymbols) { try a.perform(CreateBrush([], source: .copy, name: "None")) }

        // Editing a symbol redraws the strokes through the brush.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let master = a.state.liveChildren(brush.symbols[0])[0]
        let move = try a.perform(MoveObjects([master], by: Vector(dx: 1, dy: 0)))!
        let (_, summary) = builder.apply(move, state: a.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(line.node)))
    }

    @Test func editDuplicateAndSeeds() throws {
        var a = Replica(0xA)
        let motif = try Self.motif(&a)
        try a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let brush = Brushes.list(a.state)[0]
        let lines = [try Self.line(&a), try Self.line(&a, y: 80)]
        try a.perform(ApplyBrush(lines, brush: brush.id))

        // Change: every stroke using it follows (the node's registers are written).
        var definition = BrushDefinition(props: brush.props, symbols: brush.symbols)
        definition.props.mode = .paint
        definition.props.count = 3
        definition.props.common.name = ""
        let edit = try a.perform(EditBrush(brush.id, definition: definition))!
        #expect(edit.label == "Edit Brush")
        #expect(Brushes.list(a.state)[0].props.mode == .paint && Brushes.list(a.state)[0].name == "Leaves")
        #expect(Self.brushKind(Self.item(lines[1].node, a.state))?.brush?.mode == .paint)
        // Replacing the symbols.
        let other = try Self.motif(&a)
        try a.perform(CreateBrush([other], source: .copy, name: "Other"))
        let otherSymbol = Brushes.list(a.state)[1].symbols[0]
        try a.perform(EditBrush(brush.id, definition: BrushDefinition(props: definition.props, symbols: [otherSymbol])))
        #expect(Brushes.list(a.state)[0].symbols == [otherSymbol])
        #expect(throws: BrushError.noSymbols) { try a.perform(EditBrush(brush.id, definition: BrushDefinition())) }

        // Create: a copy with the edits for the chosen strokes only.
        definition.props.mode = .spray
        try a.perform(EditBrush(brush.id, definition: BrushDefinition(props: definition.props, symbols: [otherSymbol]), choice: .create(strokes: [lines[0]])))
        let copy = try #require(Brushes.list(a.state).first { $0.name == "Copy of Leaves" })
        #expect(OpID(Self.stroke(lines[0], a.state).brush.brush.id) == copy.id && OpID(Self.stroke(lines[1], a.state).brush.brush.id) == brush.id)

        // Duplicate.
        let duplicate = try a.perform(DuplicateBrush(brush.id))!
        #expect(duplicate.label == "Duplicate Brush" && Brushes.list(a.state).contains { $0.name == "Copy of Leaves-1" })

        // Duplicating a stroke gives the copy a seed of its own.
        let seed = Self.stroke(lines[1], a.state).brush.seed
        try a.perform(DuplicateAppearance(node: lines[1].node, row: lines[1].row))
        let seeds = AppearanceEditing.entries(lines[1].node, in: a.state).filter { $0.row.list == .strokes }.map(\.stroke.settings.brush.seed)
        #expect(seeds.count == 2 && seeds.contains(seed) && Set(seeds).count == 2 && !seeds.contains(0))
    }

    @Test func removeWithDeleteOrRelease() throws {
        var a = Replica(0xA)
        let motif = try Self.motif(&a)
        try a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let brush = Brushes.list(a.state)[0]
        let doomed = try Self.line(&a)
        try a.perform(ApplyBrush([doomed], brush: brush.id))
        let remove = try a.perform(RemoveBrush(brush.id, .delete))!
        #expect(remove.label == "Remove Brush" && !a.state.isLive(doomed.node) && Brushes.list(a.state).isEmpty)
        a.undo()
        #expect(a.state.isLive(doomed.node) && Brushes.list(a.state).count == 1)

        // Release: the object is grouped with its brush strokes baked into paths.
        let before = Self.item(doomed.node, a.state)!
        let copies = RemoveBrush.brushItems(before)
        try a.perform(RemoveBrush(brush.id, .release))
        let group = try #require(Objects.parent(of: doomed.node, in: a.state))
        #expect(a.state.nodeKind(group) == .group && a.state.liveChildren(group).count == 2)
        #expect(!AppearanceEditing.entries(doomed.node, in: a.state).contains { $0.kind == .stroke(.brush) })
        let baked = a.state.liveChildren(group)[1]
        let bakedBounds = try #require(Objects.bounds(of: baked, in: a.state))
        let drawn = copies.compactMap(\.bounds).reduce(Rect.null) { $0.union($1) }
        #expect(!drawn.isNull && abs(bakedBounds.minX - drawn.minX) < 0.5 && abs(bakedBounds.maxX - drawn.maxX) < 0.5
            && abs(bakedBounds.minY - drawn.minY) < 0.5 && abs(bakedBounds.maxY - drawn.maxY) < 0.5, "the released group matches the rendered copies")
        #expect(RemoveBrush.brushItems(.group(GroupItem(children: [before]))).count == 1)
        #expect(throws: BrushError.notABrush(brush.id)) { try a.perform(RemoveBrush(brush.id, .release)) }
    }

    @Test func importAndExportBrushFiles() throws {
        var source = Replica(0xA)
        let motif = try Self.motif(&source)
        try source.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let brush = Brushes.list(source.state)[0]
        let file = try BrushFile.document([brush.id], from: source.state)
        let exported = Brushes.list(file)
        #expect(exported.map(\.name) == ["Leaves"] && exported[0].symbols.count == 1)
        var target = Replica(0xB)
        let change = try target.perform(ImportBrushes(from: file, brushes: [exported[0].id]))!
        #expect(change.label == "Import Brush" && ImportBrushes(from: file, brushes: []).label == "Import Brushes")
        let imported = Brushes.list(target.state)
        #expect(imported.map(\.name) == ["Leaves"] && Symbols.symbols(in: target.state) == imported[0].symbols)
        #expect(throws: BrushError.notABrush(motif)) { try target.perform(ImportBrushes(from: source.state, brushes: [motif])) }
    }

    @Test func brushLoweringDefaults() {
        var props = Wiretuner_Doc_V1_BrushProps()
        props.count = 0
        var angle = Wiretuner_Doc_V1_BrushVariation()
        angle.mode = .flare
        angle.min = 1
        angle.max = 5
        props.angle = angle
        let brush = Brushes.brush(props, symbols: [])
        #expect(brush.mode == .spray && brush.count == 1 && brush.spacing == .fixed(100) && brush.scaling == .fixed(100))
        #expect(brush.angle == BrushVariation(mode: .flare, value: 0, min: 1, max: 5))
        #expect(Brushes.definition(Wiretuner_Doc_V1_NodeRef()) == nil && Brushes.referenced(nil).isEmpty)
    }

    @Test func edgeCases() throws {
        var a = Replica(0xA)
        let motif = try Self.motif(&a)
        try a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let brush = Brushes.list(a.state)[0]
        // Renaming through the sheet, and Create with a name of its own.
        var definition = BrushDefinition(props: brush.props, symbols: brush.symbols)
        definition.props.common.name = "Vines"
        try a.perform(EditBrush(brush.id, definition: definition))
        #expect(Brushes.list(a.state)[0].name == "Vines")
        definition.props.common.name = "Ivy"
        let line = try Self.line(&a)
        try a.perform(ApplyBrush([line], brush: brush.id))
        try a.perform(EditBrush(brush.id, definition: definition, choice: .create(strokes: [line])))
        #expect(Brushes.list(a.state).map(\.name) == ["Vines", "Ivy"])
        // Releasing an unused brush just deletes it.
        let unused = Brushes.list(a.state)[0].id
        let release = try a.perform(RemoveBrush(unused, .release))!
        #expect(release.ops.count == 1 && Brushes.list(a.state).map(\.name) == ["Ivy"])
        // A symbol with no geometry, and a node in the collection that is not a brush.
        let dot = try LayerFixture.object(CreatePath(contours: [NewContour(points: PathFixture.points([(3, 3)]))]), on: &a)
        try a.perform(CreateBrush([dot], source: .copy, name: "Dot"))
        #expect(a.state.props(Brushes.list(a.state).last!.symbols[0]).symbol.origin.x == 0)
        var stray = Wiretuner_Doc_V1_NodeProps()
        stray.group.kind = .group
        try a.perform(OpsCommand("Stray", ops: [Ops.create(parent: BrushFields.collection, position: [0xFE], props: stray)]))
        #expect(Brushes.list(a.state).count == 2)
        #expect(RemoveBrush.brushItems(.fill(FillItem(path: DisplayPath(), paint: .solid(.black)))).isEmpty)
        var angleless = BrushDefinition.defaultProps
        angleless.clearAngle()
        #expect(Brushes.brush(angleless, symbols: []).angle == .fixed(0))
    }

    @Test func releaseInsideTransformedGroupsAndSplitPaths() throws {
        var a = Replica(0xA)
        let motif = try Self.motif(&a)
        try a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let brush = Brushes.list(a.state)[0]
        // An open path with a fill draws one item per attribute.
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let split = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (30, 0), (30, 30)])),
                                                                   NewContour(points: PathFixture.points([(40, 0), (90, 0)]))],
                                                        appearance: appearance), on: &a)
        let row = BrushStrokeRow(node: split, element: AppearanceEditing.rows(split, .strokes, in: a.state)[0])
        try a.perform(ApplyBrush([row], brush: brush.id))
        let group = try a.perform(GroupObjects([split]))!.createdObjects[0]
        try a.perform(MoveObjects([group], by: Vector(dx: 10, dy: 5)))
        // A second user on a hidden layer draws nothing to bake.
        let layers = try LayerFixture.layers(["Hidden"], on: &a)
        let hidden = try LayerFixture.object(CreatePath(contours: [NewContour(points: PathFixture.points([(0, 200), (100, 200)]))], layer: layers[0]), on: &a)
        try a.perform(ApplyBrush([BrushStrokeRow(node: hidden, element: AppearanceEditing.rows(hidden, .strokes, in: a.state)[0])], brush: brush.id))
        try a.perform(SetLayerFlag(layers, .visible, false))
        try a.perform(RemoveBrush(brush.id, .release))
        let wrapper = try #require(Objects.parent(of: split, in: a.state))
        #expect(Objects.parent(of: wrapper, in: a.state) == group && a.state.liveChildren(wrapper).count == 2)
        let baked = a.state.liveChildren(wrapper)[1]
        #expect(Objects.transform(of: baked, in: a.state).tx == -10, "baked copies are mapped back into the group's space")
        #expect(a.state.liveChildren(Objects.parent(of: hidden, in: a.state)!).count == 2)
        // Importing into a document that already has symbols and brushes appends after them.
        var target = Replica(0xB)
        let own = try Self.motif(&target)
        try target.perform(CreateBrush([own], source: .copy, name: "Own"))
        var source = Replica(0xC)
        let theirs = try Self.motif(&source)
        try source.perform(CreateBrush([theirs], source: .copy, name: "Theirs"))
        let sourceBrush = Brushes.list(source.state)[0]
        try target.perform(ImportBrushes(from: source.state, brushes: [sourceBrush.id]))
        #expect(Brushes.list(target.state).map(\.name) == ["Own", "Theirs"])
        // A brush whose symbols are all gone is imported without symbols.
        try source.perform(OpsCommand("Drop symbol", ops: [Ops.setDeleted(sourceBrush.symbols[0])]))
        try target.perform(ImportBrushes(from: source.state, brushes: [sourceBrush.id]))
        #expect(Brushes.list(target.state).last!.symbols.isEmpty)
    }

    // MARK: Merges

    @Test func removeVersusApplyFallsBackToTheCachedStroke() throws {
        var pair = Pair()
        let motif = try Self.motif(&pair.a)
        try pair.a.perform(CreateBrush([motif], source: .copy, name: "Leaves"))
        let line = try Self.line(&pair.b)
        pair.sync()
        let brush = Brushes.list(pair.a.state)[0]
        try pair.a.perform(RemoveBrush(brush.id, .delete))
        try pair.b.perform(ApplyBrush([line], brush: brush.id))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(line.node) && Brushes.list(replica.state).isEmpty)
            let drawn = Self.brushKind(Self.item(line.node, replica.state))
            #expect(drawn != nil && drawn?.brush == nil, "the stroke renders as its cached Basic stroke")
            guard case .path(let path)? = Self.item(line.node, replica.state), case .stroke(let stroke) = path.appearance.items.last else { continue }
            #expect(stroke.style.width == 1 && stroke.paint == .solid(.black))
        }
    }
}
