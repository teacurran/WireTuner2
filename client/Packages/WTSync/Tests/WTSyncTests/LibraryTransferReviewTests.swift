import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// The review rows of the merge tests of LIB-022 (two people import one style) and LIB-016 (two
/// people update one symbol from its team library) after a reconnect.
@Suite struct LibraryTransferReviewTests {
    static let recording = DocumentCore.Recording(limit: 100, now: Date(timeIntervalSince1970: 1_000_000))

    /// A library document: "Base" (a fill), "Callout" based on it (a stroke), and the symbol Badge.
    static func library() throws -> (core: DocumentCore, callout: OpID, badge: OpID) {
        var core = DocumentCore(state: EngineState(), replica: 0x11B)
        let styles = GraphicStyleResolver.collection
        var base = Wiretuner_Doc_V1_NodeProps()
        base.style.common.name = "Base"
        base.style.appearance.fills = [Appearances.basicFill(red: 0.2, green: 0, blue: 0)]
        var callout = Wiretuner_Doc_V1_NodeProps()
        callout.style.common.name = "Callout"
        callout.style.appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 3)]
        let created = try core.perform(CreateNodes([(styles, [0x40], base), (styles, [0x50], callout)]), recording: recording)!.change!.createdNodes
        var link = Wiretuner_Doc_V1_NodeProps()
        link.style.basedOn.id = created[0].proto
        _ = try core.perform(OpsCommand("Parent", ops: [Ops.set(created[1], [RegisterPath([154, 4])], values: link)]), recording: recording)
        let rect = try core.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)), recording: recording)!.change!.createdObjects[0]
        let badge = try core.perform(ConvertToSymbol([rect], name: "Badge"), recording: recording)!.change!.createdNodes[0]
        return (core, created[1], badge)
    }

    @Test func twoPeopleImportingOneStyleListNothing() throws {
        let (library, callout, _) = try Self.library()
        let package = StylePackage(styles: [callout], from: library.state)
        var world = OfflineRound()
        try world.byMe(ImportStyles(package))
        try world.byThem(ImportStyles(package))
        #expect(world.measure().entries.isEmpty)
        let state = world.mine.state
        let names = GraphicStyleFields.displayNames(in: state, GraphicStyleResolver(state))
        #expect(names.values.sorted() == ["Base", "Base 2", "Callout", "Callout 2"])
        world.upload()
    }

    @Test func twoPeopleUpdatingOneSymbolFromItsLibraryConvergeOnOneArtworkSet() throws {
        let (library, _, badge) = try Self.library()
        let v1 = LibrarySource(documentID: "0190a0d4-0000-7000-8000-00000000000a", name: "Marketing", headSeq: 40, state: library.state)
        let v2 = LibrarySource(documentID: v1.documentID, name: "Marketing", headSeq: 50, state: library.state)
        var world = OfflineRound()
        try world.shared(CopyFromLibrary(badge, from: v1))
        let symbol = try #require(Symbols.symbols(in: world.mine.state).first)
        try world.byMe(UpdateFromLibrary([symbol], from: v2))
        try world.byThem(UpdateFromLibrary([symbol], from: v2))
        let entries = world.measure().entries
        // The symbol is listed (both wrote its library link); its artwork reads as one set.
        let entry = try #require(entries.first { $0.node == symbol })
        #expect(!entry.kinds.isEmpty)
        #expect(Symbols.artwork(of: symbol, in: world.mine.state).count == 1)
        #expect(world.mine.state.liveChildren(symbol).count == 2)
        world.upload()
        #expect(Symbols.artwork(of: symbol, in: world.theirs.state) == Symbols.artwork(of: symbol, in: world.mine.state))
    }
}

/// Creates node trees (their sequences included, through `NodeCopier`) in one change.
struct CreateNodes: Command {
    var trees: [(parent: OpID, key: [UInt8], props: Wiretuner_Doc_V1_NodeProps)]
    var label: String { "Create" }

    init(_ trees: [(OpID, [UInt8], Wiretuner_Doc_V1_NodeProps)]) {
        self.trees = trees.map { (parent: $0.0, key: $0.1, props: $0.2) }
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for tree in trees {
            _ = try NodeCopier.create(NodeTree(props: tree.props), parent: tree.parent, position: tree.key, schema: state.schema, builder: &builder)
        }
    }
}
