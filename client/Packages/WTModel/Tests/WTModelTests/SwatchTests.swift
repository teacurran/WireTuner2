import Foundation
import Testing
import WTCRDT
@testable import WTModel
import WTProto
import WTRender

/// COLOR-003, COLOR-004, COLOR-005 and COLOR-009 on one replica: the swatch commands, the
/// protected defaults, naming, the list's read-time rules and order, and tints.
@Suite struct SwatchTests {
    static func document() throws -> Replica {
        var replica = Replica(0xA)
        try replica.perform(CreateDefaultSwatches())
        return replica
    }

    @Test func aNewDocumentHasTheThreeProtectedDefaultsOnce() throws {
        var replica = try Self.document()
        #expect(try replica.perform(CreateDefaultSwatches()) == nil)
        let list = SwatchList(replica.state)
        #expect(list.swatches.map(\.name) == ["White", "Black", "Registration"])
        #expect(list.swatches.map(\.role) == [.white, .black, .registration])
        #expect(list.swatches.map(\.isSpot) == [false, true, true])
        #expect(list.swatches.allSatisfy { $0.isProtected })
        #expect(list.swatches[2].color == .registration)
        #expect(list.swatches[1].color == Color(cyan: 0, magenta: 0, yellow: 0, black: 1))
        #expect(list.sections.map(\.group) == [""])
        for id in list.swatches.map(\.id) {
            #expect(throws: SwatchError.protected(id)) { try replica.perform(RemoveSwatches([id])) }
            #expect(throws: SwatchError.protected(id)) { try replica.perform(RenameSwatch(id, to: "Paper")) }
            #expect(throws: SwatchError.protected(id)) { try replica.perform(RedefineSwatch(id, to: ColorFixture.red)) }
        }
        #expect(CreateDefaultSwatches().label == "Default colors")
    }

    @Test func defaultsGoAheadOfExistingSwatchesAndTakeTints() throws {
        var replica = Replica(0xA)
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        try replica.perform(CreateDefaultSwatches())
        let children = replica.state.store.children(SwatchFields.collection)
        #expect(children.last == grape)
        var list = SwatchList(replica.state)
        let white = list.swatches[0].id
        let black = list.swatches[1].id
        let lightBlack = try ColorFixture.tint(&replica, of: black, 50)
        let lightWhite = try ColorFixture.tint(&replica, of: white, 50)
        list = SwatchList(replica.state)
        #expect(list[lightBlack]?.isSpot == true && list[lightWhite]?.isSpot == false)
        #expect(list[lightBlack]?.depth == 1 && list.tints(of: black) == [lightBlack])
        #expect(list.tints(of: OpID(counter: 1234, replica: 1)).isEmpty)
        #expect(list.swatches.map(\.name) == ["White", "50% White", "Black", "50% Black", "Registration", "Grape"])
    }

    @Test func addingNamesAndSuffixes() throws {
        var replica = try Self.document()
        let a = try ColorFixture.add(&replica, ColorFixture.red)
        let b = try ColorFixture.add(&replica, ColorFixture.red)
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "  Grape ")
        let list = SwatchList(replica.state)
        #expect(list[a]?.name == "230r 57g 70b")
        #expect(list[b]?.name == "230r 57g 70b-1")
        #expect(list[grape]?.name == "Grape")
        #expect(list[a]?.hasDefaultName == true && list[b]?.hasDefaultName == true && list[grape]?.hasDefaultName == false)
        #expect(list[a]?.badge == "RGB" && list[grape]?.badge == nil)
        #expect(list.named("Grape")?.id == grape)
        #expect(list.named("Plum") == nil)
        #expect(throws: SwatchError.nameTaken("Grape")) { try replica.perform(AddSwatch(ColorFixture.plum, name: "Grape")) }
        #expect(AddSwatch(ColorFixture.red).label == "Add color \"230r 57g 70b\"")
        #expect(AddSwatch(ColorFixture.red, name: "Red").label == "Add color \"Red\"")
        #expect(replica.core.undoStack.undoTitle == "Undo Add color \"Grape\"")
        replica.undo()
        #expect(SwatchList(replica.state)[grape] == nil)
    }

    @Test func addToSwatchesRelinksTheObjectsColor() throws {
        var replica = try Self.document()
        let shape = try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.red))
        let path = ColorFixture.fillPath(shape, replica.state)
        let change = try replica.perform(AddSwatch(ColorFixture.red, name: "Red", relink: [(shape, path)]))
        let red = ColorFixture.created(change)[0]
        let ref = ColorFixture.fill(shape, replica.state)
        #expect(ColorResolver.swatch(of: ref) == red)
        #expect(ColorValues.cachedColor(ref.swatch.cached) == ColorFixture.red)
    }

    @Test func renameChecksUniquenessAndTints() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let plum = try ColorFixture.add(&replica, ColorFixture.plum, name: "Plum")
        let tint = try ColorFixture.tint(&replica, of: grape, 40)
        #expect(SwatchList(replica.state)[tint]?.name == "40% Grape")
        #expect(throws: SwatchError.nameTaken("Grape")) { try replica.perform(RenameSwatch(plum, to: "Grape")) }
        #expect(throws: SwatchError.emptyName) { try replica.perform(RenameSwatch(plum, to: " ")) }
        #expect(try replica.perform(RenameSwatch(plum, to: "Plum")) == nil)
        try replica.perform(RenameSwatch(grape, to: "Aubergine", from: "Grape"))
        #expect(replica.core.undoStack.undoTitle == "Undo Rename \"Grape\" to \"Aubergine\"")
        // The derived tint name follows the base with no write to the tint.
        #expect(SwatchList(replica.state)[tint]?.name == "40% Aubergine")
        try replica.perform(RenameSwatch(tint, to: "Light"))
        #expect(SwatchList(replica.state)[tint]?.name == "Light")
        try replica.perform(RenameSwatch(tint, to: ""))
        #expect(SwatchList(replica.state)[tint]?.name == "40% Aubergine")
        #expect(RenameSwatch(plum, to: "X").label == "Rename color to \"X\"")
        #expect(throws: SwatchError.notASwatch(OpID(counter: 999, replica: 9))) { try replica.perform(RenameSwatch(OpID(counter: 999, replica: 9), to: "X")) }
    }

    @Test func redefineWritesTheValueAndAutoRenames() throws {
        var replica = try Self.document()
        let auto = try ColorFixture.add(&replica, ColorFixture.red)
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        try replica.perform(RedefineSwatch(auto, to: Color(red: 0, green: 0, blue: 1)))
        #expect(SwatchList(replica.state)[auto]?.name == "0r 0g 255b")
        try replica.perform(RedefineSwatch(auto, to: Color(red: 1, green: 0, blue: 0), autoRename: false))
        #expect(SwatchList(replica.state)[auto]?.name == "0r 0g 255b")
        try replica.perform(RedefineSwatch(grape, to: ColorFixture.red, name: "Grape"))
        let list = SwatchList(replica.state)
        #expect(list[grape]?.name == "Grape" && list[grape]?.color == ColorFixture.red)
        #expect(replica.core.undoStack.undoTitle == "Undo Redefine \"Grape\"")
        #expect(RedefineSwatch(grape, to: .black).label == "Redefine color")
        // The same colour writes nothing.
        #expect(try replica.perform(RedefineSwatch(grape, to: ColorFixture.red)) == nil)
        // A tint dropped on becomes a colour.
        let tint = try ColorFixture.tint(&replica, of: grape, 50)
        try replica.perform(RedefineSwatch(tint, to: ColorFixture.plum))
        let redefined = SwatchList(replica.state)[tint]!
        #expect(!redefined.isTint && redefined.color == ColorFixture.plum && redefined.name == ColorText.defaultName(ColorFixture.plum))
    }

    @Test func duplicateGroupAndOrder() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let plum = try ColorFixture.add(&replica, ColorFixture.plum, name: "Plum")
        try replica.perform(DuplicateSwatch(grape, name: "Grape"))
        try replica.perform(DuplicateSwatch(SwatchList(replica.state).swatches[0].id))
        var list = SwatchList(replica.state)
        #expect(list.swatches.map(\.name) == ["White", "Black", "Registration", "Copy of White", "Grape", "Copy of Grape", "Plum"])
        #expect(list.named("Copy of White")?.isProtected == false)
        try replica.perform(DuplicateSwatch(grape))
        #expect(SwatchList(replica.state).named("Copy of Grape-1") != nil)
        let tint = try ColorFixture.tint(&replica, of: grape, 30)
        try replica.perform(DuplicateSwatch(tint))
        let copy = try #require(SwatchList(replica.state).named("Copy of 30% Grape"))
        #expect(copy.base == grape && copy.tintPercent == 30)
        try replica.perform(RemoveSwatches([tint, copy.id]))
        #expect(DuplicateSwatch(grape).label == "Duplicate color" && DuplicateSwatch(grape, name: "G").label == "Duplicate \"G\"")
        // Groups.
        try replica.perform(SetSwatchGroup([plum, list.swatches[0].id], group: " Fruit "))
        #expect(try replica.perform(SetSwatchGroup([plum], group: "Fruit")) == nil)
        list = SwatchList(replica.state)
        #expect(list.sections.map(\.group) == ["", "Fruit"])
        #expect(list.sections[1].swatches.map(\.id) == [plum])
        #expect(list.groups == ["Fruit"])
        #expect(SetSwatchGroup([plum], group: "").label == "Ungroup color" && SetSwatchGroup([plum, grape], group: "F").label == "Move 2 colors to \"F\"")
        // Moving by name.
        try replica.perform(MoveSwatches([plum], after: nil))
        list = SwatchList(replica.state)
        #expect(list.swatches.map(\.name).prefix(4) == ["White", "Black", "Registration", "Plum"])
        try replica.perform(MoveSwatches([plum, list.swatches[0].id], after: grape))
        list = SwatchList(replica.state)
        let names = list.swatches.map(\.name)
        #expect(names.firstIndex(of: "Plum") == names.firstIndex(of: "Grape")! + 1)
        #expect(try replica.perform(MoveSwatches([list.swatches[0].id], after: grape)) == nil)
        #expect(MoveSwatches([plum], after: nil).label == "Move color")
    }

    @Test func sortPutsDefaultsFirstNumbersBeforeLettersAndTintsUnderBases() throws {
        var replica = try Self.document()
        let names = ["banana", "Apple", "10 Blue", "2 Red", "cherry"]
        var ids: [String: OpID] = [:]
        for (i, name) in names.enumerated() {
            ids[name] = try ColorFixture.add(&replica, Color(red: Double(i) / 10, green: 0, blue: 0), name: name)
        }
        try ColorFixture.tint(&replica, of: ids["Apple"]!, 80, name: "z tint")
        try ColorFixture.tint(&replica, of: ids["Apple"]!, 20, name: "a tint")
        try replica.perform(MoveSwatches([ids["Apple"]!], after: nil))
        try replica.perform(SortSwatches())
        let list = SwatchList(replica.state)
        #expect(list.swatches.map(\.name) == ["White", "Black", "Registration", "2 Red", "10 Blue", "Apple", "a tint", "z tint", "banana", "cherry"])
        #expect(list.swatches.map(\.depth) == [0, 0, 0, 0, 0, 0, 1, 1, 0, 0])
        for (rank, swatch) in list.swatches.enumerated() {
            #expect(replica.state.store.placement(swatch.id)?.position == SortSwatches.canonicalKey(rank: rank))
        }
        // Sorting a sorted list writes nothing.
        #expect(try replica.perform(SortSwatches()) == nil)
        #expect(SortSwatches().label == "Sort colors")
    }

    @Test func canonicalKeysAreOrderedAndGenerated() {
        let ranks = [0, 1, 253, 254, 255, 64_515, 64_516, 100_000]
        let keys = ranks.map(SortSwatches.canonicalKey(rank:))
        #expect(keys[0] == [0x11, 0x01] && keys[3] == [0x12, 0x02, 0x01])
        for (a, b) in zip(keys, keys.dropFirst()) {
            #expect(FractionalIndex.less(a, b))
        }
        #expect(keys.allSatisfy { !$0.isEmpty && $0.last != 0 })
        #expect(SortSwatches.canonicalKey(rank: -3) == SortSwatches.canonicalKey(rank: 0))
        // Inserting between canonical keys still works.
        #expect(throws: Never.self) { try FractionalIndex.between(keys[0], keys[1], suffix: 7) }
    }

    @Test func removingTakesTintsAndKeepsLooks() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let tint = try ColorFixture.tint(&replica, of: grape, 40)
        let shape = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.reference(to: grape))
        let tinted = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.reference(to: tint))
        let unnamed = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: grape, percent: 10))
        try ColorFixture.markedText(&replica, fill: SwatchList(replica.state).resolver.reference(to: grape))
        // Recolour after applying: the objects' caches are now stale.
        try replica.perform(RedefineSwatch(grape, to: ColorFixture.plum))
        let fresh = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.reference(to: grape))
        let before = [shape, tinted, unnamed, fresh].map { SwatchList(replica.state).resolver.color(ColorFixture.fill($0, replica.state)) }
        let change = try replica.perform(RemoveSwatches([grape], names: ["Grape"]))!
        #expect(change.label == "Remove color \"Grape\"")
        let list = SwatchList(replica.state)
        #expect(list[grape] == nil && list[tint] == nil)
        #expect(!change.ops.contains { $0.set.node == fresh.proto })
        let after = [shape, tinted, unnamed, fresh].map { list.resolver.color(ColorFixture.fill($0, replica.state)) }
        #expect(zip(before, after).allSatisfy { close($0.0.map { var c = $0; c.spot = nil; return c }, $0.1, 1e-9) })
        // The references still name the swatches, so Restore re-links them with no write.
        #expect(ColorResolver.swatch(of: ColorFixture.fill(shape, replica.state)) == grape)
        let deleted = SwatchList.deleted(replica.state, now: Date(timeIntervalSince1970: 1_000_100))
        #expect(Set(deleted.map(\.id)) == [grape, tint])
        #expect(deleted.first { $0.id == tint }?.name == "40% Grape")
        #expect(SwatchList.deleted(replica.state, now: Date(timeIntervalSince1970: 1_000_000 + 31 * 24 * 3600)).isEmpty)
        replica.undo()
        #expect(SwatchList(replica.state)[grape] != nil && SwatchList(replica.state)[tint] != nil)
        #expect(RemoveSwatches([grape, tint]).label == "Remove 2 colors")
    }

    @Test func removeUnusedOnlyAndDeleteUnused() throws {
        var replica = try Self.document()
        let used = try ColorFixture.add(&replica, ColorFixture.grape, name: "Used")
        let usedByTint = try ColorFixture.add(&replica, ColorFixture.plum, name: "Base")
        let tint = try ColorFixture.tint(&replica, of: usedByTint, 30)
        let free = try ColorFixture.add(&replica, ColorFixture.red, name: "Free")
        let freeBase = try ColorFixture.add(&replica, .white, name: "Free base")
        let freeTint = try ColorFixture.tint(&replica, of: freeBase, 50)
        try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.reference(to: used))
        try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: tint, percent: 50))
        #expect(DeleteUnusedSwatches.unused(in: replica.state) == [free, freeBase, freeTint])
        try replica.perform(RemoveSwatches([used, usedByTint, free], unusedOnly: true))
        var list = SwatchList(replica.state)
        #expect(list[used] != nil && list[usedByTint] != nil && list[tint] != nil && list[free] == nil)
        let change = try replica.perform(DeleteUnusedSwatches())!
        #expect(change.label == "Delete unused colors")
        list = SwatchList(replica.state)
        #expect(list[freeBase] == nil && list[freeTint] == nil && list[used] != nil)
        #expect(try replica.perform(DeleteUnusedSwatches()) == nil)
    }

    @Test func restoreBringsBackTheChain() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let tint = try ColorFixture.tint(&replica, of: grape, 40)
        try replica.perform(RemoveSwatches([grape]))
        let change = try replica.perform(RestoreSwatches([tint]))!
        #expect(change.label == "Restore color")
        #expect(SwatchList(replica.state)[grape] != nil && SwatchList(replica.state)[tint] != nil)
        #expect(try replica.perform(RestoreSwatches([tint])) == nil)
        #expect(throws: SwatchError.notASwatch(.zero)) { try replica.perform(RestoreSwatches([.zero])) }
    }

    @Test func nameAllColorsNamesInlineColorsAndTints() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let a = try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.red))
        let b = try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.red))
        let c = try ColorFixture.shape(&replica, fill: ColorResolver.inline(ColorFixture.grape))
        let d = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: grape, percent: 25))
        let named = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.reference(to: grape))
        let d2 = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: grape, percent: 25))
        let lost = try ColorFixture.add(&replica, ColorFixture.plum, name: "Lost")
        let e1 = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: lost, percent: 50))
        let e2 = try ColorFixture.shape(&replica, fill: SwatchList(replica.state).resolver.tint(of: lost, percent: 50))
        try replica.perform(OpsCommand("Delete", ops: [Ops.setDeleted(lost)]))
        let gone = try ColorFixture.shape(&replica, fill: ColorResolver.inline(Color(red: 0, green: 1, blue: 0)))
        try replica.perform(OpsCommand("Delete", ops: [Ops.setDeleted(gone)]))
        let text = try ColorFixture.markedText(&replica, fill: ColorResolver.inline(.white))
        let before = [a, b, c, d].map { SwatchList(replica.state).resolver.color(ColorFixture.fill($0, replica.state)) }
        let change = try replica.perform(NameAllColors())!
        #expect(change.label == "Name All Colors")
        let list = SwatchList(replica.state)
        let refs = [a, b, c, d, named].map { ColorFixture.fill($0, replica.state) }
        #expect(refs.allSatisfy { if case .swatch? = $0.ref { return true } else { return false } })
        #expect(ColorResolver.swatch(of: refs[0]) == ColorResolver.swatch(of: refs[1]))
        #expect(ColorResolver.swatch(of: refs[2]) == grape)
        let tint = try #require(ColorResolver.swatch(of: refs[3]).flatMap { list[$0] })
        #expect(tint.isTint && tint.base == grape && tint.tintPercent == 25 && tint.name == "25% Grape")
        #expect(list.named("230r 57g 70b") != nil && list.named("0r 255g 0b") == nil)
        #expect(ColorResolver.swatch(of: ColorFixture.fill(d2, replica.state)) == tint.id)
        // Unnamed tints of a removed colour become one colour of what they show.
        let e = [e1, e2].map { ColorResolver.swatch(of: ColorFixture.fill($0, replica.state)) }
        #expect(e[0] == e[1] && list[e[0]!]?.isTint == false && close(list[e[0]!]?.color, ColorFixture.plum.tinted(0.5), 1e-9))
        #expect(ColorUses.uses(of: text, in: replica.state).first?.swatch == nil)
        let after = [a, b, c, d].map { list.resolver.color(ColorFixture.fill($0, replica.state)) }
        #expect(zip(before, after).allSatisfy { close($0.0, $0.1, 1e-9) })
        #expect(try replica.perform(NameAllColors()) == nil)
    }

    @Test func tintCommands() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape", spot: true)
        let plum = try ColorFixture.add(&replica, ColorFixture.plum, name: "Plum")
        let tint = try ColorFixture.tint(&replica, of: grape, 40)
        var swatch = SwatchList(replica.state)[tint]!
        #expect(swatch.isSpot && swatch.depth == 1 && swatch.tintPercent == 40)
        #expect(close(swatch.color, ColorFixture.grape.asSpot(SpotInk(swatch: NodeID(grape), name: "Grape")).tinted(0.4)))
        #expect(throws: SwatchError.nameTaken("Plum")) { try replica.perform(AddTintSwatch(of: grape, percent: 10, name: "Plum")) }
        try replica.perform(SetTintPercent(tint, percent: 250))
        #expect(SwatchList(replica.state)[tint]?.tintPercent == 100)
        #expect(try replica.perform(SetTintPercent(tint, percent: 100)) == nil)
        #expect(throws: SwatchError.notATint(plum)) { try replica.perform(SetTintPercent(plum, percent: 5)) }
        try replica.perform(RebaseTint(tint, onto: plum))
        swatch = SwatchList(replica.state)[tint]!
        #expect(swatch.base == plum && !swatch.isSpot && swatch.name == "100% Plum")
        #expect(try replica.perform(RebaseTint(tint, onto: plum)) == nil)
        #expect(throws: SwatchError.loop(tint)) { try replica.perform(RebaseTint(tint, onto: tint)) }
        let inner = try ColorFixture.tint(&replica, of: tint, 50)
        #expect(throws: SwatchError.loop(inner)) { try replica.perform(RebaseTint(tint, onto: inner)) }
        try replica.perform(SetTintPercent(tint, percent: 50))
        try replica.perform(FlattenTint(inner))
        swatch = SwatchList(replica.state)[inner]!
        #expect(!swatch.isTint && swatch.name == "50% 50% Plum" && close(swatch.color, ColorFixture.plum.tinted(0.25), 1e-9))
        try replica.perform(RenameSwatch(tint, to: "Named"))
        try replica.perform(FlattenTint(tint))
        #expect(SwatchList(replica.state)[tint]?.name == "Named")
        #expect([AddTintSwatch(of: grape, percent: 1).label, SetTintPercent(tint, percent: 1).label, RebaseTint(tint, onto: grape).label,
                 FlattenTint(tint).label] == ["Add tint", "Set tint percentage", "Re-base tint", "Flatten tint"])
    }

    @Test func spotAndSpaceConversions() throws {
        var replica = try Self.document()
        let grape = try ColorFixture.add(&replica, ColorFixture.grape, name: "Grape")
        let auto = try ColorFixture.add(&replica, Color(displayP3Red: 1, green: 0, blue: 0))
        let tint = try ColorFixture.tint(&replica, of: grape, 40)
        let black = SwatchList(replica.state).swatches[1].id
        try replica.perform(SetSwatchSpot([grape, tint, black], spot: true))
        #expect(SwatchList(replica.state)[grape]?.isSpot == true && SwatchList(replica.state)[tint]?.isSpot == true)
        #expect(try replica.perform(SetSwatchSpot([grape], spot: true)) == nil)
        #expect(SetSwatchSpot([grape], spot: true).label == "Make Spot" && SetSwatchSpot([grape], spot: false).label == "Make Process")
        // Convert: P3 red → sRGB is gamut mapped; the default name follows.
        try replica.perform(ConvertSwatchSpace([auto], to: .sRGB))
        var list = SwatchList(replica.state)
        #expect(list[auto]!.color.space == .sRGB && ColorModels.isInGamut(list[auto]!.color, of: .sRGB))
        #expect(list[auto]!.name == ColorText.defaultName(list[auto]!.color))
        try replica.perform(ConvertSwatchSpace([grape], to: .displayP3, name: "Grape"))
        list = SwatchList(replica.state)
        #expect(list[grape]!.value.space == .displayP3 && list[grape]!.name == "Grape")
        #expect(replica.core.undoStack.undoTitle == "Undo Convert \"Grape\" to Display P3")
        // The tint follows the base with no write, in the base's space.
        #expect(list[tint]!.color.space == .displayP3)
        try replica.perform(ConvertSwatchSpace([grape], to: .cmyk))
        #expect(SwatchList(replica.state)[grape]!.value.space == .cmyk)
        #expect(try replica.perform(ConvertSwatchSpace([grape, tint, black], to: .cmyk)) == nil)
        #expect(ConvertSwatchSpace.canConvert(list[auto]!, to: .displayP3) && !ConvertSwatchSpace.canConvert(list[auto]!, to: .sRGB))
        #expect(!ConvertSwatchSpace.canConvert(list[auto]!, to: .lab) && !ConvertSwatchSpace.canConvert(list[tint]!, to: .cmyk))
        #expect(ConvertSwatchSpace.targets.map(ConvertSwatchSpace.title) == ["sRGB", "Display P3", "CMYK"])
        #expect(ConvertSwatchSpace.title(.lab) == "Lab" && ConvertSwatchSpace.title(.oklab) == "OKLab")
        #expect(ConvertSwatchSpace([grape, tint], to: .cmyk).label == "Convert 2 colors to CMYK")
    }

    @Test func refusalsOfUnknownSwatches() throws {
        var replica = try Self.document()
        let nobody = OpID(counter: 77, replica: 7)
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(AddTintSwatch(of: nobody, percent: 5)) }
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(SetSwatchGroup([nobody], group: "G")) }
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(MoveSwatches([nobody], after: nil)) }
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(DuplicateSwatch(nobody)) }
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(SetSwatchSpot([nobody], spot: true)) }
        #expect(throws: SwatchError.notASwatch(nobody)) { try replica.perform(ConvertSwatchSpace([nobody], to: .cmyk)) }
    }
}
