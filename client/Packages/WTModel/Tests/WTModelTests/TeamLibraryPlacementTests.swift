import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// LIB-016: placing from a team library, and *Update from Library* on a symbol -- one undoable
/// change, and two concurrent updates read as one artwork set.
@Suite struct TeamLibraryPlacementTests {
    typealias Library = LibraryCatalogTests.Library

    static func instances(_ state: EngineState) -> [OpID] {
        Symbols.instanceIndex(in: state).values.flatMap { $0 }
    }

    @Test func placingCopiesTheSymbolOnceAndPlacesAnInstance() throws {
        let library = try Library()
        var (a, layer) = try StyleCommandFixture.document()
        let command = PlaceFromLibrary(library.badge, from: library.source, at: Point(x: 50, y: 60), layer: layer)
        #expect(command.label == "Place Symbol \"Badge\" from Marketing library")
        let sent = a.sent.count
        let change = try #require(try a.perform(command))
        #expect(a.sent.count == sent + 1)
        let symbol = try #require(Symbols.symbols(in: a.state).first)
        #expect(LibraryCatalogTests.provenance(symbol, a.state)?.sourceServerSeq == 40)
        let instance = try #require(change.createdObjects.last)
        #expect(Symbols.symbol(of: instance, in: a.state) == symbol)
        #expect(a.state.props(instance).instance.common.transform.tx == 50)

        // Placing again uses the copy already here.
        try a.perform(PlaceFromLibrary(library.badge, from: library.source, at: Point(x: 0, y: 0)))
        #expect(Symbols.symbols(in: a.state).count == 1 && Self.instances(a.state).count == 2)
        #expect(throws: LibraryCopyError.notInLibrary(library.brand)) { try a.perform(PlaceFromLibrary(library.brand, from: library.source, at: .zero)) }
        #expect(throws: ObjectEditError.self) { try a.perform(PlaceFromLibrary(library.badge, from: library.source, at: Point(x: .nan, y: 0))) }
    }

    @Test func updateFromLibraryIsOneUndoableChange() throws {
        var library = try Library()
        var a = Replica(0xA)
        try a.perform(CopyFromLibrary(library.badge, from: library.source))
        let symbol = try #require(Symbols.symbols(in: a.state).first)
        let before = RestoreContent.hash(a.state)
        // The library's symbol gains a second rectangle.
        let layer = try #require(library.replica.state.liveChildren(WellKnown.layers).first)
        let extra = try library.replica.perform(OpsCommand("Rect", ops: [Ops.create(parent: layer, position: [0xF0], props: ShapeFixture.rect())]))!.createdNodes[0]
        try library.replica.perform(OpsCommand("Move", ops: [Ops.move(extra, parent: library.badge, position: [0xF0])]))
        let newer = LibrarySource(documentID: library.source.documentID, name: "Marketing", headSeq: 50, state: library.replica.state)
        try a.perform(UpdateFromLibrary([symbol], from: newer))
        let artwork = Symbols.artwork(of: symbol, in: a.state)
        #expect(artwork.count == 2 && a.sent.count == 2)
        #expect(artwork.allSatisfy { NodeValues.common(a.state.props($0))?.library.sourceServerSeq == 50 }, "each copied child remembers the version")
        a.undo()
        #expect(RestoreContent.hash(a.state) == before)
        #expect(Symbols.artwork(of: symbol, in: a.state).count == 1)
    }

    @Test func twoPeopleUpdatingOneSymbolSeeOneArtworkSet() throws {
        let library = try Library()
        var pair = Pair()
        try pair.a.perform(CopyFromLibrary(library.badge, from: library.source))
        let symbol = try #require(Symbols.symbols(in: pair.a.state).first)
        pair.sync()
        let at50 = LibrarySource(documentID: library.source.documentID, name: "Marketing", headSeq: 50, state: library.replica.state)
        let at60 = LibrarySource(documentID: library.source.documentID, name: "Marketing", headSeq: 60, state: library.replica.state)
        try pair.a.perform(UpdateFromLibrary([symbol], from: at50))
        try pair.b.perform(UpdateFromLibrary([symbol], from: at50))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.liveChildren(symbol).count == 2, "both sets are live")
        let one = Symbols.artwork(of: symbol, in: pair.a.state)
        #expect(one.count == 1 && one == Symbols.artwork(of: symbol, in: pair.b.state))
        #expect(Symbols.artworkNodes(of: symbol, in: pair.a.state).count == Symbols.artworkNodes(of: library.badge, in: library.replica.state).count)

        // Updates to different versions: the version the symbol records wins.
        try pair.a.perform(UpdateFromLibrary([symbol], from: at60))
        try pair.b.perform(UpdateFromLibrary([symbol], from: at50))
        pair.sync()
        let recorded = try #require(LibraryCatalogTests.provenance(symbol, pair.a.state)).sourceServerSeq
        let kept = Symbols.artwork(of: symbol, in: pair.a.state)
        #expect(kept.count == 1 && kept == Symbols.artwork(of: symbol, in: pair.b.state))
        #expect(NodeValues.common(pair.a.state.props(kept[0]))?.library.sourceServerSeq == recorded)

        // Detached, the newest version's set is shown.
        try pair.a.perform(DetachFromLibrary([symbol]))
        let detached = Symbols.artwork(of: symbol, in: pair.a.state)
        #expect(detached.count == 1 && NodeValues.common(pair.a.state.props(detached[0]))?.library.sourceServerSeq == 60)
        // A child added by hand is always shown.
        let layer = try LayerFixture.layers(["L"], on: &pair.a)[0]
        _ = layer
        let own = try #require(try pair.a.perform(OpsCommand("Rect", ops: [Ops.create(parent: symbol, position: [0xFE], props: ShapeFixture.rect())]))).createdNodes[0]
        #expect(Symbols.artwork(of: symbol, in: pair.a.state).contains(own))
    }

    @Test func propsWithoutAKindTakeNoProvenance() {
        var provenance = Wiretuner_Doc_V1_LibraryProvenance()
        provenance.sourceServerSeq = 3
        #expect(LibraryCopying.withObjectProvenance(Wiretuner_Doc_V1_NodeProps(), provenance) == Wiretuner_Doc_V1_NodeProps())
    }
}
