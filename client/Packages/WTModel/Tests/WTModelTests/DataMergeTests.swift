import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The two-replica merge tests of DATA-003, DATA-011 and DATA-020 (data-merge.adoc and
/// scripting.adoc, "Merge semantics"): each through two in-process replicas exchanging changes.
@Suite struct DataMergeTests {
    static func converged(_ pair: inout Pair) {
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    @Test func renameVersusBindKeepsTheBindingUnderTheNewName() throws {
        var pair = Pair()
        let field = try DataFixture.fields(&pair.a, ["first_name"])[0]
        let node = try TextFixture.block(&pair.a, "x")
        Self.converged(&pair)
        try pair.a.perform(RenameField(field, to: "given_name"))
        try pair.b.perform(BindToField([node], field: field, kind: .text))
        Self.converged(&pair)
        for replica in [pair.a, pair.b] {
            let binding = try #require(DataModel(replica.state).binding(of: node, in: replica.state))
            #expect(binding.resolved?.name == "given_name")
        }
    }

    @Test func deleteVersusPlaceholderReadsMissingThenRestores() throws {
        var pair = Pair()
        let field = try DataFixture.fields(&pair.a, ["city"])[0]
        let node = try TextFixture.block(&pair.a, "In ")
        Self.converged(&pair)
        try pair.a.perform(DeleteField(field))
        try pair.b.perform(InsertPlaceholder(node: node, at: .end, field: field))
        Self.converged(&pair)
        // The live notice: the field A deleted is used by B's placeholder.
        let removed = DataNotices.fieldsRemoved(before: pair.b.state, after: pair.b.state)
        #expect(removed.isEmpty)
        for replica in [pair.a, pair.b] {
            #expect(DataModel(replica.state).placeholders(in: TextFixture.text(replica, node)).map(\.label) == ["{{missing}}"])
        }
        try pair.b.perform(RestoreField(field))
        Self.converged(&pair)
        for replica in [pair.a, pair.b] {
            #expect(DataModel(replica.state).placeholders(in: TextFixture.text(replica, node)).map(\.label) == ["{{city}}"])
        }
    }

    @Test func fieldRemovedNoticeNamesTheUses() throws {
        var a = Replica(0xA)
        let field = try DataFixture.fields(&a, ["city", "unused"])
        _ = try DataFixture.placeholderBlock(&a, "", field: field[0], at: 0)
        let before = a.state
        try a.perform(DeleteField(field[0]))
        try a.perform(DeleteField(field[1]))
        let notice = DataNotices.fieldsRemoved(before: before, after: a.state)
        #expect(notice == [DataNotices.FieldRemoved(field: field[0], name: "city", uses: 1)])
        #expect(DataNotices.fieldsRemoved(before: a.state, after: a.state).isEmpty)
    }

    @Test func concurrentDuplicateFieldsAreBothLiveAndMappingsHoldById() throws {
        var pair = Pair()
        let source = try DataFixture.source(&pair.a)
        Self.converged(&pair)
        let a = try DataFixture.fields(&pair.a, ["email"])[0]
        let b = try DataFixture.fields(&pair.b, ["email"])[0]
        try pair.a.perform(SetMapping(source, field: a, path: "E-mail"))
        try pair.b.perform(SetMapping(source, field: b, path: "mail"))
        Self.converged(&pair)
        for replica in [pair.a, pair.b] {
            let model = DataModel(replica.state)
            #expect(model.fields.count == 2 && Set(model.fields.map(\.displayName)) == ["email", "email (2)"])
            #expect(model.path(of: model.field(a)!, in: model.activeSource) == "E-mail" && model.path(of: model.field(b)!, in: model.activeSource) == "mail")
        }
    }

    @Test func fieldRenameVersusTypeChangeBothKept() throws {
        var pair = Pair()
        let field = try DataFixture.fields(&pair.a, ["price"])[0]
        Self.converged(&pair)
        try pair.a.perform(RenameField(field, to: "cost"))
        try pair.b.perform(SetFieldType(field, to: .number))
        Self.converged(&pair)
        let info = try #require(DataModel(pair.a.state).field(field))
        #expect(info.name == "cost" && info.kind == .number)
    }

    @Test func sourceURLVersusHeaderAndKindSwitch() throws {
        var pair = Pair()
        let source = try DataFixture.source(&pair.a, kind: .http) { $0.http.url = "https://a.example.com" }
        Self.converged(&pair)
        var spec = Wiretuner_Doc_V1_DataSourceSpec()
        spec.http.url = "https://b.example.com"
        try pair.a.perform(EditSource(source, spec: spec, paths: [[4, 2]]))
        try pair.b.perform(SetSourceHeaders(source, [("Accept", "application/json")]))
        Self.converged(&pair)
        let merged = try #require(DataModel(pair.a.state).source(source))
        #expect(merged.spec.http.url == "https://b.example.com" && merged.spec.http.headers.map(\.name) == ["Accept"])
    }

    @Test func concurrentSamplesKeepOneWholeValue() throws {
        var pair = Pair()
        let source = try DataFixture.source(&pair.a)
        Self.converged(&pair)
        func sample(_ byte: UInt8, _ count: UInt32) -> Wiretuner_Doc_V1_EmbeddedRecords {
            .with { $0.blobSha256 = Data(repeating: byte, count: 32); $0.mediaType = "text/csv"; $0.recordCount = count }
        }
        try pair.a.perform(SetSample(source, sample(1, 5)))
        try pair.b.perform(SetSample(source, sample(2, 3)))
        Self.converged(&pair)
        let merged = try #require(DataModel(pair.a.state).source(source)?.sample)
        #expect((merged.blobSha256 == Data(repeating: 1, count: 32) && merged.recordCount == 5)
                || (merged.blobSha256 == Data(repeating: 2, count: 32) && merged.recordCount == 3))
    }

    @Test func concurrentBindingsLaterWins() throws {
        var pair = Pair()
        let fields = try DataFixture.fields(&pair.a, ["a", "b"], kinds: [.boolean, .boolean])
        let node = try pair.a.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5)))!.createdObjects[0]
        Self.converged(&pair)
        try pair.a.perform(BindToField([node], field: fields[0], kind: .visibility))
        try pair.b.perform(BindToField([node], field: fields[1], kind: .visibility))
        Self.converged(&pair)
        let winner = DataModel(pair.a.state).binding(of: node, in: pair.a.state)?.field
        #expect(winner == fields[1], "B's write has the greater OpId")
    }

    @Test func concurrentScriptSavesKeepOneSourceAndNameVersusSourceBothSurvive() throws {
        var pair = Pair()
        let script = try #require(try pair.a.perform(SaveScript(name: "Tidy", source: "console.log(1)"))).createdNodes[0]
        Self.converged(&pair)
        #expect(DocumentScript.list(pair.b.state).map(\.name) == ["Tidy"])
        try pair.a.perform(SaveScript(script, name: "Tidy", source: "console.log('a')"))
        try pair.b.perform(SaveScript(script, name: "Tidy", source: "console.log('b')"))
        Self.converged(&pair)
        let merged = try #require(DocumentScript.script(script, in: pair.a.state))
        #expect(merged.source == "console.log('b')")
        #expect(!pair.a.state.store.losingWrites(script, ScriptFields.source).isEmpty, "the other save is kept for the review sheet")
        try pair.a.perform(RenameScript(script, to: "Tidy up"))
        try pair.b.perform(SaveScript(script, name: "Tidy", source: "console.log('c')"))
        Self.converged(&pair)
        let both = try #require(DocumentScript.script(script, in: pair.a.state))
        #expect(both.source == "console.log('c')")
    }

    @Test func concurrentMergesToPagesBothRunsPresent() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        let field = try DataFixture.fields(&pair.a, ["name"])[0]
        _ = try DataFixture.placeholderBlock(&pair.a, "", field: field, at: 0)
        Self.converged(&pair)
        let records = RecordSet(model: DataModel(pair.a.state), source: nil, raw: [DataRecord(["name": "Ada"]), DataRecord(["name": "Bo"])])
        try pair.a.perform(MergeToPages(templates: [page], records: records, indices: [0, 1]))
        try pair.b.perform(MergeToPages(templates: [page], records: records, indices: [0]))
        Self.converged(&pair)
        #expect(PageList(pair.a.state).pages.count == 4)
    }

    @Test func templateEditConcurrentWithMergeChangesTheTemplateOnly() throws {
        var pair = Pair()
        let page = try PageFixture.onePage(&pair.a)
        let field = try DataFixture.fields(&pair.a, ["name"])[0]
        let node = try DataFixture.placeholderBlock(&pair.a, "Hi ", field: field, at: 3)
        Self.converged(&pair)
        let records = RecordSet(model: DataModel(pair.a.state), source: nil, raw: [DataRecord(["name": "Ada"])])
        try pair.a.perform(MergeToPages(templates: [page], records: records, indices: [0]))
        try pair.b.perform(InsertText(node: node, text: "!", at: .end))
        Self.converged(&pair)
        let texts = DataBindings.liveNodes(in: pair.a.state).compactMap { TextNode($0, in: pair.a.state)?.string }
        #expect(Set(texts) == ["Hi {{name}}!", "Hi Ada"])
    }
}
