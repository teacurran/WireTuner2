import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Fields, sources and bindings for the data tests.
enum DataFixture {
    /// Adds fields named `names` (text unless given) and returns their ids in order.
    @discardableResult
    static func fields(_ replica: inout Replica, _ names: [String], kinds: [DataFieldKind] = []) throws -> [OpID] {
        let fields = names.enumerated().map { AddFields.Field($1, kind: $0 < kinds.count ? kinds[$0] : .text) }
        let change = try #require(try replica.perform(AddFields(fields)))
        return change.insertedElements(WellKnown.settings, DataFieldsPaths.fields)
    }

    static func field(_ replica: Replica, _ name: String) -> DataFieldInfo? {
        DataModel(replica.state).field(named: name)
    }

    /// Adds a pasted source (activated) and returns its id.
    @discardableResult
    static func source(_ replica: inout Replica, name: String = "Addresses", kind: Wiretuner_Doc_V1_DataSourceKind = .pasted,
                       _ build: (inout Wiretuner_Doc_V1_DataSourceSpec) -> Void = { _ in }) throws -> OpID {
        let change = try #require(try replica.perform(AddSource(name: name, kind: kind, build)))
        return change.insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
    }

    /// A text block holding `text` with a placeholder for `field` inserted at `offset`.
    static func placeholderBlock(_ replica: inout Replica, _ text: String, field: OpID, at offset: Int) throws -> OpID {
        let node = try TextFixture.block(&replica, text)
        try replica.perform(InsertPlaceholder(node: node, at: TextFixture.at(replica, node, offset), field: field))
        return node
    }

    static func record(_ values: [String: String]) -> DataRecord { DataRecord(values) }
}

/// DATA-003: the data commands, the model as read, placeholders and bindings.
@Suite struct DataCommandTests {
    @Test func fieldsAddRenameTypeFormatTransformDeleteRestore() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["first_name", "total"], kinds: [.text, .number])
        #expect(AddFields("x").label == "Add field" && AddFields([.init("a"), .init("b")]).label == "Add 2 fields")
        var model = DataModel(a.state)
        #expect(model.fields.map(\.name) == ["first_name", "total"] && model.fields[1].kind == .number)
        #expect(model.field(named: "FIRST_NAME")?.id == ids[0] && model.field(ids[1])?.name == "total" && model.field(nil) == nil)
        // Validation: names, duplicates (case-insensitive, within the batch too), format lengths.
        #expect(throws: DataEditError.invalidName("1st")) { try a.perform(AddFields("1st")) }
        #expect(throws: DataEditError.invalidName("")) { try a.perform(AddFields("")) }
        #expect(throws: DataEditError.duplicateName("first_name")) { try a.perform(AddFields("First_Name")) }
        #expect(throws: DataEditError.duplicateName("B")) { try a.perform(AddFields([.init("b"), .init("B")])) }
        #expect(throws: DataEditError.invalidValue("format")) { try a.perform(AddFields([.init("c", pattern: String(repeating: "#", count: 65))])) }
        #expect(try a.perform(AddFields([])) == nil)
        #expect(!DataFieldsPaths.isValidName(String(repeating: "a", count: 65)) && DataFieldsPaths.isValidName("_a1"))
        #expect(!DataFieldsPaths.isValidName("a-b") && !DataFieldsPaths.isValidName("é"))

        let rename = try #require(try a.perform(RenameField(ids[0], to: "given_name")))
        #expect(rename.label == "Rename field" && DataFixture.field(a, "given_name")?.id == ids[0])
        #expect(throws: DataEditError.duplicateName("total")) { try a.perform(RenameField(ids[0], to: "TOTAL")) }
        try a.perform(RenameField(ids[0], to: "Given_Name"))   // its own name in another case is fine
        #expect(throws: DataEditError.unknownField(.zero)) { try a.perform(RenameField(.zero, to: "x")) }
        #expect(try a.perform(SetFieldType(ids[0], to: .date))?.label == "Change field type")
        #expect(DataModel(a.state).field(ids[0])?.kind == .date)
        #expect(throws: DataEditError.unknownField(.zero)) { try a.perform(SetFieldType(.zero, to: .date)) }
        #expect(try a.perform(SetFieldFormat(ids[1], pattern: "#,##0.00"))?.label == "Change field format")
        try a.perform(SetFieldFormat(ids[1], locale: "de_DE"))
        model = DataModel(a.state)
        #expect(model.field(ids[1])?.pattern == "#,##0.00" && model.field(ids[1])?.locale == "de_DE")
        #expect(try a.perform(SetFieldFormat(ids[1])) == nil)
        #expect(throws: DataEditError.invalidValue("pattern")) { try a.perform(SetFieldFormat(ids[1], pattern: String(repeating: "0", count: 65))) }
        #expect(throws: DataEditError.invalidValue("locale")) { try a.perform(SetFieldFormat(ids[1], locale: String(repeating: "x", count: 33))) }
        // Transform: a live script node, or none; anything else refused.
        let script = try #require(try a.perform(SaveScript(name: "Upper", source: "export function transform(v) { return v; }"))).createdNodes[0]
        #expect(try a.perform(SetFieldTransform(ids[0], script: script))?.label == "Change transform")
        #expect(DataModel(a.state).field(ids[0])?.transform == script)
        #expect(throws: DataEditError.invalidValue("script")) { try a.perform(SetFieldTransform(ids[0], script: ids[1])) }
        try a.perform(DeleteScript(script))
        #expect(DataModel(a.state).field(ids[0])?.transform == nil, "a deleted script reads as no transform")
        try a.perform(SetFieldTransform(ids[0], script: nil))
        // Delete and restore.
        #expect(try a.perform(DeleteField(ids[1]))?.label == "Delete field")
        #expect(DataModel(a.state).field(ids[1]) == nil)
        #expect(throws: DataEditError.unknownField(ids[1])) { try a.perform(DeleteField(ids[1])) }
        #expect(try a.perform(RestoreField(ids[1]))?.label == "Restore field")
        #expect(DataModel(a.state).field(ids[1])?.name == "total")
        #expect(throws: DataEditError.unknownField(.zero)) { try a.perform(RestoreField(.zero)) }
        // Undo restores the prior register.
        try a.perform(RenameField(ids[1], to: "amount"))
        a.undo()
        #expect(DataModel(a.state).field(ids[1])?.name == "total")
    }

    @Test func sourcesMappingSampleAndReadTimeDefaults() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["city", "zip"])
        let http = try DataFixture.source(&a, name: "Orders", kind: .http) { spec in
            spec.http.url = "https://api.example.com/orders?since={{since}}"
            spec.http.headers = [.with { $0.name = "Accept"; $0.value = "application/json" }]
            spec.http.params = [.with { $0.name = "since"; $0.defaultValue = "2026-01-01" }]
        }
        var model = DataModel(a.state)
        let source = try #require(model.activeSource)
        #expect(source.id == http && source.kind == .http && source.hasValidURL && model.sources.count == 1)
        #expect(source.spec.http.headers.map(\.name) == ["Accept"] && source.spec.http.params.map(\.defaultValue) == ["2026-01-01"])
        let defaults = source.http
        #expect(defaults.timeoutS == 30 && defaults.pagination.firstPage == 1 && defaults.pagination.maxPages == 1000)
        #expect(defaults.pagination.mode == .none && defaults.method == .get)
        #expect(throws: DataEditError.secretHeader("Authorization")) {
            try a.perform(AddSource(name: "Bad", kind: .http) { $0.http.headers = [.with { $0.name = "Authorization" }] })
        }
        #expect(throws: DataEditError.invalidURL("http://x")) { try a.perform(AddSource(name: "Bad", kind: .http) { $0.http.url = "http://x" }) }
        // Edits: registers below the spec, the name, headers, params.
        var spec = Wiretuner_Doc_V1_DataSourceSpec()
        spec.http.url = "https://api.example.com/v2"
        spec.http.timeoutS = 60
        #expect(try a.perform(EditSource(http, name: "Orders v2", spec: spec, paths: [[4, 2], [4, 9]]))?.label == "Change source")
        model = DataModel(a.state)
        #expect(model.activeSource?.name == "Orders v2" && model.activeSource?.spec.http.url == "https://api.example.com/v2")
        #expect(model.activeSource?.http.timeoutS == 60)
        #expect(try a.perform(EditSource(http)) == nil)
        #expect(throws: DataEditError.invalidValue("paths")) { try a.perform(EditSource(http, paths: [[4, 3]])) }
        #expect(throws: DataEditError.invalidValue("paths")) { try a.perform(EditSource(http, paths: [[]])) }
        #expect(throws: DataEditError.unknownSource(.zero)) { try a.perform(EditSource(.zero)) }
        var bad = Wiretuner_Doc_V1_DataSourceSpec()
        bad.http.url = "ftp://x"
        #expect(throws: DataEditError.invalidURL("ftp://x")) { try a.perform(EditSource(http, spec: bad, paths: [[4, 2]])) }
        #expect(try a.perform(SetSourceHeaders(http, [("Accept", "text/csv"), ("X-Trace", "1")]))?.label == "Change headers")
        #expect(DataModel(a.state).activeSource?.spec.http.headers.map(\.value) == ["text/csv", "1"])
        #expect(throws: DataEditError.secretHeader("cookie")) { try a.perform(SetSourceHeaders(http, [("cookie", "x")])) }
        try a.perform(SetSourceHeaders(http, []))
        #expect(DataModel(a.state).activeSource?.spec.http.headers.isEmpty == true)
        #expect(try a.perform(SetSourceParams(http, [("page", "1")]))?.label == "Change parameters")
        #expect(DataModel(a.state).activeSource?.spec.http.params.map(\.name) == ["page"])
        // Kind switch keeps the other kind's settings (VARIANT).
        var file = Wiretuner_Doc_V1_DataSourceSpec()
        file.kind = .file
        file.file.fileName = "orders.csv"
        try a.perform(EditSource(http, spec: file, paths: [[1], [2, 2]]))
        model = DataModel(a.state)
        #expect(model.activeSource?.kind == .file && model.activeSource?.spec.http.url == "https://api.example.com/v2")
        // Mapping: by id; replaced per field; nil unpairs; dangling fields are ignored on read.
        #expect(try a.perform(SetMapping(http, field: ids[0], path: "$.address.city"))?.label == "Change mapping")
        try a.perform(SetMapping(http, field: ids[0], path: "Town"))
        model = DataModel(a.state)
        #expect(model.activeSource?.mapping.map(\.path) == ["Town"])
        #expect(model.path(of: model.field(ids[0])!, in: model.activeSource) == "Town" && model.path(of: model.field(ids[1])!, in: model.activeSource) == "zip")
        #expect(model.path(of: model.field(ids[1])!, in: nil) == "zip")
        try a.perform(SetMapping(http, field: ids[1], path: "postcode"))
        try a.perform(DeleteField(ids[1]))
        #expect(DataModel(a.state).activeSource?.mapping.count == 1, "a mapping entry whose field is gone is ignored")
        try a.perform(SetMapping(http, field: ids[0], path: nil))
        #expect(DataModel(a.state).activeSource?.mapping.isEmpty == true)
        #expect(throws: DataEditError.invalidValue("path")) { try a.perform(SetMapping(http, field: ids[0], path: String(repeating: "a", count: 513))) }
        #expect(throws: DataEditError.unknownField(ids[1])) { try a.perform(SetMapping(http, field: ids[1], path: "x")) }
        // Sample: ATOMIC, validated.
        var sample = Wiretuner_Doc_V1_EmbeddedRecords()
        sample.blobSha256 = Data(repeating: 7, count: 32)
        sample.mediaType = "text/csv"
        sample.recordCount = 5
        #expect(try a.perform(SetSample(http, sample))?.label == "Embed sample")
        #expect(DataModel(a.state).activeSource?.sample?.recordCount == 5)
        #expect(try a.perform(SetSample(http, nil))?.label == "Remove sample")
        #expect(DataModel(a.state).activeSource?.sample == nil)
        var wrong = sample
        wrong.mediaType = "text/plain"
        #expect(throws: DataEditError.invalidValue("sample")) { try a.perform(SetSample(http, wrong)) }
        // Active source and removal.
        #expect(try a.perform(SetActiveSource(nil))?.label == "Disconnect source")
        #expect(DataModel(a.state).activeSource == nil)
        #expect(SetActiveSource(http).label == "Connect source")
        try a.perform(SetActiveSource(http))
        #expect(throws: DataEditError.unknownSource(.zero)) { try a.perform(SetActiveSource(.zero)) }
        #expect(try a.perform(RemoveSource(http))?.label == "Remove source")
        model = DataModel(a.state)
        #expect(model.activeSource == nil && model.sources.isEmpty && model.source(http) == nil, "a dangling active source reads as none")
        #expect(throws: DataEditError.unknownSource(http)) { try a.perform(RemoveSource(http)) }
        // A mapping given at creation is inserted with the source; an inactive source stays inactive.
        var mapped = Wiretuner_Doc_V1_DataSource()
        mapped.name = "Mapped"
        mapped.spec.kind = .script
        mapped.mapping = [.with { $0.field = ids[0].elementID; $0.path = "c" }]
        let change = try #require(try a.perform(AddSource(mapped, activate: false)))
        let id = change.insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        model = DataModel(a.state)
        #expect(model.activeSource == nil && model.source(id)?.mapping.map(\.path) == ["c"] && model.source(id)?.script == nil)
    }

    @Test func placeholdersInsertTypeUnitsAndMissing() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["first_name", "last_name"])
        let node = try DataFixture.placeholderBlock(&a, "Dear ,", field: ids[0], at: 5)
        #expect(a.sent.last?.label == "Insert field")
        var text = TextFixture.text(a, node)
        #expect(text.string == "Dear {{first_name}},")
        var model = DataModel(a.state)
        var spans = model.placeholders(in: text)
        #expect(spans.count == 1 && spans[0].range == 5..<19 && spans[0].field == ids[0] && spans[0].label == "{{first_name}}")
        // One unit: a caret inside selects it whole; a range touching it grows to cover it.
        #expect(DataPlaceholders.unitRange(8..<8, in: text) == 5..<19)
        #expect(DataPlaceholders.unitRange(3..<6, in: text) == 3..<19)
        #expect(DataPlaceholders.unitRange(1..<2, in: text) == 1..<2)
        #expect(DataPlaceholders.unitRange(5..<5, in: text) == 5..<5, "a caret at the edge is outside")
        // Typing at either edge stays outside (non-expanding).
        try a.perform(InsertText(node: node, text: "X", at: TextFixture.at(a, node, 19)))
        try a.perform(InsertText(node: node, text: "Y", at: TextFixture.at(a, node, 5)))
        text = TextFixture.text(a, node)
        #expect(model.placeholders(in: text).map(\.range) == [6..<20])
        // Typed recognition: `{{ last_name }}` becomes a placeholder, formatting kept.
        let typed = try TextFixture.block(&a, "Hi {{ last_name }}")
        try a.perform(ApplyMark(node: typed, from: .start, to: .end, value: TextFixture.size(18)))
        var typedText = TextFixture.text(a, typed)
        #expect(DataPlaceholders.completed(in: typedText, before: typedText.length)?.name == "last_name")
        let convert = try #require(try a.perform(ConvertTypedPlaceholder(node: typed, caret: .end)))
        #expect(convert.label == "Insert field")
        typedText = TextFixture.text(a, typed)
        model = DataModel(a.state)
        spans = model.placeholders(in: typedText)
        #expect(typedText.string == "Hi {{last_name}}" && spans.map(\.field) == [ids[1]] && TextFixture.sizes(typedText).allSatisfy { $0 == 18 })
        // Already a placeholder: nothing to convert.
        #expect(DataPlaceholders.completed(in: typedText, before: typedText.length) == nil)
        #expect(throws: DataEditError.noPlaceholder) { try a.perform(ConvertTypedPlaceholder(node: typed, caret: .end)) }
        // An unknown name gets the zero id (red, "create field").
        let unknown = try TextFixture.block(&a, "{{nickname}}")
        try a.perform(ConvertTypedPlaceholder(node: unknown, caret: .end))
        let unknownSpans = DataModel(a.state).placeholders(in: TextFixture.text(a, unknown))
        #expect(unknownSpans.count == 1 && unknownSpans[0].field == nil && unknownSpans[0].label == "{{missing}}")
        // Not completed forms.
        for (string, caret) in [("{{a}", 4), ("ab}}", 4), ("x", 1), ("{{a b}}", 7), ("{{}\n}}", 6), ("a}}}}", 5), ("{{9x}}", 6)] {
            let block = try TextFixture.block(&a, string)
            #expect(DataPlaceholders.completed(in: TextFixture.text(a, block), before: caret) == nil, "\(string)")
        }
        let far = try TextFixture.block(&a, "{{" + String(repeating: " ", count: 250) + "a}}")
        #expect(DataPlaceholders.completed(in: TextFixture.text(a, far), before: 255) == nil)
        #expect(throws: DataEditError.unknownField(.zero)) { try a.perform(InsertPlaceholder(node: node, at: .end, field: .zero)) }
        // The pending format covers the placeholder; a field mark in it is ignored.
        let styled = try TextFixture.block(&a, "")
        try a.perform(InsertPlaceholder(node: styled, at: .end, field: ids[0], marks: [TextFixture.size(9), DataPlaceholders.mark(ids[1])]))
        let styledText = TextFixture.text(a, styled)
        #expect(DataModel(a.state).placeholders(in: styledText).map(\.field) == [ids[0]] && TextFixture.sizes(styledText).allSatisfy { $0 == 9 })
        // Deleting the field: its placeholders read {{missing}}; uses are counted by id.
        #expect(DeleteField.uses(of: ids[0], in: a.state) == 2)
        try a.perform(DeleteField(ids[0]))
        #expect(DataModel(a.state).placeholders(in: TextFixture.text(a, node)).first?.label == "{{missing}}")
    }

    @Test func bindingsByKindTypeAndMissing() throws {
        var a = Replica(0xA)
        let ids = try DataFixture.fields(&a, ["vip", "photo", "site", "code"], kinds: [.boolean, .image, .link, .text])
        let rect = try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10)))!.createdObjects[0]
        let barcode = try a.perform(InsertBarcode("x"))!.createdObjects[0]
        let text = try TextFixture.block(&a, "x")
        #expect(try a.perform(BindToField([rect], field: ids[0], kind: .visibility))?.label == "Bind to field")
        try a.perform(BindToField([barcode], field: ids[3], kind: .text))
        try a.perform(BindToField([text], field: ids[2], kind: .link))
        var model = DataModel(a.state)
        #expect(model.binding(of: rect, in: a.state)?.resolved?.id == ids[0] && model.binding(of: barcode, in: a.state)?.kind == .text)
        #expect(model.binding(of: text, in: a.state)?.isMissing == false && model.uses(in: a.state)[ids[0]] == 1)
        // Kinds a node cannot take.
        #expect(throws: DataEditError.bindingNotAllowed(rect)) { try a.perform(BindToField([rect], field: ids[1], kind: .image)) }
        #expect(throws: DataEditError.bindingNotAllowed(rect)) { try a.perform(BindToField([rect], field: ids[3], kind: .text)) }
        #expect(throws: DataEditError.bindingNotAllowed(WellKnown.settings)) { try a.perform(BindToField([WellKnown.settings], field: ids[0], kind: .visibility)) }
        #expect(BindToField.allows(.image, nodeKind: ImageKind.kind) && !BindToField.allows(.link, nodeKind: NodeKind.layer.rawValue))
        #expect(throws: DataEditError.unknownField(.zero)) { try a.perform(BindToField([rect], field: .zero, kind: .visibility)) }
        // A field of the wrong type reads as missing; so does a deleted one.
        try a.perform(SetFieldType(ids[0], to: .text))
        model = DataModel(a.state)
        #expect(model.binding(of: rect, in: a.state)?.isMissing == true)
        try a.perform(DeleteField(ids[2]))
        #expect(DataModel(a.state).binding(of: text, in: a.state)?.isMissing == true)
        #expect(DataModel(a.state).binding(of: WellKnown.settings, in: a.state) == nil)
        // Unbind clears; unbound nodes are skipped.
        #expect(try a.perform(Unbind([rect, barcode, text, WellKnown.settings]))?.label == "Unbind")
        #expect(DataModel(a.state).binding(of: rect, in: a.state) == nil)
        #expect(try a.perform(Unbind([rect])) == nil)
        // Image nodes: the binding lives on ImageProps.common.
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.sourceName = "photo.png"
        let layer = try a.perform(CreateLayer(name: "L"))!.createdNodes[0]
        let imageNode = try #require(try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x80], props: image)]))).createdNodes[0]
        try a.perform(BindToField([imageNode], field: ids[1], kind: .image))
        #expect(DataModel(a.state).binding(of: imageNode, in: a.state)?.resolved?.id == ids[1])
        try a.perform(Unbind([imageNode]))
        #expect(DataBindings.stored(a.state.props(imageNode)) == nil)
        #expect(DataBindings.values(kind: 999, nil) == nil)
        #expect(DataBindingKind(.unspecified) == nil && DataBindingKind.allCases.allSatisfy { DataBindingKind($0.stored) == $0 })
        #expect(DataFieldKind.allCases.allSatisfy { DataFieldKind($0.stored) == $0 } && DataFieldKind(.unspecified) == .text)
    }

    @Test func duplicateNamesNormalizeOnRead() throws {
        var pair = Pair()
        let a = try DataFixture.fields(&pair.a, ["email"])[0]
        let b = try DataFixture.fields(&pair.b, ["Email"])[0]
        pair.sync()
        for replica in [pair.a, pair.b] {
            let model = DataModel(replica.state)
            let names = Dictionary(uniqueKeysWithValues: model.fields.map { ($0.id, $0.displayName) })
            let (keeper, other) = a < b ? (a, b) : (b, a)
            #expect(names[keeper] == (keeper == a ? "email" : "Email") && names[other] == (other == a ? "email (2)" : "Email (2)"))
            #expect(model.field(named: "EMAIL")?.id == keeper)
        }
    }
}
