import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-022: style packages, *Import…* with and without *Replace styles with the same name*, style
/// library files, cross-document paste with baked overrides, and names made unique on read.
@Suite struct StyleTransferTests {
    typealias F = StyleCommandFixture
    typealias S = StyleFixture

    /// A document with "Base" (a red fill) and "Callout" based on it (a 3 pt stroke), and a
    /// rectangle on its layer using "Callout".
    static func source() throws -> (replica: Replica, base: OpID, callout: OpID, object: OpID) {
        var (a, layer) = try F.document()
        let base = try S.create([S.props("Base", behavior: [.fills], fill: 0.2)], on: &a)[0]
        let callout = try S.create([S.props("Callout", behavior: [.fills, .strokes], stroke: 3)], on: &a)[0]
        try a.perform(RawOps([S.setParent(callout, base)]))
        let object = try F.objects([(callout, nil, false)], layer: layer, on: &a)[0]
        return (a, base, callout, object)
    }

    static func named(_ name: String, in state: EngineState) -> [OpID] {
        let resolver = GraphicStyleResolver(state)
        return GraphicStyleFields.styles(in: state, resolver).filter { state.props($0).style.common.name == name }
    }

    @Test func importingAChildImportsItsParentsOnce() throws {
        let (source, base, callout, _) = try Self.source()
        let both = StylePackage(styles: [callout, base], from: source.state)
        #expect(both.names == ["Callout", "Base"] && both.resources.isEmpty && !both.isEmpty)
        var (target, _) = try F.document()
        let change = try #require(try target.perform(ImportStyles(both)))
        #expect(change.label == "Import 2 styles")
        let resolver = GraphicStyleResolver(target.state)
        let imported = try #require(Self.named("Callout", in: target.state).first)
        let parent = try #require(Self.named("Base", in: target.state).first)
        #expect(Self.named("Base", in: target.state).count == 1)
        #expect(resolver.parent(of: imported) == parent)
        #expect(F.red(StyleStacks.look(chain: resolver.chain(of: imported), styles: resolver, state: target.state).look) == 0.2)

        // The child alone brings its parent (a resource); again, both under free names.
        let child = StylePackage(styles: [callout], from: source.state)
        #expect(child.resources.count == 1 && ImportStyles(child).label == "Import Style")
        try target.perform(ImportStyles(child))
        let again = try #require(Self.named("Callout 2", in: target.state).first)
        let parentAgain = try #require(Self.named("Base 2", in: target.state).first)
        #expect(GraphicStyleResolver(target.state).parent(of: again) == parentAgain)
        #expect(try target.perform(ImportStyles(child, selection: [])) == nil)
        #expect(ImportStyles(both, selection: [callout]).chosen.count == 1)
    }

    @Test func replacingStylesWithTheSameNameRedefinesThem() throws {
        let (source, _, callout, _) = try Self.source()
        var (target, layer) = try F.document()
        let existing = try S.create([S.props("Callout", role: .normal, fill: 0.9), S.props("Base", fill: 0.5)], on: &target)
        let object = try F.objects([(existing[0], nil, false)], layer: layer, on: &target)[0]
        try target.perform(ImportStyles(StylePackage(styles: [callout], from: source.state), replacingSameName: true))
        let resolver = GraphicStyleResolver(target.state)
        #expect(GraphicStyleFields.styles(in: target.state, resolver).count == 2, "no style was added")
        #expect(resolver.parent(of: existing[0]) == existing[1])
        #expect(resolver.role(of: existing[0]) == .normal, "the role is kept")
        #expect(F.red(F.look(object, target.state)) == 0.2 && F.width(F.look(object, target.state)) == 3)
        #expect(resolver.governs(existing[0]) == [.fills, .strokes])
    }

    @Test func styleLibraryFilesRoundTrip() throws {
        let (source, _, callout, _) = try Self.source()
        var package = StylePackage(styles: [callout], from: source.state)
        package.blobs = ["ab": Data([1, 2])]
        #expect(package.assetHashes.isEmpty)
        let read = try StylePackage(fileData: package.fileData)
        #expect(read == package && read.blobs == ["ab": Data([1, 2])])
        #expect(throws: StylePackage.FileError.notAStyleLibrary) { try StylePackage(fileData: Data("nope".utf8)) }
        let symbols = SymbolPackage(symbols: [NodeTree(props: .with { $0.symbol.common.name = "S" })])
        #expect(throws: StylePackage.FileError.notAStyleLibrary) { try StylePackage(fileData: Data(StylePackage.fileMagic + symbols.encoded())) }
        #expect(StylePackage(allStylesOf: source.state).names == ["Base", "Callout"])
    }

    @Test func pastingIntoADifferentSameNamedStyleLooksIdenticalWithThePlusSign() throws {
        let (source, _, _, object) = try Self.source()
        let look = F.look(object, source.state)
        let payload = ClipboardPayload(copying: [object], from: source.state, document: "doc-a").carryingLibrary(from: source.state)
        let library = try #require(payload.library)
        #expect(library.looks.count == 1 && library.package.resources.count == 2)
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded == payload)
        #expect(ClipboardLibrary(decoding: [0xFF]) == nil)
        #expect(ClipboardLibrary(decoding: Wire.field(2, [0x0A, 0x01])) == nil)

        // The destination's "Callout" is different: it is left alone and the object overrides it.
        // Other documents write as other replicas.
        var target = Replica(0xB)
        _ = try LayerFixture.layers(["L"], on: &target)
        let theirs = try S.create([S.props("Callout", fill: 0.9)], on: &target)[0]
        let change = try #require(try target.perform(PasteFromDocument(Paste(decoded))))
        #expect(change.label == "Paste")
        let pasted = try #require(change.createdObjects.first)
        #expect(F.styleRef(pasted, target.state) == theirs)
        #expect(Self.named("Callout", in: target.state) == [theirs])
        #expect(Self.named("Base", in: target.state).isEmpty, "the style left alone brings no parent")
        #expect(GraphicStyleFields.differences(F.look(pasted, target.state), look).isEmpty)
        #expect(!GraphicStyleDefaults.overrides(of: pasted, in: target.state).isEmpty, "the plus sign")

        // A destination without the style: created with its parent, nothing overridden.
        var empty = Replica(0xE)
        _ = try LayerFixture.layers(["L"], on: &empty)
        let fresh = try #require(try empty.perform(PasteFromDocument(Paste(decoded))))
        let copy = try #require(fresh.createdObjects.last)
        #expect(fresh.createdRoots == [copy], "the styles a paste brings are not selected")
        let style = try #require(F.styleRef(copy, empty.state))
        #expect(empty.state.props(style).style.common.name == "Callout")
        #expect(GraphicStyleResolver(empty.state).parent(of: style) == Self.named("Base", in: empty.state).first)
        #expect(GraphicStyleFields.differences(F.look(copy, empty.state), look).isEmpty)
        #expect(F.own(copy, empty.state).isEmpty)

        // No library: a plain paste.
        var plain = decoded
        plain.library = nil
        #expect(try empty.perform(PasteFromDocument(Paste(plain)))?.createdObjects.count == 1)
    }

    @Test func twoPeopleImportingTheSameStyleSeeNameAndName2() throws {
        let (source, _, callout, _) = try Self.source()
        let package = StylePackage(styles: [callout], from: source.state)
        var pair = Pair()
        try pair.a.perform(ImportStyles(package))
        try pair.b.perform(ImportStyles(package))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for state in [pair.a.state, pair.b.state] {
            let names = GraphicStyleFields.displayNames(in: state, GraphicStyleResolver(state))
            #expect(names.values.sorted() == ["Base", "Base 2", "Callout", "Callout 2"])
            let callouts = Self.named("Callout", in: state).sorted()
            #expect(names[callouts[0]] == "Callout" && names[callouts[1]] == "Callout 2")
        }
    }

    @Test func looksCarryEveryCategoryAndLibrariesRoundTrip() throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        var fill = Appearances.basicFill(red: 1, green: 0, blue: 0)
        fill.id = Wiretuner_Doc_V1_ElementId.with { $0.counter = 1 }
        var stroke = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)
        stroke.id = Wiretuner_Doc_V1_ElementId.with { $0.counter = 3 }
        var effect = Wiretuner_Doc_V1_Effect()
        effect.id = Wiretuner_Doc_V1_ElementId.with { $0.counter = 2 }
        props.style.appearance.fills = [fill]
        props.style.appearance.strokes = [stroke]
        props.style.appearance.effects = [effect]
        props.style.common.halftone.frequency = 60
        let look = StyleLook(props: props)
        #expect(look.look.stack.map(\.list) == [.fills, .effects, .strokes] && look.look.halftone?.frequency == 60)
        #expect(StyleLook(props: look.props) == look)
        let library = ClipboardLibrary(looks: [OpID(counter: 2, replica: 1): look, OpID(counter: 1, replica: 1): look])
        #expect(ClipboardLibrary(decoding: library.encoded()) == library && !library.isEmpty && ClipboardLibrary().isEmpty)
        #expect(ClipboardLibrary(decoding: Wire.field(1, [0xFF, 0xFF])) == nil)

        // Unstyled objects carry no look: the paste imports their swatch and bakes nothing.
        var source = Replica(0xA)
        let blue = try #require(try source.perform(AddSwatch(Color(red: 0, green: 0, blue: 1), name: "Blue"))).createdNodes[0]
        let rect = try #require(try source.perform(SymbolTransferTests.swatched(x: 0, swatch: blue))).createdObjects[0]
        let payload = ClipboardPayload(copying: [rect], from: source.state, document: "a").carryingLibrary(from: source.state)
        #expect(payload.library?.looks.isEmpty == true)
        var target = Replica(0xB)
        let change = try #require(try target.perform(PasteFromDocument(Paste(payload))))
        #expect(change.createdRoots.count == 1)
        #expect(target.state.liveChildren(WellKnown.swatches).map { target.state.props($0).swatch.common.name } == ["Blue"])
        // Nothing to carry: no library.
        var bare = Replica(0xC)
        let plain = try #require(try bare.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 1, height: 1)))).createdObjects[0]
        #expect(ClipboardPayload(copying: [plain], from: bare.state).carryingLibrary(from: bare.state).library == nil)
    }

    @Test func displayNamesSkipNumbersInUse() throws {
        var a = Replica(0xA)
        let ids = try S.create([S.props("Box"), S.props("Box 2"), S.props("Box")], on: &a)
        let names = GraphicStyleFields.displayNames(in: a.state, GraphicStyleResolver(a.state))
        #expect(names[ids[0]] == "Box" && names[ids[1]] == "Box 2" && names[ids[2]] == "Box 3")
    }
}

/// Appends raw ops as one change.
struct RawOps: Command {
    var ops: [Wiretuner_Doc_V1_Op]
    var label: String { "Raw" }

    init(_ ops: [Wiretuner_Doc_V1_Op]) {
        self.ops = ops
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for op in ops { builder.append(op) }
    }
}
