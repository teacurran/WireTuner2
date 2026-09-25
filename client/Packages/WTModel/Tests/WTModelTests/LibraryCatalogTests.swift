import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// COLLAB-015: the team library catalog and copy-with-provenance commands (sharing.adoc).
@Suite struct LibraryCatalogTests {
    /// A library document: the swatch Brand; a style Callout whose fill is Brand; a symbol Badge
    /// of `members` rectangles in a group, each filled with Brand; an asset.
    struct Library {
        var replica = Replica(0x11B)
        var brand: OpID, callout: OpID, badge: OpID, asset: OpID
        var source: LibrarySource { LibrarySource(documentID: "0190a0d4-0000-7000-8000-00000000000a", name: "Marketing", headSeq: 40, state: replica.state) }

        init(members: Int = 3) throws {
            let brand = try ColorFixture.add(&replica, Color(red: 0.8, green: 0.1, blue: 0.1), name: "Brand")
            self.brand = brand
            let reference = Wiretuner_Doc_V1_ColorRef.with { $0.swatch.id = brand.proto }
            var style = StyleFixture.props("Callout", fill: 0.5)
            style.style.appearance.fills[0].settings.basic.color = reference
            callout = try StyleFixture.create([style], on: &replica)[0]
            let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
            var ops: [Wiretuner_Doc_V1_Op] = []
            for index in 0..<members {
                var props = ShapeFixture.rect()
                props.rect.appearance.fills = []
                ops.append(Ops.create(parent: layer, position: [0x40, UInt8(index / 200 + 1), UInt8(index % 200 + 1)], props: props))
            }
            let rects = try replica.perform(OpsCommand("Rects", ops: ops))!.createdNodes
            try replica.perform(AddAppearance.fill(rects, .with { $0.settings.kind = .basic; $0.settings.basic.color = reference }))
            let group = try replica.perform(GroupObjects(rects))!.createdObjects[0]
            badge = try replica.perform(ConvertToSymbol([group], name: "Badge"))!.createdNodes[0]
            asset = try replica.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: .with {
                $0.asset.sha256 = Data(repeating: 3, count: 32)
            })]))!.createdNodes[0]
        }
    }

    static func provenance(_ node: OpID, _ state: EngineState) -> Wiretuner_Doc_V1_LibraryProvenance? {
        LibraryCopying.provenance(of: node, in: state)
    }

    @Test func theCatalogListsEachLibrarysItemsByKind() throws {
        let library = try Library()
        var other = Replica(0x22)
        try ColorFixture.add(&other, Color(red: 0, green: 0, blue: 1), name: "Sky")
        let catalog = LibraryCatalog([LibrarySource(documentID: "z", name: "Web", headSeq: 1, state: other.state), library.source])
        #expect(catalog.libraries.map(\.name) == ["Marketing", "Web"])
        #expect(catalog.sections(.swatch).map(\.name) == ["Marketing", "Web"])
        #expect(catalog.sections(.swatch)[0].items.map(\.name) == ["Brand"], "the protected defaults are not offered")
        #expect(catalog.sections(.style).map { $0.items.map(\.name) } == [["Callout"]])
        #expect(catalog.sections(.symbol).map { $0.items.map(\.name) } == [["Badge"]])
        #expect(catalog.sections(.symbol)[0].items[0].id.hasPrefix(library.source.documentID + "/"))
        #expect(catalog.library("z")?.name == "Web" && catalog.library("nope") == nil)
    }

    struct Opener: LibraryStoreOpening {
        let sources: [LibrarySource]
        func cachedLibraries() async throws -> [LibrarySource] { sources }
    }

    @Test func theCatalogLoadsFromTheCachedStores() async throws {
        let library = try Library()
        let catalog = try await LibraryCatalog.load(from: Opener(sources: [library.source]))
        #expect(catalog.libraries.count == 1)
    }

    @Test func copyingASymbolOf200NodesIsOneChangeWithFreshIdsAndLocalReferences() throws {
        let library = try Library(members: 199)
        var a = Replica(0xA)
        let command = CopyFromLibrary(library.badge, from: library.source)
        #expect(command.label == "Add symbol \"Badge\" from Marketing library")
        let change = try #require(try a.perform(command))
        #expect(a.sent.count == 1)
        let symbols = Symbols.symbols(in: a.state)
        let copy = try #require(symbols.first)
        #expect(symbols.count == 1 && copy != library.badge)
        let group = try #require(a.state.liveChildren(copy).first)
        let members = a.state.liveChildren(group)
        #expect(members.count == 199 && members.allSatisfy { $0.replica == 0xA })
        #expect(Objects.parent(of: members[0], in: a.state) == group)
        // The swatch came along; the rectangles reference the local copy.
        let swatches = SwatchList(a.state).swatches.filter { $0.name == "Brand" }
        let brand = try #require(swatches.first?.id)
        #expect(swatches.count == 1 && brand != library.brand)
        #expect(a.state.props(members[0]).rect.appearance.fills[0].settings.basic.color.swatch.id == brand.proto)
        #expect(Self.provenance(copy, a.state)?.sourceNode == library.badge.proto)
        #expect(Self.provenance(copy, a.state)?.sourceServerSeq == 40)
        #expect(Self.provenance(brand, a.state)?.sourceNode == library.brand.proto)
        #expect(change.createdNodes.count == 1 + 1 + 199 + 1)
        // Copying the style reuses the swatch copy.
        let style = try #require(try a.perform(CopyFromLibrary(library.callout, from: library.source)))
        #expect(style.label == "Add style \"Callout\" from Marketing library")
        #expect(SwatchList(a.state).swatches.filter { $0.name == "Brand" }.count == 1)
        let localStyle = style.createdNodes[0]
        #expect(a.state.props(localStyle).style.appearance.fills[0].settings.basic.color.swatch.id == brand.proto)
        #expect(CopyFromLibrary(library.brand, from: library.source).label == "Add swatch \"Brand\" from Marketing library")
        #expect(throws: LibraryCopyError.notInLibrary(library.asset)) { try a.perform(CopyFromLibrary(library.asset, from: library.source)) }
    }

    @Test func assetsAreReusedByHash() throws {
        var library = try Library()
        // A symbol whose image names the asset.
        let layer = try #require(library.replica.state.liveChildren(WellKnown.layers).first)
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.dpiX = 72
        image.image.dpiY = 72
        let imageNode = try library.replica.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0xF0], props: image)]))!.createdNodes[0]
        let symbol = try library.replica.perform(ConvertToSymbol([imageNode], name: "Photo"))!.createdNodes[0]
        var instanceProps = Wiretuner_Doc_V1_NodeProps()
        instanceProps.instance.symbol.id = symbol.proto
        instanceProps.instance.overrides = [.with { $0.masterNode = imageNode.proto; $0.property = .image; $0.image.id = library.asset.proto }]
        let host = try library.replica.perform(OpsCommand("Host", ops: [Ops.create(parent: library.badge, position: [0xF8], props: instanceProps)]))!.createdNodes[0]
        _ = host
        var a = Replica(0xA)
        let local = try a.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: .with {
            $0.asset.sha256 = Data(repeating: 3, count: 32)
        })]))!.createdNodes[0]
        try a.perform(CopyFromLibrary(library.badge, from: library.source))
        #expect(a.state.liveChildren(OpID.wellKnown(9)) == [local], "the asset with the same hash is reused")
        #expect(Symbols.symbols(in: a.state).count == 2, "the nested symbol came along")
    }

    @Test func concurrentCopiesOfOneSwatchMakeTwoNodes() throws {
        let library = try Library()
        var pair = Pair()
        let one = try #require(try pair.a.perform(CopyFromLibrary(library.brand, from: library.source)))
        let two = try #require(try pair.b.perform(CopyFromLibrary(library.brand, from: library.source)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let copies = [one.createdNodes[0], two.createdNodes[0]]
        #expect(copies.allSatisfy { pair.a.state.isLive($0) && pair.b.state.isLive($0) })
        try pair.a.perform(RemoveSwatches([copies[0]]))
        pair.sync()
        #expect(!pair.b.state.isLive(copies[0]) && pair.b.state.isLive(copies[1]))
    }

    @Test func updateRewritesOnlyWhatDiffersAndDetachForgetsTheOrigin() throws {
        var library = try Library()
        var a = Replica(0xA)
        let swatch = try #require(try a.perform(CopyFromLibrary(library.brand, from: library.source))).createdNodes[0]
        let style = try #require(try a.perform(CopyFromLibrary(library.callout, from: library.source))).createdNodes[0]
        // Nothing changed: only the head is bumped.
        var source = library.source
        source.headSeq = 41
        let bump = try #require(try a.perform(UpdateFromLibrary([swatch], from: source)))
        #expect(bump.label == "Update from Library" && bump.ops.count == 1)
        #expect(Self.provenance(swatch, a.state)?.sourceServerSeq == 41)
        // The library renames the swatch and recolours the style's fill.
        try library.replica.perform(RenameSwatch(library.brand, to: "Brand red"))
        var fill = library.replica.state.props(library.callout).style.appearance.fills[0]
        let element = try #require(OpID(element: fill.id))
        fill.settings.basic.color = Appearances.inline(red: 0, green: 0.5, blue: 0)
        try library.replica.perform(OpsCommand("Recolour", ops: [Ops.set(library.callout, [RegisterPath([154, 6, 1]).element(element).child(3).child(2).child(1)],
                                                                         values: .with { $0.style.appearance.fills = [fill] })]))
        source = library.source
        source.headSeq = 50
        let update = try #require(try a.perform(UpdateFromLibrary([swatch, style], from: source)))
        let sets = update.ops.filter { if case .set = $0.op { true } else { false } }
        #expect(sets.contains { $0.set.paths.map(RegisterPath.init) == [SwatchFields.name] }, "only the name register of the swatch")
        #expect(SwatchList(a.state)[swatch]?.name == "Brand red")
        #expect(a.state.props(style).style.appearance.fills.count == 1)
        #expect(a.state.props(style).style.appearance.fills[0].settings.basic.color == Appearances.inline(red: 0, green: 0.5, blue: 0))
        #expect(Self.provenance(style, a.state)?.sourceServerSeq == 50)
        // Detach.
        let detach = try #require(try a.perform(DetachFromLibrary([swatch, style, WellKnown.layers])))
        #expect(detach.label == "Detach from Library" && detach.ops.count == 2)
        #expect(Self.provenance(swatch, a.state) == nil && Self.provenance(style, a.state) == nil)
        #expect(throws: LibraryCopyError.notFromLibrary(swatch)) { try a.perform(UpdateFromLibrary([swatch], from: source)) }
    }

    @Test func updatingASymbolCopiesItsArtworkAgain() throws {
        var library = try Library()
        var a = Replica(0xA)
        let copy = try #require(try a.perform(CopyFromLibrary(library.badge, from: library.source))).createdNodes.first { a.state.nodeKind($0) == .symbol }!
        let before = a.state.liveChildren(copy)
        try library.replica.perform(RenameSymbolForTest(library.badge, "Badge 2"))
        let update = try #require(try a.perform(UpdateFromLibrary([copy], from: library.source)))
        #expect(update.label == "Update from Library")
        #expect(before.allSatisfy { !a.state.isLive($0) })
        #expect(a.state.liveChildren(copy).count == 1 && a.state.liveChildren(copy) != before)
        #expect(a.state.props(copy).symbol.common.name == "Badge 2")
        // A source deleted from the library cannot update.
        try library.replica.perform(OpsCommand("Remove", ops: [Ops.setDeleted(library.badge)]))
        #expect(throws: LibraryCopyError.notInLibrary(library.badge)) { try a.perform(UpdateFromLibrary([copy], from: library.source)) }
        var other = library.source
        other.documentID = "elsewhere"
        #expect(throws: LibraryCopyError.notFromLibrary(copy)) { try a.perform(UpdateFromLibrary([copy], from: other)) }
    }

    @Test func updateVersusConcurrentLocalEditResolvesByOpId() throws {
        var library = try Library()
        var pair = Pair()
        let swatch = try #require(try pair.a.perform(CopyFromLibrary(library.brand, from: library.source))).createdNodes[0]
        pair.sync()
        try library.replica.perform(RenameSwatch(library.brand, to: "Library name"))
        try pair.a.perform(UpdateFromLibrary([swatch], from: library.source))
        try pair.b.perform(RenameSwatch(swatch, to: "Local name"))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(SwatchList(pair.a.state)[swatch]?.name == "Local name", "B's write carries the greater OpId")
        #expect(Self.provenance(swatch, pair.a.state)?.libraryDocumentID == library.source.documentID)
    }

    @Test func theBadgeNamesTheLibraryOrSaysItIsInaccessible() throws {
        let library = try Library()
        var a = Replica(0xA)
        let swatch = try #require(try a.perform(CopyFromLibrary(library.brand, from: library.source))).createdNodes[0]
        var newer = library.source
        newer.headSeq = 90
        let badge = try #require(LibraryBadge.of(swatch, in: a.state, catalog: LibraryCatalog([newer])))
        #expect(badge.libraryName == "Marketing" && badge.updateAvailable && badge.copiedSeq == 40 && badge.sourceNode == library.brand)
        #expect(badge.tooltip == "From Marketing (a newer version is available)")
        let current = try #require(LibraryBadge.of(swatch, in: a.state, catalog: LibraryCatalog([library.source])))
        #expect(!current.updateAvailable && current.tooltip == "From Marketing")
        let hidden = try #require(LibraryBadge.of(swatch, in: a.state, catalog: LibraryCatalog([])))
        #expect(hidden.libraryName == nil && hidden.tooltip == "From a library you can't access")
        #expect(LibraryBadge.of(WellKnown.layers, in: a.state, catalog: LibraryCatalog([])) == nil)
    }
}

/// A rename of a symbol for the library document in these tests.
struct RenameSymbolForTest: Command {
    var symbol: OpID
    var name: String
    init(_ symbol: OpID, _ name: String) {
        self.symbol = symbol
        self.name = name
    }
    var label: String { "Rename" }
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.set(symbol, [SymbolFields.name], values: .with { $0.symbol.common.name = name }))
    }
}
