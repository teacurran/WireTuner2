import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// A reconnect played by two `DocumentCore`s: `theirs` (the others, already on the server) and
/// `mine` (this Mac, offline); `measure` delivers their changes to `mine` and measures its unsent
/// ones against them, as `SyncClient.reconcile` does.
struct Reconnect {
    static let recording = DocumentCore.Recording(limit: 100, now: Date(timeIntervalSince1970: 1_000_000))
    static let apart: Duration = .seconds(6 * 3600)

    var mine = DocumentCore(state: EngineState(), replica: 0xB)
    var theirs = DocumentCore(state: EngineState(), replica: 0xA)
    var local: [Wiretuner_Doc_V1_Change] = []
    var remote: [Wiretuner_Doc_V1_Change] = []
    private var serverSeq: UInt64 = 0

    /// Performs `command` on `theirs` before the gap: both sides have it.
    @discardableResult
    mutating func shared(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        guard let outcome = try theirs.perform(command, recording: Self.recording), let change = outcome.outbox else { return nil }
        serverSeq += 1
        mine.receive(change, serverSeq: serverSeq)
        return outcome.change
    }

    /// Performs `command` on this Mac, offline.
    @discardableResult
    mutating func byMe(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        guard let outcome = try mine.perform(command, recording: Self.recording), let change = outcome.outbox else { return nil }
        local.append(change)
        return outcome.change
    }

    /// Performs `command` on the others' side meanwhile.
    @discardableResult
    mutating func byThem(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        guard let outcome = try theirs.perform(command, recording: Self.recording), let change = outcome.outbox else { return nil }
        remote.append(change)
        return outcome.change
    }

    /// Delivers the others' changes and measures.
    mutating func measure() -> Divergence {
        for change in remote {
            serverSeq += 1
            mine.receive(change, serverSeq: serverSeq)
        }
        return Divergence.measure(local: local, remote: remote, state: mine.state, gap: Self.apart)
    }

    /// Sends this Mac's changes (the review's choices included) to the others; both converge.
    mutating func upload() {
        for change in local {
            serverSeq += 1
            theirs.receive(change, serverSeq: serverSeq)
        }
        local = []
        #expect(mine.state.stateHash == theirs.state.stateHash)
    }
}

/// DATA-023's review rows (data-merge.adoc, "Merge semantics"): two merge runs after the same page
/// and a field removed with bindings, measured on reconnect with their choices.
@Suite struct DataMergeReviewTests {
    struct Template {
        var page: OpID
        var field: OpID
        var block: OpID
    }

    /// One real page with a text block holding a `{{name}}` placeholder, on both sides.
    static func template(_ world: inout Reconnect) throws -> Template {
        try world.shared(SetBleed([PageList.synthesizedID], to: 0))
        let page = PageList(world.theirs.state).pages[0].id
        let field = try #require(try world.shared(AddFields("name"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let block = try #require(try world.shared(CreateTextBlock(.point(Point(x: 20, y: 20)), text: "Hi "))).createdObjects[0]
        let text = try #require(TextNode(block, in: world.theirs.state))
        try world.shared(InsertPlaceholder(node: block, at: text.anchor(at: 3), field: field))
        return Template(page: page, field: field, block: block)
    }

    static func records(_ names: [String], _ state: EngineState) -> RecordSet {
        RecordSet(model: DataModel(state), source: nil, raw: names.map { DataRecord(["name": $0]) })
    }

    /// The live pages in order.
    static func pages(_ state: EngineState) -> [OpID] {
        state.store.children(WellKnown.pages).filter { state.isLive($0) }
    }

    static func merge(_ names: [String], on world: inout Reconnect, template: Template, mine: Bool) throws -> [OpID] {
        let state = mine ? world.mine.state : world.theirs.state
        let command = MergeToPages(templates: [template.page], records: records(names, state), indices: Array(names.indices))
        let change = try #require(mine ? try world.byMe(command) : try world.byThem(command))
        return zip(change.ops, change.opIDs).compactMap { op, id in
            if case .create(let create)? = op.op, case .page? = create.props.kind { return id }
            return nil
        }
    }

    @Test(arguments: MergeRunConflict.Choice.allCases) func twoMergeRunsAfterOnePageAreOneEntryWithThreeChoices(choice: MergeRunConflict.Choice) throws {
        var world = Reconnect()
        let template = try Self.template(&world)
        let mine = try Self.merge(["Ada", "Bo"], on: &world, template: template, mine: true)
        let theirs = try Self.merge(["Cy", "Di", "Ed"], on: &world, template: template, mine: false)
        #expect(mine.count == 2 && theirs.count == 3)
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty, "new pages overlap nothing")
        #expect(divergence.decision(.standard) == .perObject)
        let review = ReviewModel(divergence, decision: divergence.decision(.standard))
        let entry = try #require(review.mergeRuns.first)
        #expect(review.mergeRuns.count == 1 && entry.page == template.page && entry.id == "merge-runs:\(template.page)")
        #expect(entry.mine.pages == mine && entry.theirs.pages == theirs)
        #expect(entry.mine.label == "Merge 2 records to pages" && entry.theirs.label == "Merge 3 records to pages")
        #expect(entry.mine.objects.count == 2 && entry.theirs.objects.count == 3, "one copied block per page")
        #expect(choice.title == ["Keep both, one after the other", "Remove theirs", "Remove mine"][MergeRunConflict.Choice.allCases.firstIndex(of: choice)!])
        let command = try #require(entry.command(choice, in: world.mine.state))
        try world.byMe(command)
        world.upload()
        let state = world.theirs.state
        switch choice {
        case .keepBoth:
            #expect(command.label == "Keep both merges")
            let (earlier, later) = entry.ordered
            #expect(Self.pages(state) == [template.page] + earlier.pages + later.pages)
            #expect(entry.command(.keepBoth, in: state) == nil, "already one after the other")
        case .removeTheirs, .removeMine:
            #expect(command.label == "Remove merged pages")
            let removed = choice == .removeMine ? entry.mine : entry.theirs
            let kept = choice == .removeMine ? entry.theirs : entry.mine
            #expect(Self.pages(state) == [template.page] + kept.pages)
            #expect((removed.pages + removed.objects).allSatisfy { !state.isLive($0) })
            #expect(kept.objects.allSatisfy { state.isLive($0) } && state.isLive(template.block))
            #expect(entry.command(choice, in: state) == nil, "nothing left to remove")
        }
    }

    @Test func runsAfterDifferentPagesOrOnOneSideAreNotListed() throws {
        var world = Reconnect()
        let template = try Self.template(&world)
        let second = try #require(try world.shared(AddPages(count: 1, after: template.page))).createdNodes[0]
        _ = try Self.merge(["Ada"], on: &world, template: template, mine: true)
        let other = Template(page: second, field: template.field, block: template.block)
        _ = try Self.merge(["Bo"], on: &world, template: other, mine: false)
        let divergence = world.measure()
        #expect(divergence.mergeRuns.isEmpty && !divergence.hasRows)
        var alone = Reconnect()
        let only = try Self.template(&alone)
        _ = try Self.merge(["Ada"], on: &alone, template: only, mine: true)
        try alone.byThem(SetNameOrNote([only.block], .name, "x"))
        #expect(alone.measure().mergeRuns.isEmpty)
    }

    /// Chunks of one merge are one run whatever prefix the label carries; any other change of the
    /// replica ends the run.
    @Test func consecutiveChunksFormOneRun() {
        func chunk(_ label: String, replica: UInt64 = 5, start: UInt64, pages: Int) -> Wiretuner_Doc_V1_Change {
            var change = Wiretuner_Doc_V1_Change()
            change.replica = replica
            change.startCounter = start
            change.label = label
            for index in 0..<pages {
                var page = Wiretuner_Doc_V1_NodeProps()
                page.page = Wiretuner_Doc_V1_PageProps()
                change.ops.append(Ops.create(parent: WellKnown.pages, position: [0x80, UInt8(index)], props: page))
                change.ops.append(Ops.create(parent: WellKnown.layers, position: [0x80, UInt8(index)], props: Wiretuner_Doc_V1_NodeProps()))
            }
            return change
        }
        let runs = DataMergeReview.runs([
            chunk("ana#1 Merge 3 records to pages", start: 1, pages: 2),
            chunk("ana#2 Merge 3 records to pages", start: 10, pages: 1),
            chunk("Merge 1 record to pages", replica: 6, start: 20, pages: 1),
            chunk("ana#3 Rename", start: 30, pages: 0),
            chunk("ana#4 Merge 3 records to pages", start: 40, pages: 1),
            chunk("Merge 1 record to pages", replica: 6, start: 50, pages: 0),
        ])
        #expect(runs.map(\.pages.count) == [3, 1, 1])
        #expect(runs.map(\.label) == ["Merge 3 records to pages", "Merge 1 record to pages", "Merge 3 records to pages"])
        #expect(runs[0].objects.count == 3 && runs[0].replica == 5 && runs[1].replica == 6)
        #expect(DataMergeReview.isMergeLabel("Merge 250 records to pages") && !DataMergeReview.isMergeLabel("Merge records to pages"))
        #expect(DataMergeReview.conflicts(local: [], remote: [chunk("Merge 1 record to pages", start: 1, pages: 1)], state: EngineState()).isEmpty)
    }

    @Test func aFieldRemovedRemotelyWhileBoundHereIsListedAndRestores() throws {
        var world = Reconnect()
        let template = try Self.template(&world)
        let city = try #require(try world.shared(AddFields("city"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let unused = try #require(try world.shared(AddFields("unused"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let shape = try #require(try world.shared(CreateShape(.ellipse, size: Size(width: 4, height: 4)))).createdObjects[0]
        try world.byThem(DeleteField(city))
        try world.byThem(DeleteField(unused))
        let text = try #require(TextNode(template.block, in: world.mine.state))
        try world.byMe(InsertPlaceholder(node: template.block, at: text.anchor(at: 0), field: city))
        try world.byMe(SetNameOrNote([shape], .name, "unrelated"))
        let divergence = world.measure()
        #expect(divergence.removedFields == [FieldRemovedEntry(field: city, name: "city", uses: 1, deletedLocally: false)])
        #expect(divergence.decision(.standard) == .perObject)
        let review = ReviewModel(divergence, decision: .perObject)
        let entry = try #require(review.removedFields.first)
        #expect(entry.title == "Field \u{201C}city\u{201D} removed with 1 binding" && entry.id == "field-removed:\(city)")
        #expect(FieldRemovedEntry(field: city, name: "a", uses: 2, deletedLocally: true).title.hasSuffix("2 bindings"))
        try world.byMe(entry.restore)
        world.upload()
        let placeholders = DataModel(world.theirs.state).placeholders(in: try #require(TextNode(template.block, in: world.theirs.state)))
        #expect(placeholders.map(\.label).contains("{{city}}"))
    }

    @Test func aFieldRemovedHereWhileBoundRemotelyIsListed() throws {
        var world = Reconnect()
        _ = try Self.template(&world)
        let flag = try #require(try world.shared(AddFields([AddFields.Field("shown", kind: .boolean)]))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let other = try #require(try world.shared(AddFields("other"))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)[0]
        let shape = try #require(try world.shared(CreateShape(.ellipse, size: Size(width: 4, height: 4)))).createdObjects[0]
        try world.byMe(DeleteField(flag))
        // Deleted and restored here: its last write is live, so it is not a removal.
        try world.byMe(DeleteField(other))
        try world.byMe(RestoreField(other))
        try world.byThem(BindToField([shape], field: flag, kind: .visibility))
        let divergence = world.measure()
        #expect(divergence.removedFields.map(\.field) == [flag] && divergence.removedFields[0].deletedLocally)
        #expect(divergence.removedFields[0].name == "shown")
    }

    @Test func aRemovedFieldNobodyTouchedIsNotListed() throws {
        var world = Reconnect()
        let template = try Self.template(&world)
        try world.byThem(DeleteField(template.field))
        let shape = try #require(try world.shared(CreateShape(.ellipse, size: Size(width: 4, height: 4)))).createdObjects[0]
        try world.byMe(SetNameOrNote([shape], .name, "elsewhere"))
        let divergence = world.measure()
        #expect(divergence.removedFields.isEmpty, "the placeholder predates the gap")
        #expect(DataMergeReview.name(of: OpID(counter: 999, replica: 9), in: world.mine.state) == "")
    }

    /// A sample is disposable (data-merge.adoc, "Sources"): two refreshes are never a review row.
    @Test func concurrentSamplesAreNeverListed() throws {
        var world = Reconnect()
        let source = try #require(try world.shared(AddSource(name: "Addresses", kind: .pasted))).insertedElements(WellKnown.settings, DataFieldsPaths.sources)[0]
        func sample(_ byte: UInt8) -> Wiretuner_Doc_V1_EmbeddedRecords {
            .with { $0.blobSha256 = Data(repeating: byte, count: 32); $0.mediaType = "text/csv"; $0.recordCount = UInt32(byte) }
        }
        try world.byMe(SetSample(source, sample(1)))
        try world.byThem(SetSample(source, sample(2)))
        let divergence = world.measure()
        #expect(divergence.entries.isEmpty && divergence.localObjects == 0 && divergence.remoteObjects == 0)
        world.upload()
    }

    /// Removals on both sides, sorted by field; a use on a node since deleted does not count as
    /// touched, a node created with a placeholder does.
    @Test func removalsOnBothSidesAreSortedAndCountLiveUses() throws {
        var world = Reconnect()
        _ = try Self.template(&world)
        let fields = try #require(try world.shared(AddFields([.init("a"), .init("b"), .init("c")]))).insertedElements(WellKnown.settings, DataFieldsPaths.fields)
        try world.byThem(DeleteField(fields[0]))
        try world.byMe(DeleteField(fields[1]))
        try world.byThem(DeleteField(fields[2]))
        // Mine: a new block with a placeholder of `a`, and one of `c` that I then delete.
        for field in [fields[0], fields[2]] {
            let block = try #require(try world.byMe(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "x"))).createdObjects[0]
            let text = try #require(TextNode(block, in: world.mine.state))
            try world.byMe(InsertPlaceholder(node: block, at: text.anchor(at: 0), field: field))
            if field == fields[2] { try world.byMe(DeleteNodes([block])) }
        }
        // Theirs: a bound shape using `b`.
        let shape = try #require(try world.byThem(CreateShape(.ellipse, size: Size(width: 4, height: 4)))).createdObjects[0]
        try world.byThem(BindToField([shape], field: fields[1], kind: .visibility))
        let removed = world.measure().removedFields
        #expect(removed.map(\.field) == [fields[0], fields[1]])
        #expect(removed.map(\.deletedLocally) == [false, true] && removed.map(\.name) == ["a", "b"])
    }

    /// The earlier run is the one whose first page id is smaller, whichever side it is on.
    @Test func theEarlierRunIsTheSmallerFirstPage() {
        let low = MergeRun(label: "Merge 1 record to pages", replica: 1, pages: [OpID(counter: 3, replica: 1)], objects: [])
        let high = MergeRun(label: "Merge 1 record to pages", replica: 2, pages: [OpID(counter: 9, replica: 2)], objects: [])
        #expect(MergeRunConflict(page: .zero, mine: high, theirs: low).ordered.earlier == low)
        #expect(MergeRunConflict(page: .zero, mine: low, theirs: high).ordered.later == high)
        #expect(MergeRun(label: "", replica: 0, pages: [], objects: []).first == .zero)
    }
}
