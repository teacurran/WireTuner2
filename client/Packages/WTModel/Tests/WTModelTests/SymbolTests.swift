import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

enum SymbolFixture {
    /// A filled, stroked rectangle at `x`.
    static func rect(x: Double, name: String? = nil, layer: OpID? = nil) -> CreateShape {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        return CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .translation(x: x, y: 0), appearance: appearance, layer: layer)
    }

    /// Every solid fill colour drawn in `item`, depth first.
    static func fills(_ item: DisplayItem?) -> [Color] {
        switch item {
        case .path(let path)?:
            return path.appearance.items.compactMap { if case .fill(let fill) = $0 { return fill.paint.color } else { return nil } }
        case .group(let group)?:
            return group.children.flatMap { fills($0) }
        default:
            return []
        }
    }

    static func red() -> Wiretuner_Doc_V1_ColorRef { Appearances.inline(red: 1, green: 0, blue: 0) }

    /// Two rectangles converted to a symbol; returns (symbol, instance, the two master nodes).
    static func converted(on replica: inout Replica) throws -> (symbol: OpID, instance: OpID, masters: [OpID]) {
        let first = try replica.perform(rect(x: 0))!.createdObjects[0]
        let second = try replica.perform(rect(x: 20))!.createdObjects[0]
        let change = try replica.perform(ConvertToSymbol([first, second]))!
        let created = change.createdNodes
        return (created[0], created[1], [first, second])
    }
}

@Suite struct SymbolCommandTests {
    @Test func convertPlaceAndRender() throws {
        var a = Replica(0xA)
        let before = try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]
        let original = try #require(Objects.bounds(of: before, in: a.state))
        a.undo()
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        #expect(a.state.nodeKind(symbol) == .symbol && Objects.parent(of: symbol, in: a.state) == WellKnown.symbols)
        #expect(a.state.liveChildren(symbol) == masters)
        #expect(a.state.props(symbol).symbol.common.name == "Symbol 1")
        #expect(a.state.props(symbol).symbol.origin.x == 15 && a.state.props(symbol).symbol.origin.y == 5)
        #expect(Symbols.symbols(in: a.state) == [symbol])
        #expect(Symbols.instanceIndex(in: a.state) == [symbol: [instance]])
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let object = try #require(scene.object(instance))
        #expect(object.kind == .instance && scene.topLevel == [NodeID(instance)])
        guard case .group(let group) = object.item else { Issue.record("an instance draws as a group"); return }
        #expect(group.atomic && group.children.count == 2)
        #expect(Objects.bounds(of: instance, in: a.state) == Rect(x: 0, y: 0, width: 30, height: 10))
        #expect(object.bounds.map { $0.contains(original) } == true)
        // Place another at (100, 100): the origin lands there.
        let placed = try a.perform(PlaceInstance(symbol, at: Point(x: 100, y: 100)))!.createdObjects[0]
        #expect(Objects.bounds(of: placed, in: a.state) == Rect(x: 85, y: 95, width: 30, height: 10))
        #expect(Symbols.instanceIndex(in: a.state)[symbol] == [instance, placed])
        // A second conversion takes the next free name; a single named object gives its name.
        let named = try a.perform(SymbolFixture.rect(x: 50))!.createdObjects[0]
        var name = Wiretuner_Doc_V1_NodeProps()
        name.rect.common.name = "Badge"
        try a.perform(OpsCommand("Name", ops: [Ops.set(named, [CommonFields.name(.rect)], values: name)]))
        let badge = try a.perform(ConvertToSymbol([named]))!.createdNodes[0]
        #expect(a.state.props(badge).symbol.common.name == "Badge")
        let plain = try a.perform(SymbolFixture.rect(x: 70))!.createdObjects[0]
        let third = try a.perform(ConvertToSymbol([plain], name: nil))!.createdNodes[0]
        #expect(a.state.props(third).symbol.common.name == "Symbol 2")
        // Undo puts the objects back.
        a.undo()
        #expect(Objects.parent(of: plain, in: a.state) != third && !a.state.isLive(third))
        #expect(try a.perform(ConvertToSymbol([])) == nil)
    }

    @Test func convertingAcrossLayersPlacesTheInstanceOnTheActiveLayer() throws {
        var a = Replica(0xA)
        let ids = try LayerFixture.layers(["One", "Two"], on: &a)
        let first = try a.perform(SymbolFixture.rect(x: 0, layer: ids[0]))!.createdObjects[0]
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.common.transform = PathEditing.proto(.translation(x: 5, y: 0))
        let holder = try a.perform(OpsCommand("Group", ops: [Ops.create(parent: ids[1], position: [0x80], props: group)]))!.createdNodes[0]
        let second = try a.perform(OpsCommand("Member", ops: [Ops.create(parent: holder, position: [0x80], props: ShapeFixture.rect())]))!.createdNodes[0]
        let change = try #require(try a.perform(ConvertToSymbol([first, second, holder], layer: ids[0])))
        let symbol = change.createdNodes[0]
        let instance = change.createdNodes[1]
        #expect(a.state.liveChildren(symbol) == [first, holder], "a member whose group is converted goes with its group")
        #expect(Objects.parent(of: instance, in: a.state) == ids[0])
        #expect(a.state.props(holder).group.common.transform.tx == 5)
        // Inside a transformed group the instance takes the members' place, compensating for the
        // group's transform.
        let members = try [0x40, 0x90].map { key in
            try a.perform(OpsCommand("Member", ops: [Ops.create(parent: holder, position: [UInt8(key)], props: ShapeFixture.rect())]))!.createdNodes[0]
        }
        try a.perform(SetTransforms([(members[1], .translation(x: 20, y: 0))]))
        let union = Objects.bounds(of: members[0], in: a.state)!.union(Objects.bounds(of: members[1], in: a.state)!)
        let inGroup = try #require(try a.perform(ConvertToSymbol(members)))
        #expect(Objects.parent(of: inGroup.createdNodes[1], in: a.state) == holder)
        #expect(Objects.bounds(of: inGroup.createdNodes[1], in: a.state) == union)
        #expect(a.state.props(members[1]).rect.common.transform.tx == 25, "masters are flattened into symbol space")
    }

    @Test func aMasterEditRepaintsEveryInstanceAndNothingElse() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        let second = try a.perform(PlaceInstance(symbol, at: Point(x: 100, y: 100)))!.createdObjects[0]
        let unrelated = try a.perform(SymbolFixture.rect(x: 300))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let before = builder.rebuild(a.state)
        #expect(builder.dependencies.directDependents(of: NodeID(symbol)) == [NodeID(instance), NodeID(second)])
        #expect(builder.library.symbols[NodeID(symbol)]?.nodes.count == 2)
        let change = try #require(try a.perform(SetTransforms([(masters[0], .translation(x: 0, y: 30))])))
        let (after, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.isSuperset(of: [NodeID(instance), NodeID(second)]) && !summary.touchedNodes.contains(NodeID(unrelated)))
        #expect(after.object(instance)?.bounds != before.object(instance)?.bounds)
        #expect(after.object(unrelated)?.item == before.object(unrelated)?.item)
        // A new master node reaches the instances through its symbol.
        let added = try #require(try a.perform(OpsCommand("Add", ops: [Ops.create(parent: symbol, position: [0xF0], props: ShapeFixture.rect())])))
        let (grown, addSummary) = builder.apply(added, state: a.state, origin: .remote)
        #expect(addSummary.touchedNodes.contains(NodeID(second)))
        guard case .group(let group)? = grown.object(second)?.item else { Issue.record("group"); return }
        #expect(group.children.count == 3)
    }

    @Test func overridesRecolorHideAndReset() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        let other = try a.perform(PlaceInstance(symbol, at: Point(x: 100, y: 100)))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let fill = SetOverride([instance], master: masters[0], value: .fill(SymbolFixture.red()), in: a.state)
        #expect(fill.label == "Override fill")
        let change = try #require(try a.perform(fill))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        #expect(SymbolFixture.fills(scene.object(instance)?.item) == [Color(red: 1, green: 0, blue: 0), Color(red: 0, green: 0, blue: 1)])
        #expect(SymbolFixture.fills(scene.object(other)?.item) == [Color(red: 0, green: 0, blue: 1), Color(red: 0, green: 0, blue: 1)])
        #expect(summary.touchedNodes == [NodeID(instance)], "an override edit repaints only its instance")
        // Editing it again writes the register of the same element.
        let again = try #require(try a.perform(SetOverride([instance], master: masters[0], value: .fill(Appearances.inline(red: 0, green: 1, blue: 0)), in: a.state)))
        #expect(again.ops.count == 1 && again.ops[0].set.paths.count == 1)
        #expect(a.state.props(instance).instance.overrides.count == 1)
        #expect(Symbols.liveOverrides(of: instance, in: a.state).count == 1)
        // Stroke, hidden (labelled with the part's name) and image overrides.
        try a.perform(SetOverride([instance], master: masters[1], value: .stroke(SymbolFixture.red()), in: a.state))
        let hide = SetOverride([instance, other], master: masters[1], value: .hidden(true), in: a.state)
        #expect(hide.label == "Hide rect")
        try a.perform(hide)
        #expect(SetOverride([instance], master: masters[1], value: .hidden(false), in: a.state).label == "Show rect")
        let hidden = builder.rebuild(a.state)
        #expect(SymbolFixture.fills(hidden.object(other)?.item).count == 1)
        #expect(throws: SymbolError.notOverridable(masters[0])) {
            try a.perform(SetOverride([instance], master: masters[0], value: .image(OpID(counter: 1, replica: 1)), in: a.state))
        }
        #expect(throws: SymbolError.notOverridable(symbol)) { try a.perform(SetOverride([instance], master: symbol, value: .hidden(true), in: a.state)) }
        #expect(throws: SymbolError.notAnInstance(masters[0])) { try a.perform(SetOverride([masters[0]], master: masters[0], value: .hidden(true), in: a.state)) }
        // Reset one, then all.
        let reset = ResetOverrides([instance], key: OverrideKey(master: masters[1], property: .hidden))
        #expect(reset.label == "Reset override")
        try a.perform(reset)
        #expect(Symbols.liveOverrides(of: instance, in: a.state).keys.map(\.property).sorted { $0.rawValue < $1.rawValue } == [.fill, .stroke])
        let all = ResetOverrides([instance, other])
        #expect(all.label == "Reset all overrides")
        try a.perform(all)
        #expect(Symbols.liveOverrides(of: instance, in: a.state).isEmpty && Symbols.liveOverrides(of: other, in: a.state).isEmpty)
        #expect(try a.perform(ResetOverrides([instance])) == nil)
        a.undo()
        #expect(Symbols.liveOverrides(of: other, in: a.state).count == 1, "undo brings the overrides back")
    }

    @Test func overrideReadTimeRules() throws {
        var pair = Pair()
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &pair.a)
        pair.sync()
        // Concurrent creation of one override: the greater element id wins on both replicas.
        try pair.a.perform(SetOverride([instance], master: masters[0], value: .fill(SymbolFixture.red()), in: pair.a.state))
        try pair.b.perform(SetOverride([instance], master: masters[0], value: .fill(Appearances.inline(red: 0, green: 1, blue: 0)), in: pair.b.state))
        pair.sync()
        #expect(pair.a.state.props(instance).instance.overrides.count == 2)
        let winnerA = Symbols.liveOverrides(of: instance, in: pair.a.state)[OverrideKey(master: masters[0], property: .fill)]
        let winnerB = Symbols.liveOverrides(of: instance, in: pair.b.state)[OverrideKey(master: masters[0], property: .fill)]
        #expect(winnerA == winnerB && winnerA != nil)
        let ids = pair.a.state.props(instance).instance.overrides.compactMap { OpID(element: $0.id) }
        #expect(winnerA.flatMap { OpID(element: $0.id) } == ids.max())
        // A deleted master node's override reads as nothing and comes back with the node.
        try pair.a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(masters[0])]))
        #expect(Symbols.liveOverrides(of: instance, in: pair.a.state).isEmpty)
        pair.a.undo()
        #expect(Symbols.liveOverrides(of: instance, in: pair.a.state).count == 1)
        // Unspecified property and an instance of no symbol contribute nothing.
        var odd = Wiretuner_Doc_V1_NodeProps()
        var element = Wiretuner_Doc_V1_Override()
        element.masterNode = masters[1].proto
        odd.instance.overrides = [element]
        try pair.a.perform(OpsCommand("Odd", ops: [Ops.elementInsert(instance, SymbolFields.overrides, positions: [[0x01]], values: odd)]))
        #expect(Symbols.liveOverrides(of: instance, in: pair.a.state).count == 1)
        #expect(Symbols.fits(.text, pair.a.state.props(masters[0])) == false && Symbols.fits(.fill, pair.a.state.props(masters[0])))
        _ = symbol
    }

    @Test func releaseBakesTheResolvedArtworkInPlace() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        let placed = try a.perform(PlaceInstance(symbol, at: Point(x: 115, y: 5)))!.createdObjects[0]
        try a.perform(SetOverride([placed], master: masters[0], value: .fill(SymbolFixture.red()), in: a.state))
        try a.perform(SetOverride([placed], master: masters[1], value: .hidden(true), in: a.state))
        try a.perform(SetOverride([placed], master: masters[0], value: .stroke(SymbolFixture.red()), in: a.state))
        let change = try #require(try a.perform(ReleaseInstances([placed], label: "Detach instance")))
        #expect(change.label == "Detach instance")
        #expect(!a.state.isLive(placed))
        let group = change.createdNodes[0]
        let copies = a.state.liveChildren(group)
        #expect(a.state.nodeKind(group) == .group && copies.count == 1, "the hidden part is left out")
        #expect(Objects.bounds(of: copies[0], in: a.state) == Rect(x: 100, y: 0, width: 10, height: 10))
        let copy = a.state.props(copies[0]).rect.appearance
        #expect(copy.fills.first?.settings.basic.color == SymbolFixture.red())
        #expect(copy.strokes.first?.settings.basic.color == SymbolFixture.red())
        #expect(a.state.props(masters[0]).rect.appearance.fills.first?.settings.basic.color != SymbolFixture.red(), "the symbol is untouched")
        a.undo()
        #expect(a.state.isLive(placed) && !a.state.isLive(group))
        #expect(ReleaseInstances([instance]).label == "Release Instance")
        // An instance of a removed symbol is left alone.
        try a.perform(OpsCommand("Remove", ops: [Ops.setDeleted(symbol)]))
        #expect(try a.perform(ReleaseInstances([instance])) == nil)
    }

    @Test func swapSetsOverridesAsideAndPlaceholdersStandIn() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        let circle = try a.perform(CreateShape(.ellipse, size: Size(width: 8, height: 8)))!.createdObjects[0]
        let second = try a.perform(ConvertToSymbol([circle], name: "Dot"))!.createdNodes[0]
        try a.perform(SetOverride([instance], master: masters[0], value: .fill(SymbolFixture.red()), in: a.state))
        let swap = try #require(try a.perform(SwapSymbol([instance], to: second)))
        #expect(swap.label == "Swap Symbol")
        #expect(Symbols.symbol(of: instance, in: a.state) == second && Symbols.liveOverrides(of: instance, in: a.state).isEmpty)
        try a.perform(SwapSymbol([instance], to: symbol))
        #expect(Symbols.liveOverrides(of: instance, in: a.state).count == 1, "swapping back restores them")
        #expect(throws: SymbolError.notASymbol(masters[0])) { try a.perform(SwapSymbol([instance], to: masters[0])) }
        #expect(throws: SymbolError.notASymbol(masters[0])) { try a.perform(PlaceInstance(masters[0], at: .zero)) }
        #expect(throws: ObjectEditError.invalidValue("point")) { try a.perform(PlaceInstance(symbol, at: Point(x: .nan, y: 0))) }
        // A removed symbol: the placeholder with the symbol's name; a non-symbol: "not a symbol".
        var builder = DocumentDisplayListBuilder(canvas: "c")
        try a.perform(OpsCommand("Remove", ops: [Ops.setDeleted(symbol)]))
        let spec = Symbols.instanceSpec(instance, transform: .identity, in: a.state)
        #expect(spec.symbol == nil && spec.placeholderName == "Symbol 1" && spec.overrides.isEmpty)
        #expect(Objects.bounds(of: instance, in: a.state) == nil)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.instance.symbol.id = circle.proto
        let odd = try a.perform(OpsCommand("Odd", ops: [Ops.create(parent: Objects.parent(of: instance, in: a.state)!, position: [0xF0], props: props)]))!.createdNodes[0]
        #expect(Symbols.instanceSpec(odd, transform: .identity, in: a.state).placeholderName == "not a symbol")
        let empty = try a.perform(OpsCommand("Empty", ops: [Ops.create(parent: Objects.parent(of: instance, in: a.state)!, position: [0xF1],
                                                                          props: { var p = Wiretuner_Doc_V1_NodeProps(); p.instance = .init(); return p }())]))!.createdNodes[0]
        #expect(Symbols.instanceSpec(empty, transform: .identity, in: a.state).symbol == nil)
        #expect(Symbols.symbol(of: empty, in: a.state) == nil && Symbols.liveOverrides(of: empty, in: a.state).isEmpty)
        let scene = builder.rebuild(a.state)
        #expect(scene.object(instance) != nil && scene.object(odd) != nil && scene.object(empty) != nil, "placeholders are drawn")
        // Restoring the symbol reconnects the instance (it depends on the symbol id while dangling).
        #expect(builder.dependencies.directDependents(of: NodeID(symbol)).contains(NodeID(instance)))
        let restore = try #require(try a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(symbol, false)])))
        let (restored, summary) = builder.apply(restore, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.contains(NodeID(instance)))
        guard case .group(let group)? = restored.object(instance)?.item else { Issue.record("group"); return }
        #expect(group.children.count == 2)
    }

    @Test func nestedInstancesReachTheirHosts() throws {
        var a = Replica(0xA)
        let (inner, _, masters) = try SymbolFixture.converted(on: &a)
        // A symbol whose artwork holds an instance of the first, placed on the canvas.
        let nested = try a.perform(PlaceInstance(inner, at: Point(x: 0, y: 50)))!.createdObjects[0]
        let outer = try a.perform(ConvertToSymbol([nested], name: "Outer"))!
        let host = outer.createdNodes[1]
        var folder = Wiretuner_Doc_V1_NodeProps()
        folder.symbolFolder.common.name = "Folder"
        let created = try a.perform(OpsCommand("Folder", ops: [Ops.create(parent: WellKnown.symbols, position: [0x01], props: folder)]))!.createdNodes[0]
        try a.perform(OpsCommand("Move", ops: [Ops.move(outer.createdNodes[0], parent: created, position: [0x80])]))
        #expect(Symbols.symbols(in: a.state) == [inner, outer.createdNodes[0]])
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let change = try #require(try a.perform(SetTransforms([(masters[1], .translation(x: 20, y: 40))])))
        let (_, summary) = builder.apply(change, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.contains(NodeID(host)), "an edit two symbols down repaints the host")
        #expect(Objects.bounds(of: host, in: a.state) != nil)
    }

    @Test func everyOverrideKindReachesTheRendererAndRelease() throws {
        var a = Replica(0xA)
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &a)
        func child(_ parent: OpID, _ key: UInt8, _ build: (inout Wiretuner_Doc_V1_NodeProps) -> Void) throws -> OpID {
            var props = Wiretuner_Doc_V1_NodeProps()
            build(&props)
            return try a.perform(OpsCommand("Add", ops: [Ops.create(parent: parent, position: [key], props: props)]))!.createdNodes[0]
        }
        let group = try child(symbol, 0xE0) { $0.group.common.transform = PathEditing.proto(.translation(x: 5, y: 0)) }
        let member = try a.perform(OpsCommand("Member", ops: [Ops.create(parent: group, position: [0x80], props: ShapeFixture.rect())]))!.createdNodes[0]
        let text = try child(symbol, 0xE1) { $0.text = .init() }
        let image = try child(symbol, 0xE2) { $0.image = .init() }
        _ = try child(symbol, 0xE3) { $0.chart = .init() }
        let asset = try child(OpID.wellKnown(9), 0x80) { $0.asset.sha256 = Data(repeating: 0x0A, count: 32) }
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let artwork = try #require(builder.library.symbols[NodeID(symbol)])
        #expect(artwork.nodes.map(\.id) == [masters[0], masters[1], group].map(NodeID.init), "text, image and an empty chart draw nothing yet")
        guard case .group(_, let members)? = artwork.nodes.last?.content, case .item(let placed)? = members.first?.content else {
            Issue.record("the group's member"); return
        }
        #expect(placed.bounds?.minX == 5, "a member is flattened through its group")
        #expect(scene.object(instance) != nil)
        // Every kind, set twice where the register path differs from the first write.
        var none = Wiretuner_Doc_V1_ColorRef()
        none.none = true
        try a.perform(SetOverride([instance], master: masters[0], value: .fill(none), in: a.state))
        try a.perform(SetOverride([instance], master: masters[0], value: .stroke(none), in: a.state))
        try a.perform(SetOverride([instance], master: masters[0], value: .stroke(none), in: a.state))
        try a.perform(SetOverride([instance], master: group, value: .hidden(false), in: a.state))
        try a.perform(SetOverride([instance], master: group, value: .hidden(false), in: a.state))
        try a.perform(SetOverride([instance], master: group, value: .fill(SymbolFixture.red()), in: a.state))
        try a.perform(SetOverride([instance], master: image, value: .image(asset), in: a.state))
        try a.perform(SetOverride([instance], master: image, value: .image(asset), in: a.state))
        try a.perform(SetOverride([instance], master: text, value: .fill(SymbolFixture.red()), in: a.state))
        #expect(SetOverride([instance], master: text, value: .hidden(true), in: a.state).label == "Hide text")
        var textOverride = Wiretuner_Doc_V1_NodeProps()
        var element = Wiretuner_Doc_V1_Override()
        element.masterNode = text.proto
        element.property = .text
        textOverride.instance.overrides = [element]
        try a.perform(OpsCommand("Text", ops: [Ops.elementInsert(instance, SymbolFields.overrides, positions: [[0xF0]], values: textOverride)]))
        #expect(Symbols.liveOverrides(of: instance, in: a.state).count == 7)
        let rendered = Symbols.renderOverrides(of: instance, in: a.state)
        #expect(rendered.contains(.fill(NodeID(masters[0]), .clear)) && rendered.contains(.stroke(NodeID(masters[0]), .clear)))
        #expect(rendered.contains(.image(NodeID(image), assetID: String(repeating: "0a", count: 32))))
        #expect(rendered.contains(.fill(NodeID(text), Color(red: 1, green: 0, blue: 0))))
        #expect(!rendered.contains { if case .text = $0 { true } else { false } }, "text overrides wait for text layout")
        #expect(!rendered.contains(.hidden(NodeID(group))), "Visible ticked hides nothing")
        // A deleted asset: the master's own image.
        try a.perform(OpsCommand("Remove asset", ops: [Ops.setDeleted(asset)]))
        #expect(!Symbols.renderOverrides(of: instance, in: a.state).contains { if case .image = $0 { true } else { false } })
        // Release copies the group with its member recoloured and leaves the text alone.
        let released = try #require(try a.perform(ReleaseInstances([instance])))
        let copies = a.state.liveChildren(released.createdNodes[0])
        #expect(copies.count == 6)
        let copiedGroup = try #require(copies.first { a.state.nodeKind($0) == .group })
        #expect(a.state.liveChildren(copiedGroup).count == 1)
        #expect(a.state.props(copiedGroup).group.appearance.fills.isEmpty)
        _ = member
    }

    @Test func edgeCasesOfPlaceholdersAndEmptySymbols() throws {
        var a = Replica(0xA)
        // An empty group converts with its origin at zero; its symbol has no bounds.
        let layer = try LayerFixture.layers(["Only"], on: &a)[0]
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group = .init()
        let empty = try a.perform(OpsCommand("Group", ops: [Ops.create(parent: layer, position: [0x80], props: group)]))!.createdNodes[0]
        let change = try #require(try a.perform(ConvertToSymbol([empty])))
        #expect(a.state.props(change.createdNodes[0]).symbol.origin == Wiretuner_Doc_V1_Point())
        #expect(Objects.bounds(of: change.createdNodes[1], in: a.state) == nil)
        // An instance naming a node that does not exist shows a placeholder with no name.
        var props = Wiretuner_Doc_V1_NodeProps()
        props.instance.symbol.id = OpID(counter: 999, replica: 99).proto
        let lost = try a.perform(OpsCommand("Lost", ops: [Ops.create(parent: layer, position: [0x90], props: props)]))!.createdNodes[0]
        #expect(Symbols.instanceSpec(lost, transform: .identity, in: a.state).placeholderName == "")
    }

    @Test func nodeTreesKnowTheNewKinds() {
        for kind in [NodeKind.chart, .symbol, .instance, .barcode] {
            var tree = NodeTree(props: NodeValues.common(kind: kind) { $0.name = "n" })
            #expect(tree.kind == kind)
            tree.transform = .translation(x: 3, y: 0)
            #expect(tree.transform == .translation(x: 3, y: 0))
            tree.transform = .identity
            #expect(NodeValues.common(tree.props)?.hasTransform == false)
        }
    }
}
