import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto
import WTRender

/// The merge cases of swatches.adoc, tints.adoc and spot-process.adoc through two in-process
/// replicas (COLOR-003/004/005/009), the resolver's fallback ladder (COLOR-006's WTModel half),
/// and the swatch index kept from changes applied in any order.
@Suite struct SwatchMergeTests {
    /// Two replicas sharing the defaults and the swatches `setup` adds on A.
    static func pair(_ setup: (inout Replica) throws -> Void = { _ in }) throws -> Pair {
        var pair = Pair()
        try pair.a.perform(CreateDefaultSwatches())
        try setup(&pair.a)
        pair.sync()
        return pair
    }

    static func converged(_ pair: Pair) -> SwatchList {
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let a = SwatchList(pair.a.state)
        #expect(a.swatches == SwatchList(pair.b.state).swatches)
        return a
    }

    static func later(_ a: Wiretuner_Doc_V1_Change, _ b: Wiretuner_Doc_V1_Change) -> Bool {
        OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
    }

    @Test func renameVersusRecolorKeepsBoth() throws {
        var grape = OpID.zero
        var pair = try Self.pair { grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape") }
        try pair.a.perform(RenameSwatch(grape, to: "Plum"))
        try pair.b.perform(RedefineSwatch(grape, to: ColorFixture.red))
        pair.sync()
        let swatch = Self.converged(pair)[grape]!
        #expect(swatch.name == "Plum" && swatch.color == ColorFixture.red)
    }

    @Test func recolorVersusRecolorConvergesOnTheGreaterOpID() throws {
        var grape = OpID.zero
        var pair = try Self.pair { grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape") }
        let a = try pair.a.perform(RedefineSwatch(grape, to: ColorFixture.red))!
        let b = try pair.b.perform(RedefineSwatch(grape, to: ColorFixture.plum))!
        pair.sync()
        #expect(Self.converged(pair)[grape]!.color == (Self.later(a, b) ? ColorFixture.red : ColorFixture.plum))
        #expect(pair.a.state.store.losingWrites(grape, SwatchFields.value).count == 2)
    }

    @Test func deleteVersusUseLeavesTheObjectLookingTheSame() throws {
        var grape = OpID.zero
        var shape = OpID.zero
        var pair = try Self.pair {
            grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape")
            shape = try ColorFixture.shape(&$0, fill: ColorResolver.inline(.white))
        }
        try pair.a.perform(RemoveSwatches([grape]))
        let ref = SwatchList(pair.b.state).resolver.reference(to: grape)
        try pair.b.perform(SetAppearanceColor([(shape, ColorFixture.fillRow(shape, pair.b.state))], color: ref))
        let before = SwatchList(pair.b.state).resolver.color(ColorFixture.fill(shape, pair.b.state))
        pair.sync()
        let list = Self.converged(pair)
        #expect(list[grape] == nil)
        for replica in [pair.a, pair.b] {
            let resolver = ColorResolver(replica.state)
            let fill = ColorFixture.fill(shape, replica.state)
            #expect(resolver.isDangling(fill))
            #expect(resolver.color(fill) == before)
        }
        // Restoring re-links the object with no write on it.
        try pair.a.perform(RestoreSwatches([grape]))
        #expect(!ColorResolver(pair.a.state).isDangling(ColorFixture.fill(shape, pair.a.state)))
    }

    @Test func concurrentNameAllColorsConvergesWithDuplicates() throws {
        var pair = try Self.pair { replica in
            try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.red))
            try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.plum))
        }
        try pair.a.perform(NameAllColors())
        try pair.b.perform(NameAllColors())
        pair.sync()
        let list = Self.converged(pair)
        let names = list.swatches.map(\.name)
        #expect(names.contains("230r 57g 70b") && names.contains("230r 57g 70b (2)"))
        #expect(list.named("230r 57g 70b")!.id < list.swatches.first { $0.name == "230r 57g 70b (2)" }!.id)
    }

    @Test func concurrentSortsProduceIdenticalSortedPositions() throws {
        var pair = try Self.pair { replica in
            for name in ["delta", "alpha", "charlie", "bravo"] {
                try ColorFixture.add(&replica, ColorFixture.grape, name: name)
            }
        }
        try pair.a.perform(SortSwatches())
        try pair.b.perform(SortSwatches())
        pair.sync()
        let list = Self.converged(pair)
        #expect(list.swatches.map(\.name) == ["White", "Black", "Registration", "alpha", "bravo", "charlie", "delta"])
        for swatch in list.swatches {
            #expect(pair.a.state.store.placement(swatch.id)?.position == pair.b.state.store.placement(swatch.id)?.position)
        }
    }

    @Test func sortVersusDragAndSortVersusAddConverge() throws {
        var ids: [OpID] = []
        var pair = try Self.pair { replica in
            for name in ["c", "a", "b"] {
                ids.append(try ColorFixture.add(&replica, ColorFixture.grape, name: name))
            }
        }
        try pair.a.perform(SortSwatches())
        try pair.b.perform(MoveSwatches([ids[0]], after: nil))
        let added = try ColorFixture.add(&pair.b, ColorFixture.plum, name: "z")
        pair.sync()
        let list = Self.converged(pair)
        #expect(list[added] != nil)
        #expect(Set(list.swatches.map(\.name)) == ["White", "Black", "Registration", "a", "b", "c", "z"])
        try pair.a.perform(SortSwatches())
        pair.sync()
        #expect(Self.converged(pair).swatches.map(\.name) == ["White", "Black", "Registration", "a", "b", "c", "z"])
    }

    @Test func spotVersusProcessAndConversionsConverge() throws {
        var grape = OpID.zero
        var pair = try Self.pair { grape = try ColorFixture.add(&$0, ColorFixture.grape, name: "Grape") }
        // Make Spot on A while B (seeing it spot) makes it process.
        let a = try pair.a.perform(SetSwatchSpot([grape], spot: true))!
        let b = try pair.b.perform(OpsCommand("Make Process", ops: [Ops.set(grape, [SwatchFields.spot], values: SwatchFields.values { $0.spot = false })]))!
        pair.sync()
        #expect(Self.converged(pair)[grape]!.isSpot == Self.later(a, b))
        // Convert to CMYK (already) vs recolor, then sRGB vs P3 on one swatch.
        try pair.a.perform(RedefineSwatch(grape, to: ColorFixture.red))
        pair.sync()
        let toP3 = try pair.a.perform(ConvertSwatchSpace([grape], to: .displayP3))!
        let toCMYK = try pair.b.perform(ConvertSwatchSpace([grape], to: .cmyk))!
        pair.sync()
        let space = Self.converged(pair)[grape]!.value.space
        #expect(space == (Self.later(toP3, toCMYK) ? .displayP3 : .cmyk))
        #expect(pair.a.state.store.losingWrites(grape, SwatchFields.value).isEmpty == false)
    }

    @Test func tintPercentRebaseAndRemovedBaseConverge() throws {
        var grape = OpID.zero
        var plum = OpID.zero
        var tint = OpID.zero
        var pair = try Self.pair { replica in
            grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
            plum = try ColorFixture.add(&replica, ColorFixture.plum, name: "Plum")
            tint = try ColorFixture.tint(&replica, of: grape, 40)
        }
        try pair.a.perform(SetTintPercent(tint, percent: 20))
        try pair.b.perform(SetTintPercent(tint, percent: 60))
        pair.sync()
        _ = Self.converged(pair)
        try pair.a.perform(RebaseTint(tint, onto: plum))
        try pair.b.perform(RebaseTint(tint, onto: grape))
        pair.sync()
        _ = Self.converged(pair)
        // Remove the base on A while B makes a new tint of it: the tint stays live, rendering its cache.
        try pair.a.perform(RemoveSwatches([grape]))
        let late = try ColorFixture.tint(&pair.b, of: grape, 30)
        let expected = SwatchList(pair.b.state)[late]!.color
        pair.sync()
        let list = Self.converged(pair)
        let swatch = try #require(list[late])
        #expect(swatch.baseRemoved && swatch.depth == 0 && close(swatch.color, expected.withSpot(nil), 1e-9))
        #expect(swatch.name == "30% Grape")
    }

    @Test func twoTintsRebasedOntoEachOtherAreCutAtTheSmallerID() throws {
        var grape = OpID.zero
        var first = OpID.zero
        var second = OpID.zero
        var pair = try Self.pair { replica in
            grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
            first = try ColorFixture.tint(&replica, of: grape, 50)
            second = try ColorFixture.tint(&replica, of: grape, 50)
        }
        try pair.a.perform(RebaseTint(first, onto: second))
        try pair.b.perform(RebaseTint(second, onto: first))
        pair.sync()
        let list = Self.converged(pair)
        let cut = min(first, second)
        // The cut link reads its cached base (Grape at the time of the re-base: Grape's 50% tint for
        // the link onto the other tint).
        let resolver = list.resolver
        #expect(resolver.chain(cut).cut)
        #expect(list[first] != nil && list[second] != nil)
        #expect(close(resolver.color(ofSwatch: cut), ColorFixture.grape.tinted(0.5).tinted(0.5), 1e-9))
        #expect(close(resolver.color(ofSwatch: max(first, second)), ColorFixture.grape.tinted(0.5).tinted(0.5).tinted(0.5), 1e-9))
        // A tint of a looped tint lists under it.
        let outer = try ColorFixture.tint(&pair.a, of: first, 50)
        let looped = SwatchList(pair.a.state)
        #expect(looped[outer]?.depth == 1 && looped[first]?.depth == 0 && looped[second]?.depth == 0)
    }

    @Test func resolverLadder() throws {
        var replica = try SwatchTests.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape", spot: true)
        let t1 = try ColorFixture.tint(&replica, of: grape, 50)
        let t2 = try ColorFixture.tint(&replica, of: t1, 50)
        let t3 = try ColorFixture.tint(&replica, of: t2, 50)
        var resolver = ColorResolver(replica.state)
        let ink = SpotInk(swatch: NodeID(grape), name: "Grape")
        #expect(close(resolver.color(ofSwatch: t3), ColorFixture.grape.asSpot(ink).tinted(0.125), 1e-12))
        #expect(resolver.chain(t3) == ColorResolver.Chain(base: grape, amount: 0.125, depth: 3, dangling: false, cut: false))
        #expect(resolver.swatch(role: .unspecified) == nil)
        // References: none, unset, inline, swatch, unnamed tint.
        #expect(resolver.color(ColorResolver.none) == nil && resolver.color(Wiretuner_Doc_V1_ColorRef()) == nil)
        #expect(resolver.color(ColorResolver.inline(ColorFixture.red)) == ColorFixture.red)
        #expect(close(resolver.color(resolver.tint(of: t1, percent: 50)), ColorFixture.grape.asSpot(ink).tinted(0.25), 1e-12))
        // A dangling reference reads its cache; with no cache, black.
        var dangling = Wiretuner_Doc_V1_ColorRef()
        dangling.swatch.id = OpID(counter: 999, replica: 9).proto
        #expect(resolver.color(dangling) == .black)
        dangling.swatch.cached = ColorValues.cached(ColorFixture.red)
        #expect(resolver.color(dangling) == ColorFixture.red && resolver.isDangling(dangling))
        var danglingTint = Wiretuner_Doc_V1_ColorRef()
        danglingTint.tint.base.id = OpID(counter: 999, replica: 9).proto
        danglingTint.tint.percent = 0
        #expect(resolver.color(danglingTint) == .black && resolver.isDangling(danglingTint))
        #expect(!resolver.isDangling(ColorResolver.none))
        #expect(ColorResolver.swatch(of: ColorResolver.none) == nil)
        // A tint of a deleted base reads the cached base scaled.
        try replica.perform(RemoveSwatches([grape]))
        try replica.perform(RestoreSwatches([t1]))
        try replica.perform(OpsCommand("Delete", ops: [Ops.setDeleted(grape)]))
        resolver = ColorResolver(replica.state)
        #expect(resolver.chain(t1).dangling)
        #expect(close(resolver.color(ofSwatch: t1), ColorFixture.grape.tinted(0.5), 1e-12))
        #expect(resolver.color(ofSwatch: grape) == nil)
        // A deleted protected swatch reads as live; percent read rules.
        let white = resolver.swatch(role: .white)!
        try replica.perform(OpsCommand("Delete", ops: [Ops.setDeleted(white)]))
        #expect(ColorResolver(replica.state).isSwatch(white))
        #expect(ColorResolver.percent(0) == 100 && ColorResolver.percent(.nan) == 100 && ColorResolver.percent(0.5) == 1 && ColorResolver.percent(40) == 40)
    }

    @Test func malformedSwatchesReadByTheNormalizations() throws {
        var replica = try SwatchTests.document()
        // A second Black (impossible by construction) is an ordinary swatch; a tint pointing at a
        // non-swatch reads its cache, then black; an unnamed colour shows its default name.
        let layer = try replica.perform(CreateLayer())!
        let layerID = ColorFixture.created(layer)[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.swatch.role = .black
        props.swatch.value = ColorValues.stored(ColorFixture.red)
        var tint = Wiretuner_Doc_V1_NodeProps()
        tint.swatch.parent.id = layerID.proto
        tint.swatch.tintPercent = 50
        var cachedTint = tint
        cachedTint.swatch.parent.cached = ColorValues.cached(ColorFixture.red)
        let change = try replica.perform(OpsCommand("Malformed", ops: [
            Ops.create(parent: SwatchFields.collection, position: [0xF0], props: props),
            Ops.create(parent: SwatchFields.collection, position: [0xF1], props: tint),
            Ops.create(parent: SwatchFields.collection, position: [0xF2], props: cachedTint),
        ]))
        let ids = ColorFixture.created(change)
        let list = SwatchList(replica.state)
        #expect(list[ids[0]]?.role == nil && list[ids[0]]?.name == "230r 57g 70b" && list[ids[0]]?.isProtected == false)
        #expect(list[ids[1]]?.color == .black.tinted(0.5) && list[ids[1]]?.baseRemoved == true && list[ids[1]]?.isSpot == false)
        #expect(list[ids[2]]?.color == ColorFixture.red.tinted(0.5))
        #expect(list.swatches.filter { $0.role == .black }.count == 1)
    }

    @Test func indexStaysCorrectAcrossRemoteChangesInAnyOrder() throws {
        var pair = try Self.pair()
        let grape = try ColorFixture.add(&pair.a, ColorFixture.grape, name: "Grape")
        pair.sync()
        let ref = SwatchList(pair.a.state).resolver.reference(to: grape)
        let s1 = try ColorFixture.shape(&pair.a, fill: ref, stroke: ref)
        let s2 = try ColorFixture.shape(&pair.a, fill: ref)
        let tint = try ColorFixture.tint(&pair.a, of: grape, 30)
        let created = pair.a.sent.count
        try pair.a.perform(RenameSwatch(grape, to: "Plum"))
        try pair.a.perform(SetAppearanceColor([(s2, ColorFixture.fillRow(s2, pair.a.state))], color: ColorResolver.inline(.white)))
        try pair.a.perform(SetTintPercent(tint, percent: 70))
        try pair.b.perform(RedefineSwatch(grape, to: ColorFixture.red))
        try pair.b.perform(SetSwatchGroup([grape], group: "Fruit"))
        // A third replica receives the creations, then B's edits and A's edits in reverse order --
        // an order neither replica saw -- indexing after each.
        let changes = Array(pair.a.sent[..<created]) + pair.b.sent.reversed() + pair.a.sent[created...].reversed()
        var c = Replica(0xC)
        var index = SwatchIndex(c.state)
        for change in changes {
            let before = c.state
            c.receive([change])
            index.apply(DocumentEvent(change: change, origin: .remote, before: before, after: c.state))
        }
        let full = SwatchIndex(c.state)
        #expect(index.dependents(of: grape) == full.dependents(of: grape))
        #expect(index.list.swatches == full.list.swatches)
        #expect(Set(index.liveDependents(of: grape, in: c.state).map(\.node)) == [s1, tint])
        #expect(index.users(of: [grape], in: c.state) == [s1])
        #expect(index.isUsed(grape, in: c.state))
        #expect(index.list.named("Plum")?.id == grape && index.list[grape]?.color == ColorFixture.red && index.list[grape]?.section == "Fruit")
        #expect(index.list[tint]?.tintPercent == 70)
        #expect(index.uses(on: s2).first?.swatch == nil && index.uses(on: OpID(counter: 4321, replica: 4)).isEmpty)
        #expect(index.dependents(of: grape).filter { $0.node == s1 }.count == 2)
        #expect(index.unnamedUses(in: c.state).map(\.node) == [s2])
        // Deleting the object and a reload.
        try pair.a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(s1)]))
        let before = c.state
        c.receive([pair.a.sent.last!])
        index.apply(DocumentEvent(change: pair.a.sent.last!, origin: .remote, before: before, after: c.state))
        #expect(index.users(of: [grape], in: c.state).isEmpty)
        index.apply(DocumentEvent(change: Wiretuner_Doc_V1_Change(), origin: .reload, before: c.state, after: EngineState()))
        #expect(index.list.swatches.isEmpty && index.dependents(of: grape).isEmpty)
    }

    @Test func usesAreFoundInRegistersNestedMessagesMarksAndTints() throws {
        var replica = try SwatchTests.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let ref = SwatchList(replica.state).resolver.reference(to: grape)
        let shape = try ColorFixture.shape(&replica, fill: ref)
        let uses = ColorUses.uses(of: shape, in: replica.state)
        #expect(uses.count == 1 && uses[0].swatch == grape)
        // The path of a register round-trips through the sparse writer.
        guard case .register(let path) = uses[0].location else { Issue.record("register"); return }
        let op = ColorUses.write(ColorResolver.inline(.white), at: path, of: shape)
        let value = replica.state.registerValue(in: op.set.values, kind: 20, path: path)
        #expect(value != nil)
        #expect(ColorUses.leaf(RegisterPath([20, 999]), schema: replica.state.schema) == nil)
        #expect(ColorUses.uses(of: OpID(counter: 5555, replica: 5), in: replica.state).isEmpty)
        // A ColorRef inside an encoded message the table describes.
        var fill = Wiretuner_Doc_V1_BasicFill()
        fill.color = ref
        let nested = ColorUses.nested(try fill.serializedBytes(), message: "wiretuner.doc.v1.BasicFill", schema: replica.state.schema, depth: 0)
        #expect(nested == [ref])
        #expect(ColorUses.nested([0x0A], message: "wiretuner.doc.v1.BasicFill", schema: replica.state.schema, depth: 0).isEmpty)
        #expect(ColorUses.nested([], message: "x", schema: replica.state.schema, depth: 99).isEmpty)
        // Wire records skip fixed and varint fields and stop at malformed input.
        let records = Array(WireRecords([0x08, 0x01, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0x1D, 0, 0, 0, 0, 0x22, 0x01, 0x07, 0x0B]))
        #expect(records.count == 1 && records[0].field == 4 && records[0].payload == [7])
        #expect(Array(WireRecords([0x08])).isEmpty && Array(WireRecords([0x0A, 0x05, 0x01])).isEmpty && Array(WireRecords(Data([0x80]))).isEmpty)
        // A text mark's fill.
        let text = try replica.perform(OpsCommand("Text", ops: [Ops.create(parent: OpID.wellKnown(4), position: [0x80], props: Fixture.textBlock())]))
        let block = ColorFixture.created(text)[0]
        try replica.perform(OpsCommand("Type", ops: [Ops.textInsert(block, Fixture.text, "Hi")]))
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = block.proto
        mark.text = Fixture.text.proto
        mark.start.char = Ops.elementID(OpID(counter: ColorFixture.created(text)[0].counter + 1, replica: 0xA))
        mark.start.before = true
        mark.end.char = Ops.elementID(OpID(counter: ColorFixture.created(text)[0].counter + 2, replica: 0xA))
        mark.value.fill = ref
        var markOp = Wiretuner_Doc_V1_Op()
        markOp.textMark = mark
        try replica.perform(OpsCommand("Mark", ops: [markOp]))
        #expect(ColorUses.uses(of: block, in: replica.state).contains { if case .mark = $0.location { return $0.swatch == grape } else { return false } })
        #expect(ColorUses.touched(by: replica.sent.last!) == [block])
    }

    @Test func touchedNamesEveryOpsNode() {
        let node = OpID(counter: 9, replica: 2)
        let path = RegisterPath([20, 3])
        var ops: [Wiretuner_Doc_V1_Op] = [
            Ops.create(parent: SwatchFields.collection, position: [0x80], props: SwatchFields.values { $0.spot = true }),
            Ops.set(node, [path], values: Wiretuner_Doc_V1_NodeProps()), Ops.move(node, parent: .zero, position: [1]), Ops.setDeleted(node),
            Ops.textInsert(node, path, "a"), Ops.textDelete(node, path, first: node, count: 1),
            Ops.elementInsert(node, path, positions: [[1]]), Ops.elementMove(node, path, position: [1]), Ops.elementDelete(node, [path]),
            Ops.setAdd(node, path, values: Wiretuner_Doc_V1_NodeProps()), Ops.setRemove(node, path, values: Wiretuner_Doc_V1_NodeProps()),
            Ops.noop(), Wiretuner_Doc_V1_Op(),
        ]
        var mark = Wiretuner_Doc_V1_Op()
        mark.textMark.node = OpID(counter: 3, replica: 3).proto
        ops.append(mark)
        var change = Wiretuner_Doc_V1_Change()
        change.replica = 7
        change.startCounter = 100
        change.ops = ops
        #expect(ColorUses.touched(by: change) == [OpID(counter: 100, replica: 7), node, OpID(counter: 3, replica: 3)])
    }

    @Test func swatchesModelFollowsTheDocument() async throws {
        let document = await MainActor.run { Document(memory: DocumentCore(state: EngineState(), replica: 0xD)) }
        let model = await SwatchesModel(document: document)
        try await document.perform(CreateDefaultSwatches())
        let grape = ColorFixture.created(try await document.perform(AddSwatch(ColorFixture.grape, name: "Grape")))[0]
        await MainActor.run {
            #expect(model.list.swatches.map(\.name) == ["White", "Black", "Registration", "Grape"])
            #expect(model.revision == 2)
            #expect(model.userCount(of: [grape]) == 0)
        }
        try await document.perform(RemoveSwatches([grape], index: await model.index))
        await MainActor.run {
            #expect(model.deleted().map(\.id) == [grape])
            model.stop()
            model.stop()
        }
        try await document.perform(RestoreSwatches([grape]))
        await MainActor.run { #expect(model.revision == 3) }
    }
}

extension Color {
    /// The colour without a spot ink.
    func withSpot(_ ink: SpotInk?) -> Color {
        var color = self
        color.spot = ink
        return color
    }
}
