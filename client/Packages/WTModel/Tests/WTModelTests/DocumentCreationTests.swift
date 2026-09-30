import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DOC-019: new documents from the built-in template or a library template (creating-opening.adoc).
@Suite struct DocumentCreationTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)

    /// The vector pinning the built-in initial change's hash (both engines replay it).
    static let vector = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../crdt-conformance/vectors/changes/new-document-built-in.textproto")
        .standardizedFileURL

    /// The built-in initial change as the vector holds it: replica 7, seq 1, from counter 1.
    static func builtInChange() throws -> Wiretuner_Doc_V1_Change {
        var core = DocumentCore(state: EngineState(), replica: 7)
        return try #require(try core.perform(CreateDocument(), recording: DocumentCore.Recording(limit: 1, now: now))?.change)
    }

    @Test func aBuiltInDocumentHasOnePageDefaultSettingsAndOneCreatedChange() throws {
        let core = try DocumentCreation.newDocument(from: .builtIn, replica: 0xA, now: Self.now)
        let pages = PageList(core.state)
        #expect(!pages.isSynthesized && pages.pages.count == 1)
        #expect(pages.pages[0].geometry == .letter && pages.pages[0].rect == DocumentCreation.builtInPage)
        #expect(pages.masters.isEmpty && pages.settings == DocumentSettings(EngineState()))
        #expect(core.nextSeq == 2, "one change")
        #expect(core.undoStack == UndoStack(), "not an undo step")
        let change = try Self.builtInChange()
        #expect(change.label == "Created")
        #expect(!SwatchList(core.state).swatches.isEmpty, "the default swatches")
        // A document that already has content gets nothing.
        var again = core
        #expect(try again.perform(CreateDocument(), recording: DocumentCore.Recording(limit: 1, now: Self.now)) == nil)
    }

    /// `change` with its fractional positions cleared (they carry random jitter, crdt-model.adoc
    /// "Fractional positions") and its wall time.
    static func shape(_ change: Wiretuner_Doc_V1_Change) -> Wiretuner_Doc_V1_Change {
        var copy = change
        copy.wallTimeMs = 0
        copy.ops = copy.ops.map { op in
            var op = op
            if case .create = op.op { op.create.position = Data() }
            if case .elementInsert = op.op { op.elementInsert.positions = op.elementInsert.positions.map { _ in Data() } }
            return op
        }
        return copy
    }

    @Test func theBuiltInChangeIsTheConformanceVectorsUpToPositions() throws {
        let change = try Self.builtInChange()
        let text = try String(contentsOf: Self.vector, encoding: .utf8)
        let expected = try #require(text.firstMatch(of: /state_hash: "([0-9a-f]{64})"/)?.1)
        let body = try #require(text.firstMatch(of: /setup \{\n  change \{\n((?s).*)\n  \}\n\}\nexpect/)?.1)
        let stored = try Wiretuner_Doc_V1_Change(textFormatString: String(body))
        #expect(Self.shape(stored) == Self.shape(change), "the vector holds a built-in initial change (regenerate it with WT_RECORD_VECTORS=1 when the template changes)")
        var state = EngineState()
        state.apply(stored, serverSeq: 1)
        #expect(StateHash.of(state.store).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() == String(expected))
    }

    /// A template document: a master, guides, a style, a swatch, a symbol, a custom page size
    /// and a custom unit, the units set to it, and one object.
    static func template() throws -> Replica {
        var a = Replica(0x7E)
        a.core = try DocumentCreation.newDocument(from: .builtIn, replica: 0x7E, now: now)
        let page = PageList(a.state).pages[0].id
        try a.perform(NewMasterPage(from: page))
        try a.perform(AddGuides(on: [page], axis: .vertical, at: [36, 72]))
        try a.perform(AddSwatch(Color(red: 0.2, green: 0.3, blue: 0.4), name: "Brand"))
        try a.perform(AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)))
        try a.perform(AddCustomUnit(name: "Beard", amount: 0.1, base: .millimeters))
        let unit = try #require(DocumentSettings(a.state).customUnits.first)
        try a.perform(SetUnits(.custom(unit.id)))
        let shape = try a.perform(SymbolFixture.rect(x: 7000))!.createdObjects[0]
        try a.perform(ConvertToSymbol([shape], name: "Badge"))
        try a.perform(SymbolFixture.rect(x: 7100))
        return a
    }

    @Test func aDocumentFromALibraryTemplateHoldsACopyWithFreshIds() throws {
        let source = try Self.template()
        let core = try DocumentCreation.newDocument(from: .document(source.state, name: "Business card"), replica: 0xB, now: Self.now)
        #expect(core.nextSeq == 2 && core.undoStack == UndoStack())
        let pages = PageList(core.state), originals = PageList(source.state)
        #expect(pages.pages.count == 1 && pages.masters.map(\.name) == originals.masters.map(\.name))
        #expect(pages.pages[0].guides.map(\.position) == originals.pages[0].guides.map(\.position))
        #expect(pages.pages[0].id != originals.pages[0].id, "fresh ids")
        let settings = DocumentSettings(core.state)
        #expect(settings.customPageSizes.map(\.name) == ["Card"] && settings.customUnits.map(\.name) == ["Beard"])
        if case .custom(let id) = settings.units { #expect(id == settings.customUnits[0].id) } else { Issue.record("the custom unit") }
        #expect(SwatchList(core.state).swatches.map(\.name) == SwatchList(source.state).swatches.map(\.name))
        #expect(Symbols.symbols(in: core.state).map { core.state.props($0).symbol.common.name } == ["Badge"])
        #expect(Symbols.symbols(in: core.state) != Symbols.symbols(in: source.state))
        #expect(Symbols.instanceIndex(in: core.state).values.flatMap { $0 }.count == 1, "the instance points at the copied symbol")
        #expect(CreateDocument(.document(source.state, name: "Business card")).label == "Created from Business card")
        #expect(CreateDocument(.document(source.state, name: "")).label == "Created")
        let all = Set(core.state.store.children(WellKnown.layers).flatMap { core.state.store.children($0) })
        #expect(all.allSatisfy { $0.replica == 0xB }, "every node written by the new document's replica")
        // Styles, masters, custom sizes and units, swatches: copied, each with a fresh id.
        let styles = OpID.wellKnown(6)
        let copiedStyles = core.state.store.children(styles), sourceStyles = source.state.store.children(styles)
        #expect(!copiedStyles.isEmpty && copiedStyles.count == sourceStyles.count, "the template's styles")
        let sourceSettings = DocumentSettings(source.state)
        let fresh: [(String, [OpID], [OpID])] = [
            ("styles", copiedStyles, sourceStyles),
            ("masters", pages.masters.map(\.id), originals.masters.map(\.id)),
            ("custom sizes", settings.customPageSizes.map(\.id), sourceSettings.customPageSizes.map(\.id)),
            ("custom units", settings.customUnits.map(\.id), sourceSettings.customUnits.map(\.id)),
            ("swatches", SwatchList(core.state).swatches.map(\.id), SwatchList(source.state).swatches.map(\.id)),
        ]
        for (what, copied, originalIDs) in fresh {
            #expect(!copied.isEmpty && Set(copied).isDisjoint(with: originalIDs), "fresh \(what) ids")
            #expect(copied.allSatisfy { $0.replica == 0xB }, "\(what) written by the new document's replica")
        }
    }

    @Test func documentIDsAreUUIDv7() {
        let id = DocumentCreation.newDocumentID(now: Date(timeIntervalSince1970: 1_700_000_000), random: [UInt8](repeating: 0xFF, count: 10))
        #expect(id.count == 36)
        #expect(id.hasPrefix("018bcfe5-6800-7fff-bfff-ffffffffffff".prefix(15)))
        #expect(Array(id)[14] == "7" && "89ab".contains(Array(id)[19]))
        #expect(DocumentCreation.newDocumentID() != DocumentCreation.newDocumentID())
        #expect(DocumentCreation.newDocumentID(random: [1]).count == 36, "short randomness is padded")
    }

    /// Writes the vector's change (run with WT_RECORD_VECTORS=1, then fill in the hashes the
    /// conformance run reports).
    @Test func recordTheVector() throws {
        guard ProcessInfo.processInfo.environment["WT_RECORD_VECTORS"] == "1" else { return }
        let change = try Self.builtInChange()
        var body = change.textFormatString().split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
        body = body.replacingOccurrences(of: "\n    ops", with: "\n    ops")
        let text = """
            # crdt-conformance/vectors/changes/new-document-built-in.textproto (DOC-019; schema: crdt-conformance/schema/vector.proto)
            name: "changes/new-document-built-in"
            description: "A new document's initial change from the built-in template (WTModel's CreateDocument, label Created): one Letter page centred on the pasteboard, the protected default swatches and the default styles.  Pins the hash every engine must reach from it."
            setup {
              change {
            \(body)
              }
            }
            expect {
              state_hash: "\(String(repeating: "0", count: 64))"
              snapshot_hash: "\(String(repeating: "0", count: 64))"
            }

            """
        try text.write(to: Self.vector, atomically: true, encoding: .utf8)
    }
}
