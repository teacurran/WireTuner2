import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The conformance vectors of DOC-002's and DOC-010's read-time normalizations
/// (`crdt-conformance/vectors/document/`): each is the changes the real commands write -- a setup
/// by replica 7, then replicas 1 and 2 concurrently -- so the stored state behind each read rule
/// is pinned for both engines.  The rules themselves are read-time (`PageList`,
/// `DocumentSettings`) and are asserted here on the merged state.  `WT_RECORD_VECTORS=1` rewrites
/// the files with empty hashes (record them with WTCRDT's `ConformanceTests`, then confirm with
/// `make -C crdt-conformance java`); the committed files must hold exactly these changes.
@Suite struct DocumentSetupVectorTests {
    struct Vector {
        var name: String
        var task: String
        var description: String
        var setup: [Wiretuner_Doc_V1_Change]
        var replicas: [(id: UInt64, changes: [Wiretuner_Doc_V1_Change])]
        /// The merged state (both replicas' changes applied to the setup).
        var merged: EngineState
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "crdt-conformance/vectors/document")

    /// Plays `setup` on replica 7, then `one` on replica 1 and `two` on replica 2 (each after the
    /// setup, neither seeing the other).
    static func vector(_ name: String, task: String, _ description: String, setup: (inout Replica) throws -> Void,
                       one: (inout Replica) throws -> Void, two: ((inout Replica) throws -> Void)? = nil) throws -> Vector {
        var origin = Replica(7)
        try setup(&origin)
        var first = Replica(1), second = Replica(2)
        first.receive(origin.sent)
        second.receive(origin.sent)
        try one(&first)
        try two?(&second)
        var merged = Replica(3)
        merged.receive(origin.sent + first.sent + second.sent)
        var replicas = [(id: UInt64(1), changes: first.sent)]
        if two != nil { replicas.append((2, second.sent)) }
        return Vector(name: name, task: task, description: description, setup: origin.sent, replicas: replicas, merged: merged.state)
    }

    static func vectors() throws -> [Vector] {
        var result: [Vector] = []
        // DOC-002: a page naming a custom size another replica removed keeps the name (reads Custom).
        var card = OpID.zero, page = OpID.zero
        result.append(try vector("document/custom-size-remove-vs-use", task: "DOC-002",
                                 "Replica 1 sets the page to the custom size Card while replica 2 removes Card.  The page's geometry register keeps preset \\\"Card\\\" with no live size of that name, so it reads as Custom at the stored size (PageList); restoring the size brings the name back.",
                                 setup: { r in
                                     page = try PageFixture.onePage(&r)
                                     try r.perform(AddCustomPageSize(name: "Card", size: Size(width: 252, height: 144)))
                                     card = DocumentSettings(r.state).customPageSizes[0].id
                                 }, one: { r in
                                     try r.perform(SetPageGeometry([page], to: PageGeometry(preset: "Card", portrait: Size(width: 252, height: 144))))
                                 }, two: { r in try r.perform(RemoveCustomPageSize(card)) }))
        // DOC-002: a custom unit chosen while another replica removes it reads as points.
        var unit = OpID.zero
        result.append(try vector("document/custom-unit-remove-vs-choose", task: "DOC-002",
                                 "Replica 1 chooses the custom unit Hand while replica 2 removes it.  The units register keeps the custom choice naming a deleted element, which reads as points (DocumentSettings).",
                                 setup: { r in
                                     _ = try PageFixture.onePage(&r)
                                     try r.perform(AddCustomUnit(name: "Hand", amount: 4, base: .inches))
                                     unit = DocumentSettings(r.state).customUnits[0].id
                                 }, one: { r in try r.perform(SetUnits(.custom(unit))) }, two: { r in try r.perform(RemoveCustomUnit(unit)) }))
        // DOC-002: a printer resolution of zero (a file written by another client) reads as 300.
        result.append(try vector("document/printer-resolution-zero", task: "DOC-002",
                                 "Replica 1 writes printer_resolution 0 to the settings node (no command does; an older or foreign client might).  The register holds 0, which reads as 300 dpi (DocumentSettings).",
                                 setup: { r in _ = try PageFixture.onePage(&r) },
                                 one: { r in
                                     try r.perform(OpsCommand("Printer resolution", ops: [Ops.set(WellKnown.settings, [SettingsFields.printerResolution],
                                                                                                   values: SettingsFields.values { $0.printerResolution = 0 })]))
                                 }))
        // DOC-002: both pages removed concurrently leaves none, which reads as one Letter page.
        var pages: [OpID] = []
        result.append(try vector("document/every-page-removed", task: "DOC-002",
                                 "Of two pages, replica 1 removes the first and replica 2 the second.  No live page is left under the pages root; the document reads as one synthesized Letter page at the origin (PageList) and writes nothing until a command touches it.",
                                 setup: { r in
                                     _ = try PageFixture.onePage(&r)
                                     try r.perform(AddPages(count: 1))
                                     pages = PageList(r.state).pages.map(\.id)
                                 }, one: { r in try r.perform(RemovePages([pages[0]])) }, two: { r in try r.perform(RemovePages([pages[1]])) }))
        // DOC-010: applying a master another replica deleted keeps the reference; the page reads ordinary.
        var master = OpID.zero
        result.append(try vector("document/master-delete-vs-apply", task: "DOC-010",
                                 "Replica 1 deletes the A5 master page while replica 2 applies it to the page.  The page's master register keeps the reference to the tombstone, so the page reads as an ordinary Letter page (PageList); restoring the master makes it a child again.",
                                 setup: { r in
                                     let first = try PageFixture.onePage(&r)
                                     page = first
                                     try r.perform(NewMasterPage(from: first))
                                     master = PageList(r.state).masters[0].id
                                     try r.perform(SetPageGeometry([master], to: PageGeometry(PagePreset.named("A5")!)))
                                 }, one: { r in try r.perform(DeleteMasterPage(master)) }, two: { r in try r.perform(ApplyMasterPage(master, to: [page])) }))
        // DOC-010: a master reference naming an ordinary page reads unset.
        result.append(try vector("document/master-names-a-page", task: "DOC-010",
                                 "Replica 1 writes the first page's master reference to the second page, an ordinary page (no command does).  The register holds the reference, which reads unset: the page is not a child (PageList).",
                                 setup: { r in
                                     _ = try PageFixture.onePage(&r)
                                     try r.perform(AddPages(count: 1))
                                     pages = PageList(r.state).pages.map(\.id)
                                 }, one: { r in
                                     try r.perform(OpsCommand("Master", ops: [Ops.set(pages[0], [PageFields.master], values: PageFields.values { $0.master.id = pages[1].proto })]))
                                 }))
        return result
    }

    /// A change in the vector's text format, indented under `change {`.
    static func text(_ change: Wiretuner_Doc_V1_Change, sequenced: Bool) -> String {
        var change = change
        if sequenced { change.baseServerSeq = 1 }
        return change.textFormatString().split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")
    }

    /// The vector file up to its `expect` block.
    static func body(_ vector: Vector) -> String {
        var lines = [
            "# crdt-conformance/vectors/\(vector.name).textproto (\(vector.task); schema: crdt-conformance/schema/vector.proto; recorded by WTModel's DocumentSetupVectorTests)",
            "name: \"\(vector.name)\"",
            "description: \"\(vector.description)\"",
            "setup {",
        ]
        for change in vector.setup { lines += ["  change {", text(change, sequenced: false), "  }"] }
        lines.append("}")
        for replica in vector.replicas {
            lines += ["replica {", "  id: \(replica.id)"]
            for change in replica.changes { lines += ["  change {", text(change, sequenced: true), "  }"] }
            lines.append("}")
        }
        lines += vector.replicas.count == 2 ? ["deliveries { order: [1, 2] }", "deliveries { order: [2, 1] }"] : ["deliveries { order: [1] }"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func url(_ vector: Vector) -> URL { directory.appending(path: "\(vector.name.split(separator: "/").last!).textproto") }

    @Test func theReadRulesHoldOnTheMergedStates() throws {
        let vectors = try Self.vectors()
        let settings = vectors.map { DocumentSettings($0.merged) }, lists = vectors.map { PageList($0.merged) }
        #expect(lists[0].pages[0].geometry.preset == "" && lists[0].pages[0].geometry.size == Size(width: 144, height: 252) && settings[0].customPageSizes.isEmpty)
        #expect(settings[1].units == .points && settings[1].customUnits.isEmpty)
        #expect(vectors[2].merged.props(WellKnown.settings).settings.printerResolution == 0 && settings[2].printerResolution == 300)
        #expect(lists[3].isSynthesized && lists[3].pages[0].geometry == .letter && vectors[3].merged.liveChildren(WellKnown.pages).isEmpty)
        #expect(!lists[4].pages[0].isChild && lists[4].pages[0].geometry == .letter && lists[4].masters.isEmpty)
        #expect(!lists[5].pages[0].isChild && vectors[5].merged.props(lists[5].pages[0].id).page.master.id == lists[5].pages[1].id.proto)
    }

    /// `text` without its position keys, which the commands draw at random between neighbours.
    static func positionless(_ text: String) -> String {
        text.replacingOccurrences(of: #"positions?: "(?:[^"\\]|\\.)*""#, with: "position: _", options: .regularExpression)
    }

    @Test func theCommittedVectorsHoldTheseChanges() throws {
        #expect(Self.positionless(#"position: "\200a\"b" x"#) == "position: _ x")
        for vector in try Self.vectors() {
            let committed = try String(contentsOf: Self.url(vector), encoding: .utf8)
            #expect(Self.positionless(committed).hasPrefix(Self.positionless(Self.body(vector))), "\(vector.name): rerun with WT_RECORD_VECTORS=1 (positions aside)")
            #expect(committed.contains("state_hash: \"") && !committed.contains("state_hash: \"\""), "\(vector.name) has its hashes")
        }
    }

    @Test func recordTheVectors() throws {
        guard ProcessInfo.processInfo.environment["WT_RECORD_VECTORS"] == "1" else { return }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for vector in try Self.vectors() {
            let text = Self.body(vector) + "expect {\n  state_hash: \"\"\n  snapshot_hash: \"\"\n}\n"
            try text.write(to: Self.url(vector), atomically: true, encoding: .utf8)
        }
    }
}
