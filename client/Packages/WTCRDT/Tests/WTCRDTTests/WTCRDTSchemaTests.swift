import Foundation
import Testing
import WTCRDTSchema
import WTProto

/// Smoke tests of the protoc-gen-wtcrdt output: the Go tests in tools/protoc-gen-wtcrdt cover
/// every policy and rule; these check that the generated Swift behaves the same at runtime.
@Suite struct WTCRDTSchemaTests {
    @Test func mergeTableDefaults() throws {
        let common = try #require(WTMergeTable.messages["wiretuner.doc.v1.CommonProps"])
        #expect(common[1]?.policy == .atomic)          // string name
        #expect(common[4]?.policy == .atomic)          // Transform, explicit MERGE_ATOMIC
        #expect(common[8]?.policy == .structure)       // NavigationProps, default STRUCT
        #expect(common[5]?.typeName == "wiretuner.doc.v1.NodeRef")
        #expect(WTMergeTable.field("wiretuner.doc.v1.NodeProps", 50)?.oneof == "kind")
        #expect(WTMergeTable.field("wiretuner.doc.v1.NodeProps", 9999) == nil)
    }

    @Test func jsonMatchesResourceAndVersion() throws {
        let resource = try #require(WTCRDTSchemaPackage.mergeTableResource())
        #expect(String(decoding: resource, as: UTF8.self) == WTMergeTable.json + "\n"
            || String(decoding: resource, as: UTF8.self) == WTMergeTable.json)
        let object = try #require(try JSONSerialization.jsonObject(with: resource) as? [String: Any])
        #expect(object["version"] as? String == WTMergeTable.version)
        #expect(WTMergeTable.version.count == 64)
    }

    @Test func changeRules() {
        var change = Wiretuner_Doc_V1_Change()
        let ids = Set(WTValidators.validate(change).map(\.ruleID))
        #expect(ids == ["fixed64.gt", "uint64.gt", "repeated.min_items"])

        change.replica = 7
        change.seq = 1
        change.startCounter = 1
        change.label = String(repeating: "x", count: 257)
        var create = Wiretuner_Doc_V1_CreateNode()
        create.position = Data([0x80])
        var op = Wiretuner_Doc_V1_Op()
        op.create = create
        change.ops = [op]
        let violations = WTValidators.validate(change)
        #expect(violations.map(\.fieldPath).sorted() == ["label", "ops[0].create.parent", "ops[0].create.props"])
        #expect(violations.first { $0.fieldPath == "label" }?.ruleID == "string.max_len")
    }

    @Test func oneofRequiredAndStringRules() {
        #expect(WTValidators.validate(Wiretuner_Doc_V1_Op()).map(\.ruleID) == ["required"])

        var request = Wiretuner_Docs_V1_CreateRequest()
        request.documentID = "not-a-uuid"
        request.spaceID = "0190f5a0-0000-7000-8000-000000000000"
        let byField = Dictionary(grouping: WTValidators.validate(request), by: \.fieldPath)
        #expect(Set(byField["document_id"]?.map(\.ruleID) ?? []) == ["string.uuid", "string.pattern"])
        #expect(byField["space_id"] == nil)
        #expect(byField["folder_id"] == nil)   // IGNORE_IF_ZERO_VALUE

        request.documentID = "0190f5a0-0000-7000-8000-000000000000"
        #expect(WTValidators.validate(request).allSatisfy { $0.fieldPath != "document_id" })
    }
}
