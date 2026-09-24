import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

@Suite struct SymbolLibraryTests {
    @Test func copyToSymbolLeavesTheSelection() throws {
        var a = Replica(0xA)
        let first = try a.perform(SymbolFixture.rect(x: 0))!.createdObjects[0]
        let second = try a.perform(SymbolFixture.rect(x: 20))!.createdObjects[0]
        let change = try #require(try a.perform(CopyToSymbol([first, second])))
        #expect(change.label == "Copy to Symbol")
        let symbol = change.createdNodes[0]
        #expect(a.state.isLive(first) && a.state.isLive(second))
        #expect(a.state.liveChildren(symbol).count == 2)
        #expect(a.state.props(symbol).symbol.origin.x == 15)
        #expect(Symbols.instanceIndex(in: a.state)[symbol] == nil)
        #expect(try a.perform(CopyToSymbol([], name: "x")) == nil)
        let named = try #require(try a.perform(CopyToSymbol([first], name: "Named")))
        #expect(a.state.props(named.createdNodes[0]).symbol.common.name == "Named")
        a.undo()
        #expect(!a.state.isLive(named.createdNodes[0]))
    }

    @Test func duplicateCopiesArtworkUnderANewName() throws {
        var a = Replica(0xA)
        let (symbol, _, masters) = try SymbolFixture.converted(on: &a)
        let change = try #require(try a.perform(DuplicateSymbols([symbol])))
        #expect(change.label == "Duplicate Symbol")
        let copy = change.createdNodes[0]
        #expect(a.state.props(copy).symbol.common.name == "Symbol 1 copy")
        #expect(a.state.liveChildren(copy).count == 2 && Set(a.state.liveChildren(copy)).isDisjoint(with: masters))
        #expect(Symbols.symbols(in: a.state) == [symbol, copy])
        #expect(DuplicateSymbols([symbol, copy]).label == "Duplicate 2 symbols")
        #expect(throws: SymbolError.notASymbol(masters[0])) { try a.perform(DuplicateSymbols([masters[0]])) }
    }

    @Test func replaceArtworkAndReplaceVersusReplace() throws {
        var pair = Pair()
        let (symbol, instance, masters) = try SymbolFixture.converted(on: &pair.a)
        let mine = try pair.a.perform(SymbolFixture.rect(x: 100))!.createdObjects[0]
        let theirs = try pair.a.perform(SymbolFixture.rect(x: 200))!.createdObjects[0]
        pair.sync()
        let change = try #require(try pair.a.perform(ReplaceSymbolArtwork(symbol, with: [mine])))
        #expect(change.label == "Replace Symbol Artwork")
        #expect(masters.allSatisfy { !pair.a.state.isLive($0) })
        #expect(pair.a.state.liveChildren(symbol) == [mine])
        let placed = change.createdObjects[0]
        #expect(Symbols.instanceIndex(in: pair.a.state)[symbol] == [instance, placed])
        #expect(Objects.bounds(of: placed, in: pair.a.state) == Rect(x: 100, y: 0, width: 10, height: 10))
        try pair.b.perform(ReplaceSymbolArtwork(symbol, with: [theirs]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Set(pair.a.state.liveChildren(symbol)) == [mine, theirs])
        // Nothing to move, or the symbol's own artwork: nothing.
        #expect(try pair.a.perform(ReplaceSymbolArtwork(symbol, with: [mine])) == nil)
        #expect(throws: SymbolError.notASymbol(mine)) { try pair.a.perform(ReplaceSymbolArtwork(mine, with: [theirs])) }
    }

    @Test func replaceAcrossLayersPlacesTheInstanceOnTheActiveLayer() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["One", "Two"], on: &a)
        let (symbol, _, _) = try SymbolFixture.converted(on: &a)
        let first = try LayerFixture.object(SymbolFixture.rect(x: 0, layer: layers[0]), on: &a)
        let second = try LayerFixture.object(SymbolFixture.rect(x: 40, layer: layers[1]), on: &a)
        let change = try #require(try a.perform(ReplaceSymbolArtwork(symbol, with: [first, second], layer: layers[0])))
        #expect(Objects.parent(of: change.createdObjects[0], in: a.state) == layers[0])
    }

    @Test func swapReplacesObjectsWithInstancesAndSwapVersusSwapIsLWW() throws {
        var pair = Pair()
        let (symbol, instance, _) = try SymbolFixture.converted(on: &pair.a)
        let other = try pair.a.perform(CopyToSymbol([try pair.a.perform(SymbolFixture.rect(x: 60))!.createdObjects[0]]))!.createdNodes[0]
        let third = try pair.a.perform(CopyToSymbol([try pair.a.perform(SymbolFixture.rect(x: 90))!.createdObjects[0]]))!.createdNodes[0]
        let object = try pair.a.perform(SymbolFixture.rect(x: 300))!.createdObjects[0]
        pair.sync()
        let change = try #require(try pair.a.perform(SwapSymbol([object], to: symbol)))
        let placed = change.createdObjects[0]
        #expect(!pair.a.state.isLive(object) && Symbols.symbol(of: placed, in: pair.a.state) == symbol)
        let bounds = try #require(Objects.bounds(of: placed, in: pair.a.state))
        #expect(bounds.midX == 305 && bounds.midY == 5)
        try pair.a.perform(SwapSymbol([instance], to: other))
        try pair.b.perform(SwapSymbol([instance], to: third))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let winner = try #require(Symbols.symbol(of: instance, in: pair.a.state))
        #expect([other, third].contains(winner))
        #expect(pair.a.state.losingWrites(instance, SymbolFields.instanceSymbol).count >= 1)
    }

    @Test func removeWithReleaseOrDeleteAndConcurrentPlace() throws {
        for handling in [InstanceHandling.release, .delete] {
            var pair = Pair()
            let (symbol, instance, masters) = try SymbolFixture.converted(on: &pair.a)
            pair.sync()
            let remove = RemoveSymbols([symbol], instances: handling, in: pair.a.state)
            #expect(remove.label == "Remove symbol Symbol 1 and 1 instance")
            let change = try #require(try pair.a.perform(remove))
            #expect(!pair.a.state.isLive(symbol) && masters.allSatisfy { !pair.a.state.isLive($0) } && !pair.a.state.isLive(instance))
            if handling == .release {
                let group = try #require(change.createdObjects.first)
                #expect(pair.a.state.liveChildren(group).count == 2)
            } else {
                #expect(change.createdObjects.isEmpty)
            }
            // Concurrently B places an instance: it reads as a placeholder with the name and the
            // symbol's last known bounds; restoring the symbol re-renders it.
            let placed = try pair.b.perform(PlaceInstance(symbol, at: Point(x: 0, y: 0)))!.createdObjects[0]
            pair.sync()
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
            let spec = Symbols.instanceSpec(placed, transform: .identity, in: pair.a.state)
            #expect(spec.symbol == nil && spec.placeholderName == "Symbol 1")
            #expect(spec.placeholderRect == Rect(x: -15, y: -5, width: 30, height: 10))
            try pair.a.perform(OpsCommand("Restore symbol", ops: ([symbol] + masters).map { Ops.setDeleted($0, false) }))
            #expect(Symbols.instanceSpec(placed, transform: .identity, in: pair.a.state).symbol == NodeID(symbol))
        }
    }

    @Test func removeLabelsFoldersAndErrors() throws {
        var a = Replica(0xA)
        let (symbol, _, masters) = try SymbolFixture.converted(on: &a)
        let copy = try a.perform(DuplicateSymbols([symbol]))!.createdNodes[0]
        #expect(RemoveSymbols([copy], instances: .delete, in: a.state).label == "Remove symbol Symbol 1 copy")
        #expect(RemoveSymbols([symbol, copy], instances: .delete, in: a.state).label == "Remove 2 symbols and 1 instance")
        let folder = try a.perform(CreateSymbolFolder())!.createdNodes[0]
        #expect(a.state.props(folder).symbolFolder.common.name == "Folder 1")
        let inner = try a.perform(CreateSymbolFolder(name: "Inner", in: folder))!.createdNodes[0]
        let second = try a.perform(CreateSymbolFolder())!.createdNodes[0]
        #expect(a.state.props(second).symbolFolder.common.name == "Folder 2")
        #expect(throws: SymbolLibraryError.notAFolder(symbol)) { try a.perform(CreateSymbolFolder(in: symbol)) }
        let move = MoveSymbolsToFolder([copy], to: inner)
        #expect(move.label == "Move to Folder")
        try a.perform(move)
        #expect(Symbols.library(in: a.state).contains(.folder(folder, name: "Folder 1", entries: [.folder(inner, name: "Inner", entries: [.symbol(copy)])])))
        #expect(throws: SymbolLibraryError.folderIntoItself(folder)) { try a.perform(MoveSymbolsToFolder([folder], to: inner)) }
        #expect(throws: SymbolLibraryError.notAFolder(symbol)) { try a.perform(MoveSymbolsToFolder([copy], to: symbol)) }
        #expect(throws: SymbolLibraryError.notInLibrary(masters[0])) { try a.perform(MoveSymbolsToFolder([masters[0]], to: nil)) }
        #expect(MoveSymbolsToFolder([copy], to: nil).label == "Move to Top Level")
        // Removing a folder removes its symbols; a symbol in a deleted folder lists at the top.
        #expect(RemoveSymbols([folder], instances: .delete, in: a.state).label == "Remove symbol Symbol 1 copy")
        let empty = try a.perform(CreateSymbolFolder(name: "Empty"))!.createdNodes[0]
        #expect(RemoveSymbols([empty], instances: .delete, in: a.state).label == "Remove folder Empty")
        #expect(throws: SymbolLibraryError.notInLibrary(masters[0])) {
            try a.perform(RemoveSymbols([masters[0]], instances: .delete, in: a.state))
        }
        try a.perform(OpsCommand("Delete folder", ops: [Ops.setDeleted(inner)]))
        #expect(Symbols.library(in: a.state).last == .symbol(copy))
        // The symbol listed at the top level is no longer the folder's to remove.
        try a.perform(RemoveSymbols([folder], instances: .release, in: a.state))
        #expect(a.state.isLive(copy) && !a.state.isLive(folder))
    }

    @Test func releaseVersusConcurrentArtworkEdit() throws {
        var pair = Pair()
        let (_, instance, masters) = try SymbolFixture.converted(on: &pair.a)
        pair.sync()
        let released = try pair.a.perform(ReleaseInstances([instance]))!.createdObjects
        try pair.b.perform(OpsCommand("Move", ops: [Objects.setTransform(masters[0], kind: .rect, .translation(x: 50, y: 0))]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let copy = released[1]
        #expect(Objects.bounds(of: copy, in: pair.a.state)?.minX == 0)
    }

    @Test func nestingCyclesAreCutAtTheSmallestInstanceID() throws {
        var a = Replica(0xA)
        let (outer, _, _) = try SymbolFixture.converted(on: &a)
        let inner = try a.perform(CopyToSymbol([try a.perform(SymbolFixture.rect(x: 80))!.createdObjects[0]]))!.createdNodes[0]
        // outer holds an instance of inner, inner one of outer: a cycle through nesting.
        func nest(_ symbol: OpID, in host: OpID, key: UInt8) throws -> OpID {
            try a.perform(OpsCommand("Nest", ops: [Ops.create(parent: host, position: [0xF0, key], props: SymbolEditing.instanceProps(symbol, transform: .identity))]))!
                .createdNodes[0]
        }
        let first = try nest(inner, in: outer, key: 1)
        #expect(Symbols.cutInstances(in: a.state).isEmpty)
        let second = try nest(outer, in: inner, key: 2)
        #expect(Symbols.cutInstances(in: a.state) == [min(first, second)])
        #expect(Symbols.isCut(first, in: a.state))
        #expect(!Symbols.isCut(second, in: a.state))
        let spec = Symbols.instanceSpec(first, transform: .identity, in: a.state)
        #expect(spec.symbol == nil && spec.placeholderName == "Symbol 2")
        #expect(Symbols.enclosingSymbol(of: first, in: a.state) == outer)
        // A self-reference is a cycle of one.
        let own = try nest(outer, in: outer, key: 3)
        #expect(Symbols.cutInstances(in: a.state).contains(own))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        _ = builder.rebuild(a.state)
    }

    @Test func aReferenceToANonSymbolReadsAsNotASymbol() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Only"], on: &a)[0]
        let target = try LayerFixture.object(LayerFixture.rect(on: layer), on: &a)
        let instance = try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0xF0], props: SymbolEditing.instanceProps(target, transform: .identity))]))!.createdNodes[0]
        let spec = Symbols.instanceSpec(instance, transform: .identity, in: a.state)
        #expect(spec.symbol == nil && spec.placeholderName == "not a symbol" && spec.placeholderRect == nil)
    }
}
