import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DRAW-038: document hose sets -- the commands, the read normalizations, spraying and merges.
@Suite struct HoseSetTests {
    /// A set named `name` on `replica`.
    static func set(_ replica: inout Replica, name: String = "Leaves") throws -> OpID {
        try replica.perform(CreateHoseSet(name: name))!.createdNodes[0]
    }

    /// Pastes a 10 pt square at `x` into `set` as its next object.
    @discardableResult
    static func addSquare(_ replica: inout Replica, to set: OpID, x: Double = 100) throws -> OpID {
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: x), on: &replica)
        let payload = ClipboardPayload(copying: [rect], from: replica.state)
        try replica.perform(CutObjects([rect]))
        return try replica.perform(AddHoseObject(set, payload: payload))!.createdNodes[0]
    }

    @Test func createRenameDuplicateDeleteAndRestore() throws {
        var a = Replica(0xA)
        var options = Wiretuner_Doc_V1_HoseOptions()
        options.order = .random
        let change = try a.perform(CreateHoseSet(name: " Leaves ", options: options))!
        #expect(change.label == "New hose set")
        let leaves = change.createdNodes[0]
        #expect(a.state.store.placement(leaves)?.parent == WellKnown.symbols)
        let read = try #require(HoseSets.set(leaves, in: a.state))
        #expect(read.name == "Leaves" && read.options.order == .random && read.objects.isEmpty && read.libraryID == nil)
        // Beside symbols: the symbol list skips it.
        #expect(Symbols.symbols(in: a.state).isEmpty)
        #expect(throws: HoseError.nameTaken("Leaves")) { try a.perform(CreateHoseSet(name: "Leaves")) }
        #expect(throws: HoseError.emptyName) { try a.perform(CreateHoseSet(name: "  ")) }
        #expect(try a.perform(RenameHoseSet(leaves, name: "Leaves")) == nil)
        #expect(try a.perform(RenameHoseSet(leaves, name: "Foliage"))!.label == "Rename hose set")
        try Self.addSquare(&a, to: leaves)
        let copy = try a.perform(DuplicateHoseSet(leaves, name: "Foliage 2"))!
        #expect(copy.label == "Duplicate hose set")
        let duplicate = try #require(HoseSets.list(in: a.state).first { $0.name == "Foliage 2" })
        #expect(duplicate.objects.count == 1 && duplicate.options.order == .random && duplicate.id != leaves)
        #expect(try a.perform(DeleteHoseSet(leaves))!.label == "Delete hose set")
        #expect(HoseSets.set(leaves, in: a.state) == nil && HoseSets.list(in: a.state).map(\.name) == ["Foliage 2"])
        #expect(throws: HoseError.notASet(leaves)) { try a.perform(RenameHoseSet(leaves, name: "X")) }
        #expect(throws: HoseError.notASet(leaves)) { try a.perform(DeleteHoseSet(leaves)) }
        #expect(throws: HoseError.notASet(leaves)) { try a.perform(DuplicateHoseSet(leaves, name: "X")) }
        #expect(try a.perform(RestoreHoseSet(leaves))!.label == "Restore hose set")
        #expect(HoseSets.set(leaves, in: a.state)?.objects.count == 1)
        #expect(throws: HoseError.notASet(leaves)) { try a.perform(RestoreHoseSet(leaves)) }
        #expect(throws: HoseError.notASet(WellKnown.symbols)) { try a.perform(RestoreHoseSet(WellKnown.symbols)) }
    }

    @Test func pastedArtworkBecomesCentredObjects() throws {
        var a = Replica(0xA)
        let set = try Self.set(&a)
        let object = try Self.addSquare(&a, to: set, x: 100)
        let bounds = try #require(Objects.bounds(of: object, in: a.state))
        #expect(abs(bounds.midX) < 1e-9 && abs(bounds.midY) < 1e-9 && bounds.width == 10)
        #expect(a.state.nodeKind(object) == .rect)
        // Several objects become one group.
        let one = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil, x: 30), on: &a)
        let change = try a.perform(AddHoseObject(set, payload: ClipboardPayload(copying: [one, two], from: a.state)))!
        #expect(change.label == "Paste in hose object")
        let group = change.createdNodes[0]
        #expect(a.state.nodeKind(group) == .group && a.state.liveChildren(group).count == 2)
        let groupBounds = try #require(Objects.bounds(of: group, in: a.state))
        #expect(abs(groupBounds.midX) < 1e-9 && groupBounds.width == 40)
        #expect(HoseSets.set(set, in: a.state)?.objects == [object, group])
        #expect(HoseSets.extent(of: HoseSets.set(set, in: a.state)!, in: a.state) == 40)
        #expect(throws: HoseError.nothingToAdd) { try a.perform(AddHoseObject(set, payload: ClipboardPayload(nodes: []))) }
        #expect(throws: HoseError.notASet(one)) { try a.perform(AddHoseObject(one, payload: ClipboardPayload(nodes: []))) }
        // Ten at most.
        for _ in 0..<8 { try Self.addSquare(&a, to: set) }
        #expect(throws: HoseError.full) { try Self.addSquare(&a, to: set) }
        // Remove.
        #expect(try a.perform(RemoveHoseObject(set, object: object))!.label == "Remove hose object")
        #expect(HoseSets.set(set, in: a.state)?.objects.count == 9)
        #expect(throws: HoseError.notAnObject(object)) { try a.perform(RemoveHoseObject(set, object: object)) }
        let empty = try Self.set(&a, name: "Empty")
        #expect(HoseSets.extent(of: HoseSets.set(empty, in: a.state)!, in: a.state) == 1)
    }

    @Test func optionsAndTheirNormalizations() throws {
        var a = Replica(0xA)
        let set = try Self.set(&a)
        let defaults = try #require(HoseSets.set(set, in: a.state)).options
        #expect(defaults == HoseSprayOptions() && defaults.gridSize == 36 && defaults.scalePercent == 100 && defaults.spacing == .variable)
        let change = try a.perform(SetHoseOptions(set, [.order(.backAndForth), .spacing(.grid), .gridSize(20), .spacingAmount(150),
                                                        .scale(.random), .scalePercent(180), .rotation(.incremental), .angle(0.5),
                                                        .order(.random)]))!
        #expect(change.label == "Change hose options")
        let options = try #require(HoseSets.set(set, in: a.state)).options
        #expect(options == HoseSprayOptions(order: .random, spacing: .grid, gridSize: 20, spacingAmount: 150, scale: .random,
                                            scalePercent: 180, rotation: .incremental, angle: 0.5))
        try a.perform(SetHoseOptions(set, [.spacing(.random), .rotation(.random), .order(.backAndForth)]))
        let random = try #require(HoseSets.set(set, in: a.state)).options
        #expect(random.spacing == .random && random.rotation == .random && random.order == .backAndForth)
        #expect(try a.perform(SetHoseOptions(set, [])) == nil)
        for bad in [HoseOption.gridSize(0), .spacingAmount(201), .scalePercent(0.5), .angle(.nan), .gridSize(.infinity)] {
            #expect(throws: ObjectEditError.self) { try a.perform(SetHoseOptions(set, [bad])) }
        }
        #expect(throws: HoseError.notASet(WellKnown.symbols)) { try a.perform(SetHoseOptions(WellKnown.symbols, [.angle(1)])) }
        // Stored values outside the rules read normalized.
        var stored = Wiretuner_Doc_V1_HoseOptions()
        stored.gridSize = -4
        stored.scalePercent = 0
        #expect(HoseSets.options(stored).gridSize == 36 && HoseSets.options(stored).scalePercent == 100)
    }

    // MARK: Spraying

    @Test func aStrokeCreatesTransformedCopiesInOneChange() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        let set = try Self.set(&a)
        let square = try Self.addSquare(&a, to: set)
        // A symbol member sprays as instances.
        let artwork = try LayerFixture.object(LayerFixture.rect(on: layer, x: 200), on: &a)
        let instance = try a.perform(ConvertToSymbol([artwork]))!.createdObjects.last!
        try a.perform(AddHoseObject(set, payload: ClipboardPayload(copying: [instance], from: a.state)))
        let before = a.state.liveChildren(layer)
        let placements = [HosePlacement(index: 0, center: Point(x: 50, y: 50), scale: 2, rotation: 0),
                          HosePlacement(index: 1, center: Point(x: 80, y: 50), scale: 1, rotation: 0),
                          HosePlacement(index: 0, center: Point(x: 110, y: 50), scale: 0.5, rotation: Double.pi / 2),
                          HosePlacement(index: 7, center: .zero, scale: 1, rotation: 0)]
        let change = try a.perform(SprayHose(set, placements: placements, layer: layer))!
        #expect(change.label == "Spray 4 objects" && SprayHose(set, placements: [placements[0]]).label == "Spray object")
        let sprayed = Array(a.state.liveChildren(layer).dropFirst(before.count))
        #expect(sprayed.count == 3)
        #expect(sprayed.map { a.state.nodeKind($0) } == [.rect, .instance, .rect])
        let big = try #require(Objects.bounds(of: sprayed[0], in: a.state))
        #expect(abs(big.midX - 50) < 1e-9 && abs(big.width - 20) < 1e-9)
        let small = try #require(Objects.bounds(of: sprayed[2], in: a.state))
        #expect(abs(small.midX - 110) < 1e-9 && abs(small.height - 5) < 1e-9)
        // The hose object itself is untouched and nothing records the hose.
        #expect(Objects.bounds(of: square, in: a.state)?.midX == 0)
        // Only placements past the objects: nothing to write.
        #expect(try a.perform(SprayHose(set, placements: [placements[3]], layer: layer)) == nil)
        #expect(throws: HoseError.notASet(layer)) { try a.perform(SprayHose(layer, placements: placements)) }
    }

    @Test func aStrokePastTheOpLimitIsSplitUnderOneLabel() throws {
        var a = Replica(0xA)
        let set = try Self.set(&a)
        try Self.addSquare(&a, to: set)
        let placements = (0..<7).map { HosePlacement(index: 0, center: Point(x: Double($0) * 20, y: 0), scale: 1, rotation: 0) }
            + [HosePlacement(index: 3, center: .zero, scale: 1, rotation: 0)]
        let whole = try SprayHose.strokes(set, placements: placements, in: a.state)
        #expect(whole.count == 1 && whole[0].placements.count == 7)
        let pieces = try SprayHose.strokes(set, placements: placements, in: a.state, limit: 8)
        #expect(pieces.count > 1 && pieces.allSatisfy { $0.label == "Spray 7 objects" })
        #expect(pieces.reduce(0) { $0 + $1.placements.count } == 7)
        var created = 0
        for piece in pieces {
            let change = try a.perform(piece)!
            #expect(change.ops.count <= 8)
            created += change.createdObjects.count
        }
        #expect(created == 7)
        #expect(throws: HoseError.notASet(WellKnown.layers)) { try SprayHose.strokes(WellKnown.layers, placements: placements, in: a.state) }
    }

    @Test func aLibraryHoseIsCopiedIntoTheDocumentOnce() throws {
        var a = Replica(0xA)
        let bundle = HoseDefaults.bundles[1]
        let change = try a.perform(ImportHoseSet(bundle))!
        #expect(change.label == "Copy hose to document")
        let stars = try #require(HoseSets.set(libraryID: bundle.libraryID!, in: a.state))
        #expect(stars.name == "Stars" && stars.objects.count == 2 && stars.options.rotation == .random)
        #expect(try a.perform(ImportHoseSet(bundle)) == nil)
        // A document's own set (no identity) is always copied.
        var own = bundle
        own.tree.props.hoseSet.common.note = ""
        own.tree.props.hoseSet.common.name = "Mine"
        try a.perform(ImportHoseSet(own))
        #expect(HoseSets.list(in: a.state).count == 2 && HoseSets.list(in: a.state).first { $0.name == "Mine" }?.libraryID == nil)
        #expect(HoseSets.libraryID("wt-hose:not-a-uuid") == nil)
    }

    @Test func thePreviewDrawsEachPlacement() throws {
        var a = Replica(0xA)
        let set = try Self.set(&a)
        let square = try Self.addSquare(&a, to: set)
        let artwork = try LayerFixture.object(LayerFixture.rect(on: nil, x: 200), on: &a)
        let instance = try a.perform(ConvertToSymbol([artwork]))!.createdObjects.last!
        try a.perform(AddHoseObject(set, payload: ClipboardPayload(copying: [instance], from: a.state)))
        let read = try #require(HoseSets.set(set, in: a.state))
        let placements = [HosePlacement(index: 0, center: Point(x: 30, y: 40), scale: 2, rotation: 0),
                          HosePlacement(index: 0, center: Point(x: 60, y: 40), scale: 1, rotation: 0),
                          HosePlacement(index: 1, center: .zero, scale: 1, rotation: 0),
                          HosePlacement(index: 5, center: .zero, scale: 1, rotation: 0)]
        let items = HosePreview.items(read, placements: placements, in: a.state)
        #expect(items.count == 2)
        guard case .path(let first)? = items.first else { Issue.record("no path"); return }
        let center = first.transform.apply(Point(x: 5, y: 5))
        #expect(abs(center.x - 30) < 1e-9 && abs(center.y - 40) < 1e-9)
        #expect(HosePreview.items(of: square, in: a.state).count == 1)
        #expect(HosePreview.items(of: read.objects[1], in: a.state).isEmpty)
    }

    // MARK: Merges

    @Test func elevenConcurrentObjectsReadAsTen() throws {
        var pair = Pair()
        let set = try Self.set(&pair.a)
        for _ in 0..<8 { try Self.addSquare(&pair.a, to: set) }
        pair.sync()
        try Self.addSquare(&pair.a, to: set, x: 10)
        try Self.addSquare(&pair.b, to: set, x: 20)
        try Self.addSquare(&pair.b, to: set, x: 30)
        pair.sync()
        for replica in [pair.a, pair.b] {
            let read = try #require(HoseSets.set(set, in: replica.state))
            #expect(read.objects.count == 10 && read.extras.count == 1)
            #expect(read.objects + read.extras == replica.state.liveChildren(set))
        }
        #expect(HoseSets.set(set, in: pair.a.state)?.objects == HoseSets.set(set, in: pair.b.state)?.objects)
        // An extra can be removed.
        let extra = HoseSets.set(set, in: pair.a.state)!.extras[0]
        try pair.a.perform(RemoveHoseObject(set, object: extra))
        #expect(HoseSets.set(set, in: pair.a.state)?.extras.isEmpty == true)
        #expect(throws: HoseError.full) { try Self.addSquare(&pair.a, to: set) }
    }

    @Test func concurrentOptionEditsConverge() throws {
        var pair = Pair()
        let set = try Self.set(&pair.a)
        pair.sync()
        try pair.a.perform(SetHoseOptions(set, [.order(.random), .spacingAmount(50)]))
        try pair.b.perform(SetHoseOptions(set, [.order(.backAndForth), .scalePercent(150)]))
        try pair.b.perform(RenameHoseSet(set, name: "Ferns"))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let read = try #require(HoseSets.set(set, in: replica.state))
            #expect(read.options.order == .backAndForth && read.options.spacingAmount == 50 && read.options.scalePercent == 150)
            #expect(read.name == "Ferns")
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func deleteSetVersusAddObjectLeavesARestorableSet() throws {
        var pair = Pair()
        let set = try Self.set(&pair.a)
        let first = try Self.addSquare(&pair.a, to: set)
        pair.sync()
        try pair.a.perform(DeleteHoseSet(set))
        let added = try Self.addSquare(&pair.b, to: set)
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(HoseSets.set(set, in: replica.state) == nil)
            #expect(replica.state.liveChildren(set) == [first, added] && replica.state.store.deleted(set)?.current.value == true)
        }
        try pair.b.perform(RestoreHoseSet(set))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(HoseSets.set(set, in: replica.state)?.objects == [first, added])
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func twoConcurrentStrokesBothLandInOneOrder() throws {
        var pair = Pair()
        let layer = try LayerFixture.layers(["Art"], on: &pair.a)[0]
        let set = try Self.set(&pair.a)
        try Self.addSquare(&pair.a, to: set)
        pair.sync()
        let left = (0..<3).map { HosePlacement(index: 0, center: Point(x: Double($0) * 15, y: 0), scale: 1, rotation: 0) }
        let right = (0..<2).map { HosePlacement(index: 0, center: Point(x: Double($0) * 15, y: 90), scale: 1, rotation: 0.3) }
        try pair.a.perform(SprayHose(set, placements: left, layer: layer))
        try pair.b.perform(SprayHose(set, placements: right, layer: layer))
        pair.sync()
        #expect(pair.a.state.liveChildren(layer).count == 5)
        #expect(pair.a.state.liveChildren(layer) == pair.b.state.liveChildren(layer))
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}
