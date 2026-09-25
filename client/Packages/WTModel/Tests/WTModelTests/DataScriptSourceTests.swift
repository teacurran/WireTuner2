import Foundation
import Synchronization
import Testing
import WTCRDT
@testable import WTModel
import WTProto

/// The remaining model pieces of DATA-015: outside scripts copied into the document when picked,
/// transform results cached per record, and a script source merging like a CSV (data-merge.adoc).
@Suite struct DataScriptSourceTests {
    static let library: Wiretuner_Doc_V1_LibrarySource = .with {
        $0.documentID = "0190a0d4-0000-7000-8000-00000000000b"
        $0.symbol = OpID(counter: 5, replica: 3).proto
        $0.serverSeq = 12
    }

    @Test func pickingAnOutsideScriptCopiesItOnceAndReusesTheCopy() throws {
        var a = Replica(0xA)
        let tickets = ExternalScript(name: "Tickets", source: "export function records() { return []; }", description: "From the box office",
                                     library: Self.library)
        let command = CopyScriptIntoDocument(tickets)
        #expect(command.label == "Copy script")
        let change = try #require(try a.perform(command))
        let node = try #require(CopyScriptIntoDocument.node(for: tickets, after: change, in: a.state))
        let copy = try #require(DocumentScript.script(node, in: a.state))
        #expect(copy.name == "Tickets" && copy.description == "From the box office" && copy.library == Self.library)
        // Picking it again writes nothing and names the copy.
        #expect(try a.perform(CopyScriptIntoDocument(tickets)) == nil)
        #expect(CopyScriptIntoDocument.node(for: tickets, after: nil, in: a.state) == node)
        // The same library script, renamed here, is still the copy.
        try a.perform(RenameScript(node, to: "Box office"))
        #expect(tickets.existingCopy(in: a.state) == node)
        // A Scripts-folder script of a taken name but other source gets a free name.
        let local = ExternalScript(name: "Box office", source: "export function records() { return [{a: 1}]; }")
        let second = try #require(try a.perform(CopyScriptIntoDocument(local)))
        #expect(DocumentScript.script(second.createdNodes[0], in: a.state)?.name == "Box office 2")
        let third = ExternalScript(name: "Box office", source: "export function records() { return [{b: 2}]; }")
        let named = try #require(try a.perform(CopyScriptIntoDocument(third)))
        #expect(DocumentScript.script(named.createdNodes[0], in: a.state)?.name == "Box office 3")
        // Identical name and source from the folder: reused.
        #expect(local.existingCopy(in: a.state) == second.createdNodes[0])
        // A library script whose source changed in the library is copied again.
        var updated = tickets
        updated.source = "export function records() { return [{c: 3}]; }"
        #expect(updated.existingCopy(in: a.state) == nil)
    }

    final class Counting: FieldTransforming, Sendable {
        let calls = Mutex(0)
        func transform(script: OpID, value: String?, record: [String: String], field: String) throws -> String? {
            calls.withLock { $0 += 1 }
            if value == "bad" { throw ScriptError.timeout }
            return value.map { $0.uppercased() }
        }
    }

    @Test func transformResultsAreCachedPerRecordAndFailuresAreNot() throws {
        let base = Counting()
        let cache = CachingFieldTransformer(base)
        let script = OpID(counter: 1, replica: 1)
        #expect(try cache.transform(script: script, value: "ada", record: ["n": "1"], field: "f") == "ADA")
        #expect(try cache.transform(script: script, value: "ada", record: ["n": "1"], field: "f") == "ADA")
        #expect(try cache.transform(script: script, value: nil, record: ["n": "1"], field: "f") == nil)
        #expect(try cache.transform(script: script, value: nil, record: ["n": "1"], field: "f") == nil)
        #expect(cache.runs == 2 && base.calls.withLock { $0 } == 2)
        // Another record (the transform may read it) or field runs again.
        _ = try cache.transform(script: script, value: "ada", record: ["n": "2"], field: "f")
        _ = try cache.transform(script: script, value: "ada", record: ["n": "1"], field: "g")
        #expect(cache.runs == 4)
        #expect(throws: ScriptError.timeout) { try cache.transform(script: script, value: "bad", record: [:], field: "f") }
        #expect(throws: ScriptError.timeout) { try cache.transform(script: script, value: "bad", record: [:], field: "f") }
        #expect(cache.runs == 6, "a failure is reported for every record")
    }

    @Test func aScriptSourceOf10000RecordsMergesLikeTheSameRecordsFromACSV() throws {
        var a = Replica(0xA)
        _ = try DataFixture.fields(&a, ["first", "seat", "n"])
        let source = try a.perform(SaveScript(name: "Generated", source: """
        export function records() {
          const out = [];
          for (let i = 0; i < 10000; i++) out.push({ first: "P" + i, seat: "A-" + (i % 40), n: i * 3 });
          return out;
        }
        """))!.createdNodes[0]
        let result = try ScriptRecordSource.records(script: source, state: a.state, limits: ScriptLimits(wallClock: 60, memory: 1 << 30))
        var csv = "first,seat,n\n"
        for i in 0..<10_000 { csv += "P\(i),A-\(i % 40),\(i * 3)\n" }
        let table = DataTable.delimited(csv)
        #expect(result.table.records.count == 10_000 && table.records.count == 10_000)
        let model = DataModel(a.state)
        let fromScript = RecordSet(model: model, source: nil, raw: result.table.records, locale: Locale(identifier: "en_US_POSIX"))
        let fromCSV = RecordSet(model: model, source: nil, raw: table.records, locale: Locale(identifier: "en_US_POSIX"))
        #expect(fromScript.records == fromCSV.records)
        #expect(fromScript.issues == fromCSV.issues)
    }
}
