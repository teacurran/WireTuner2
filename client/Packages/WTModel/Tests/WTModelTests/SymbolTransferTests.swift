import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-013: symbol packages -- import from another document's state, symbol library files, and
/// paste of instances carrying their symbol (library.adoc, "Copying symbols between documents").
@Suite struct SymbolTransferTests {
    /// A rectangle at `x` filled with the swatch `swatch`.
    static func swatched(x: Double, swatch: OpID) -> CreateShape {
        var appearance = Appearances.standard
        var fill = Appearances.basicFill(red: 0, green: 0, blue: 1)
        fill.settings.basic.color = Wiretuner_Doc_V1_ColorRef()
        fill.settings.basic.color.swatch.id = swatch.proto
        appearance.fills = [fill]
        return CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .translation(x: x, y: 0), appearance: appearance)
    }

    static func swatchRef(_ node: OpID, in state: EngineState) -> OpID? {
        let fills = state.props(node).rect.appearance.fills
        guard let fill = fills.first, case .swatch(let ref)? = fill.settings.basic.color.ref else { return nil }
        return OpID(ref.id)
    }

    static func swatches(in state: EngineState) -> [OpID] { state.liveChildren(WellKnown.swatches) }

    @Test func importingTwoHundredSymbolsWithSharedSwatchesCreatesEachSwatchOnce() throws {
        var source = Replica(0xA)
        let blue = try #require(try source.perform(AddSwatch(Color(red: 0, green: 0, blue: 1), name: "Blue"))).createdNodes[0]
        let red = try #require(try source.perform(AddSwatch(Color(red: 1, green: 0, blue: 0), name: "Red"))).createdNodes[0]
        var symbols: [OpID] = []
        for index in 0..<200 {
            let rect = try #require(try source.perform(Self.swatched(x: Double(index), swatch: index.isMultiple(of: 2) ? blue : red))).createdObjects[0]
            symbols.append(try #require(try source.perform(CopyToSymbol([rect], name: "S\(index)"))).createdNodes[0])
        }
        let package = SymbolPackage(symbols: symbols, from: source.state)
        #expect(package.symbols.count == 200 && package.resources.count == 2 && package.names.first == "S0")

        var target = Replica(0xB)
        let existing = try #require(try target.perform(AddSwatch(Color(red: 0, green: 0, blue: 1), name: "Blue"))).createdNodes[0]
        let change = try #require(try target.perform(ImportSymbols(package)))
        #expect(change.label == "Import 200 symbols")
        #expect(Symbols.symbols(in: target.state).count == 200)
        // "Blue" matched by name; "Red" created once.
        let swatches = Self.swatches(in: target.state)
        #expect(swatches.count == 2 && swatches[0] == existing)
        let imported = Symbols.symbols(in: target.state)
        let firstRect = try #require(target.state.liveChildren(imported[0]).first)
        let secondRect = try #require(target.state.liveChildren(imported[1]).first)
        #expect(Self.swatchRef(firstRect, in: target.state) == existing)
        #expect(Self.swatchRef(secondRect, in: target.state) == swatches[1])
        #expect(target.state.props(swatches[1]).swatch.common.name == "Red")
        // Importing again copies the symbols under free names and still adds no swatch.
        try target.perform(ImportSymbols(package, selection: [symbols[0]]))
        #expect(Self.swatches(in: target.state).count == 2)
        #expect(target.state.props(Symbols.symbols(in: target.state).last!).symbol.common.name == "S0 2")
        #expect(ImportSymbols(package, selection: [symbols[0]]).label == "Import Symbol")
        #expect(try target.perform(ImportSymbols(package, selection: [])) == nil)
        target.undo()
        #expect(Symbols.symbols(in: target.state).count == 200)
    }

    @Test func nestedSymbolsAndOverridesPointAtTheCopies() throws {
        var source = Replica(0xA)
        let (inner, _, masters) = try SymbolFixture.converted(on: &source)
        let placed = try #require(try source.perform(PlaceInstance(inner, at: Point(x: 100, y: 100)))).createdNodes[0]
        try source.perform(SetOverride([placed], master: masters[0], value: .fill(SymbolFixture.red()), in: source.state))
        let outer = try #require(try source.perform(CopyToSymbol([placed], name: "Outer"))).createdNodes[0]
        let package = SymbolPackage(symbols: [outer], from: source.state)
        #expect(package.resources.map(\.collection) == [WellKnown.symbols])

        var target = Replica(0xB)
        try target.perform(ImportSymbols(package))
        let list = Symbols.symbols(in: target.state)
        #expect(list.count == 2)
        let copiedOuter = try #require(list.first { target.state.props($0).symbol.common.name == "Outer" })
        let copiedInner = try #require(list.first { $0 != copiedOuter })
        let instance = try #require(target.state.liveChildren(copiedOuter).first)
        #expect(Symbols.symbol(of: instance, in: target.state) == copiedInner)
        let override = try #require(Symbols.liveOverrides(of: instance, in: target.state).keys.first)
        #expect(override.master == target.state.liveChildren(copiedInner)[0])
    }

    @Test func pasteReusesAnIdenticalSymbolAndRenamesADifferentOne() throws {
        var source = Replica(0xA)
        let (symbol, instance, _) = try SymbolFixture.converted(on: &source)
        let payload = ClipboardPayload(copying: [instance], from: source.state)
        let package = SymbolPackage(referencedBy: payload.nodes, from: source.state)
        #expect(package.resources.count == 1 && package.symbols.isEmpty && !package.isEmpty)

        // The same artwork under the same name: the pasted instance uses it.
        var same = Replica(0xB)
        let blob = SymbolPackage(symbols: [symbol], from: source.state)
        try same.perform(ImportSymbols(blob))
        let existing = Symbols.symbols(in: same.state)[0]
        let paste = try #require(try same.perform(PasteWithSymbols(Paste(payload), package: package)))
        #expect(paste.label == "Paste")
        #expect(Symbols.symbols(in: same.state) == [existing])
        #expect(Symbols.symbol(of: paste.createdObjects[0], in: same.state) == existing)

        // A different symbol of the same name: the pasted one is added as "Symbol 1 2".
        var different = Replica(0xC)
        let rect = try #require(try different.perform(SymbolFixture.rect(x: 50))).createdObjects[0]
        try different.perform(ConvertToSymbol([rect], name: source.state.props(symbol).symbol.common.name))
        try different.perform(PasteWithSymbols(Paste(payload), package: package))
        let names = Symbols.symbols(in: different.state).map { different.state.props($0).symbol.common.name }
        #expect(names == ["Symbol 1", "Symbol 1 2"])
        // Pasting again reuses the copy made by the first paste.
        try different.perform(PasteWithSymbols(Paste(payload), package: package))
        #expect(Symbols.symbols(in: different.state).count == 2)
    }

    @Test func twoPeopleImportingTheSameSymbolConcurrentlyMakeTwoSymbols() throws {
        var source = Replica(0xA)
        let (symbol, _, _) = try SymbolFixture.converted(on: &source)
        let package = SymbolPackage(symbols: [symbol], from: source.state)
        var pair = Pair()
        try pair.a.perform(ImportSymbols(package))
        try pair.b.perform(ImportSymbols(package))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Symbols.symbols(in: pair.a.state).count == 2)
    }

    @Test func assetsMatchByHash() throws {
        var source = Replica(0xA)
        var asset = Wiretuner_Doc_V1_NodeProps()
        asset.asset.sha256 = Data(repeating: 0xAB, count: 32)
        asset.asset.common.name = "photo.png"
        let assetID = try #require(try source.perform(OpsCommand("Asset", ops: [Ops.create(parent: .wellKnown(9), position: [0x80], props: asset)])))
            .createdNodes[0]
        var image = Wiretuner_Doc_V1_NodeProps()
        image.svgAnimation.asset.id = assetID.proto
        let layer = try #require(try source.perform(SymbolFixture.rect(x: 0))).createdObjects[0]
        let parent = try #require(source.state.store.placement(layer)?.parent)
        let imageID = try #require(try source.perform(OpsCommand("Image", ops: [Ops.create(parent: parent, position: [0xF0], props: image)])))
            .createdNodes[0]
        let symbol = try #require(try source.perform(CopyToSymbol([imageID], name: "Pic"))).createdNodes[0]
        let package = SymbolPackage(symbols: [symbol], from: source.state, blobs: ["ab": Data([1])])
        #expect(package.assetHashes == [String(repeating: "ab", count: 32)])

        var target = Replica(0xB)
        asset.asset.common.name = "renamed.png"
        let existing = try #require(try target.perform(OpsCommand("Asset", ops: [Ops.create(parent: .wellKnown(9), position: [0x80], props: asset)])))
            .createdNodes[0]
        try target.perform(ImportSymbols(package))
        #expect(target.state.liveChildren(.wellKnown(9)) == [existing])
        let copy = try #require(target.state.liveChildren(Symbols.symbols(in: target.state)[0]).first)
        #expect(OpID(target.state.props(copy).svgAnimation.asset.id) == existing)
    }

    @Test func symbolLibraryFilesRoundTrip() throws {
        var source = Replica(0xA)
        let blue = try #require(try source.perform(AddSwatch(Color(red: 0, green: 0, blue: 1), name: "Blue"))).createdNodes[0]
        let rect = try #require(try source.perform(Self.swatched(x: 0, swatch: blue))).createdObjects[0]
        let symbol = try #require(try source.perform(CopyToSymbol([rect], name: "Dot"))).createdNodes[0]
        let package = SymbolPackage(symbols: [symbol], from: source.state, blobs: ["cafe": Data([1, 2, 3])])
        let file = package.fileData
        #expect(file.starts(with: SymbolPackage.fileMagic) && SymbolPackage.fileExtension == "wtsymbols")
        let read = try SymbolPackage(fileData: file)
        #expect(read == package)
        #expect(throws: SymbolPackage.FileError.notASymbolLibrary) { try SymbolPackage(fileData: Data("nope".utf8)) }
        #expect(throws: SymbolPackage.FileError.notASymbolLibrary) { try SymbolPackage(fileData: Data(SymbolPackage.fileMagic + [0x08, 0x01])) }
        #expect(SymbolPackage(decoding: Wire.field(1, [0xFF])) == nil)
        #expect(SymbolPackage(decoding: Wire.field(2, ClipboardPayload(nodes: [NodeTree(props: .init())], sourceDocument: "x").encoded())) == nil)
        #expect(SymbolPackage(decoding: Wire.field(2, [0xFF])) == nil)
        #expect(SymbolPackage(decoding: Wire.field(3, Wire.field(1, [0x61]))) == nil)
        #expect(SymbolPackage(decoding: Wire.field(9, [1]))?.isEmpty == true)
        var target = Replica(0xB)
        try target.perform(ImportSymbols(read))
        #expect(Symbols.symbols(in: target.state).count == 1 && Self.swatches(in: target.state).count == 1)
    }

    @Test func referencesAreFoundThroughTheSchema() {
        let schema = Schema.generated
        var props = Wiretuner_Doc_V1_NodeProps()
        props.instance.symbol.id = OpID(counter: 5, replica: 9).proto
        let tree = NodeTree(props: props)
        #expect(ReferenceRewriting.targets(in: tree, schema: schema) == [OpID(counter: 5, replica: 9)])
        let moved = ReferenceRewriting.rewrite(tree, schema: schema) { $0 == OpID(counter: 5, replica: 9) ? OpID(counter: 1, replica: 2) : nil }
        #expect(OpID(moved.props.instance.symbol.id) == OpID(counter: 1, replica: 2))
        #expect(ReferenceRewriting.walk(Schema.root, [0xFF], schema: schema, clearingElements: false) { _ in nil } == [0xFF])
        #expect(SymbolImporter.caseName(.symbol(.init())) == "symbol")
        #expect(SymbolImporter.isName("Star", variantOf: "Star") && SymbolImporter.isName("Star 12", variantOf: "Star"))
        #expect(!SymbolImporter.isName("Star x", variantOf: "Star") && !SymbolImporter.isName("Stars", variantOf: "Star"))
        #expect(!SymbolImporter.isName("Star ", variantOf: "Star"))
    }
}
