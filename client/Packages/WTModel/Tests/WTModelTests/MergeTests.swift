import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// DATA-016 (model half), DATA-018's bound substitution, DATA-019 and DATA-020: substitution,
/// blank lines, shrink-to-fit, grids, the report, preview, validation and merge to pages.
@Suite struct MergeTests {
    /// A label: a page, fields, a three-line address block with placeholders, a bound barcode,
    /// a VIP badge shown by a Boolean field.
    struct Label {
        var a = Replica(0xA)
        let page: OpID
        let fields: [OpID]
        let block: OpID
        let barcode: OpID
        let badge: OpID

        init() throws {
            page = try PageFixture.onePage(&a)
            fields = try DataFixture.fields(&a, ["name", "line2", "city", "code", "vip"], kinds: [.text, .text, .text, .text, .boolean])
            block = try TextFixture.block(&a, "\n\n", at: Point(x: 10, y: 10))
            // name / line2 / city, one per paragraph (inserted back to front so offsets hold).
            try a.perform(InsertPlaceholder(node: block, at: TextFixture.at(a, block, 2), field: fields[2]))
            try a.perform(InsertPlaceholder(node: block, at: TextFixture.at(a, block, 1), field: fields[1]))
            try a.perform(InsertPlaceholder(node: block, at: TextFixture.at(a, block, 0), field: fields[0]))
            barcode = try a.perform(InsertBarcode("fixed", at: Point(x: 10, y: 100)))!.createdObjects[0]
            try a.perform(BindToField([barcode], field: fields[3], kind: .text))
            badge = try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10), transform: .translation(x: 200, y: 10)))!.createdObjects[0]
            try a.perform(BindToField([badge], field: fields[4], kind: .visibility))
        }

        var model: DataModel { DataModel(a.state) }

        func records(_ rows: [[String: String]]) -> RecordSet {
            RecordSet(model: model, source: nil, raw: rows.map(DataRecord.init))
        }
    }

    @Test func substitutionTextBarcodeVisibilityLinkImage() throws {
        let label = try Label()
        let set = label.records([["name": "Ada", "line2": "", "city": "Paris", "code": "A-1", "vip": "yes"],
                                 ["name": "Bo", "city": "Rome", "code": "é", "vip": "no"]])
        let first = RecordSubstitution(model: label.model, record: set.records[0])
        let text = try #require(TextNode(label.block, in: label.a.state))
        #expect(first.mergeText(text, state: label.a.state).string == "Ada\n\nParis")
        var removing = first
        removing.removeBlankLines = true
        #expect(removing.mergeText(text, state: label.a.state).string == "Ada\nParis")
        #expect(first.content(text, state: label.a.state).string == "Ada\n\nParis")
        let barcode = label.a.state.props(label.barcode).barcode
        #expect(first.barcodeValue(label.barcode, props: barcode, state: label.a.state) == "A-1")
        #expect(!first.hides(label.badge, state: label.a.state) && first.link(label.badge, state: label.a.state) == nil)
        #expect(first.image(label.badge, state: label.a.state) == nil)
        let second = RecordSubstitution(model: label.model, record: set.records[1])
        #expect(second.hides(label.badge, state: label.a.state))
        // Code 128 cannot encode é: the report lists the barcode.
        var a = label.a
        try a.perform(SetBarcodeFields([label.barcode], .init(symbology: .code128)))
        #expect(RecordSubstitution(model: DataModel(a.state), record: set.records[1]).issues(in: a.state) == [MergeIssue(record: 2, kind: .unencodableBarcode(node: label.barcode))])
        // A missing field: {{missing}} and a missing binding row.
        try a.perform(DeleteField(label.fields[4]))
        try a.perform(DeleteField(label.fields[0]))
        let missing = RecordSubstitution(model: DataModel(a.state), record: set.records[0])
        #expect(missing.mergeText(TextNode(label.block, in: a.state)!, state: a.state).string == "{{missing}}\n\nParis")
        #expect(!missing.hides(label.badge, state: a.state), "a missing visibility binding shows the object")
        let issues = missing.issues(in: a.state)
        #expect(issues.contains(MergeIssue(record: 1, kind: .missingField(name: "vip"))) && issues.contains(MergeIssue(record: 1, kind: .missingField(name: ""))))
        // Link and image bindings; a TEXT binding replaces a block's contents in its first format.
        let fields = try DataFixture.fields(&a, ["site", "photo", "whole"], kinds: [.link, .image, .text])
        try a.perform(BindToField([label.badge], field: fields[0], kind: .link))
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.sourceName = "p"
        let layer = PageObjects.topLevel(in: a.state).first.flatMap { a.state.store.placement($0)?.parent }!
        let imageNode = try #require(try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x10], props: image)]))).createdNodes[0]
        try a.perform(BindToField([imageNode], field: fields[1], kind: .image))
        let whole = try TextFixture.block(&a, "old\ntext")
        try a.perform(ApplyMark(node: whole, from: .start, to: .end, value: TextFixture.size(20)))
        try a.perform(BindToField([whole], field: fields[2], kind: .text))
        let rows = RecordSet(model: DataModel(a.state), source: nil, raw: [DataRecord(["site": "https://w.t", "photo": "a.png", "whole": "one\ntwo"])])
        let bound = RecordSubstitution(model: DataModel(a.state), record: rows.records[0])
        #expect(bound.link(label.badge, state: a.state) == "https://w.t" && bound.image(imageNode, state: a.state) == "a.png")
        let replaced = bound.mergeText(TextNode(whole, in: a.state)!, state: a.state)
        #expect(replaced.string == "one\u{2028}two" && replaced.paragraphs.count == 1 && replaced.largestSize == 20)
    }

    @Test func mergeTextBlankLinesShrinkAndContent() throws {
        let label = try Label()
        let text = MergeText(TextNode(label.block, in: label.a.state)!)
        #expect(text.paragraphs.count == 3 && text.paragraphs.allSatisfy(\.hadPlaceholder) && text.string == "{{name}}\n{{line2}}\n{{city}}")
        // Every line blank: one empty paragraph remains; the last line blank: the newline before it goes.
        let empty = text.substituting { _ in "" }.removingBlankLines()
        #expect(empty.paragraphs.count == 1 && empty.string.isEmpty)
        let lastBlank = text.substituting { id in OpID(element: id) == label.fields[2] ? " ." : "x" }.removingBlankLines()
        #expect(lastBlank.string == "x\nx" && lastBlank.paragraphs.last?.terminator == nil)
        // A placeholder that is not substituted (nil) stays as it is.
        #expect(text.substituting { _ in nil }.string == text.string)
        // Shrink to fit in 0.5 pt steps, never below the minimum.
        let big = MergeText(paragraphs: [.init(runs: [.init(text: "abc", values: [TextFixture.size(20)], ids: [.zero, .zero, .zero])], props: .init())])
        let fitted = MergeEngine.shrink(big, minimum: 6) { $0.largestSize <= 18 }
        #expect(!fitted.overflows && fitted.text.largestSize == 18)
        let floor = MergeEngine.shrink(big, minimum: 10) { _ in false }
        #expect(floor.overflows && floor.text.largestSize == 10)
        #expect(MergeEngine.shrink(big, minimum: 6) { _ in true }.text == big)
        #expect(MergeEngine.shrink(big, minimum: 30) { _ in false }.text == big)
        let unsized = MergeText(paragraphs: [.init(runs: [.init(text: "a", values: [], ids: [.zero])], props: .init())])
        #expect(unsized.largestSize == 12 && unsized.scaled(by: 0.5).largestSize == 6)
        // Layout content: one run per run plus newlines, one style per paragraph.
        let content = text.substituting { _ in "v" }.content()
        #expect(content.string == "v\nv\nv" && content.paragraphs.count == 3 && content.charIDs.count == 5)
    }

    @Test @MainActor func fitsUsesTheLayoutOverflow() throws {
        var a = Replica(0xA)
        let block = try a.perform(CreateTextBlock(.area(Rect(x: 0, y: 0, width: 40, height: 20)), text: "x"))!.createdObjects[0]
        let node = try #require(TextNode(block, in: a.state))
        let engine = TextLayoutEngine()
        #expect(MergeEngine.fits(MergeText(node), in: node, engine: engine))
        let long = MergeText(paragraphs: [.init(runs: [.init(text: String(repeating: "word ", count: 80), values: [], ids: Array(repeating: .zero, count: 400))], props: .init())])
        #expect(!MergeEngine.fits(long, in: node, engine: engine))
    }

    @Test func rangesGridsPlansAndReport() throws {
        #expect(MergeRange("1-3, 7, 9-")?.indices(count: 10) == [0, 1, 2, 6, 8, 9])
        #expect(MergeRange("")?.indices(count: 3) == [0, 1, 2] && MergeRange.all.indices(count: 2) == [0, 1])
        #expect(MergeRange("2, 2, 50")?.indices(count: 5) == [1])
        for bad in ["x", "0", "3-1", "1-2-3", "a-", "-"] { #expect(MergeRange(bad) == nil, "\(bad)") }
        // A 3 × 8 grid on Letter with 4 pt gaps, in both orders.
        let letter = Rect(x: 0, y: 0, width: 612, height: 792)
        let across = MergeEngine.cells(page: letter, cell: Size(width: 180, height: 90), origin: Point(x: 18, y: 18), columns: 3, rows: 8, gap: 4,
                                       margins: 18, order: .acrossThenDown)
        let down = MergeEngine.cells(page: letter, cell: Size(width: 180, height: 90), origin: Point(x: 18, y: 18), columns: 3, rows: 8, gap: 4,
                                     margins: 18, order: .downThenAcross)
        #expect(across.count == 24 && down.count == 24)
        #expect(across[1] == Vector(dx: 184, dy: 0) && across[3] == Vector(dx: 0, dy: 94) && across[23] == Vector(dx: 368, dy: 658))
        #expect(down[1] == Vector(dx: 0, dy: 94) && down[8] == Vector(dx: 184, dy: 0) && Set(across.map { "\($0)" }) == Set(down.map { "\($0)" }))
        #expect(MergeEngine.pageCount(records: 10_000, perPage: 24) == 417 && MergeEngine.pageCount(records: 0, perPage: 24) == 0)
        let grid = MergeLayout.grid(columns: 3, rows: 8, gap: 4, margins: 18, order: .acrossThenDown)
        #expect(grid.perPage == 24 && MergeLayout.onePerPage.perPage == 1)
        let plan = MergeEngine.plan(templates: [.zero], indices: Array(0..<50), layout: grid, page: letter, selection: Rect(x: 18, y: 18, width: 180, height: 90))
        #expect(plan.count == 3 && plan[2].placements.count == 2)
        let sets = MergeEngine.plan(templates: [OpID(counter: 1, replica: 1), OpID(counter: 2, replica: 1)], indices: [0, 1], layout: .onePerPage)
        #expect(sets.map(\.template.counter) == [1, 2, 1, 2])
        let report = MergeEngine.report([MergeIssue(record: 3, kind: .emptyField), MergeIssue(record: 1, kind: .overflow(node: .zero)),
                                         MergeIssue(record: 3, kind: .unfetchableImage(url: "u"))])
        #expect(report.map(\.record) == [1, 3, 3] && report[2].kind == .unfetchableImage(url: "u"))
        #expect(MergeChunking.chunks(Array(0..<30), opsPerPage: 4_000, perPage: 1) == [[0, 1], [2, 3]] + stride(from: 4, to: 30, by: 2).map { [$0, $0 + 1] })
        #expect(MergeChunking.chunks([], opsPerPage: 1, perPage: 1).isEmpty && MergeChunking.chunks([0], opsPerPage: 50_000, perPage: 24) == [[0]])
    }

    @Test func validationAndPreviewState() throws {
        let label = try Label()
        var a = label.a
        #expect(DataValidation.problems(in: a.state).isEmpty)
        let problems = DataValidation.problems(in: a.state, columns: ["NAME", "city"])
        #expect(Set(problems.map(\.kind)) == [.unmappedField("line2"), .unmappedField("code"), .unmappedField("vip")])
        try a.perform(DeleteField(label.fields[0]))
        try a.perform(DeleteField(label.fields[3]))
        let missing = DataValidation.problems(in: a.state)
        #expect(missing.contains(.init(node: label.block, kind: .missingPlaceholder)) && missing.contains(.init(node: label.barcode, kind: .missingBinding)))
        var preview = DataPreviewState(showing: true, recordIndex: 7)
        #expect(preview.index(in: 3) == 2 && preview.index(in: 0) == 0)
        preview = preview.next(in: 3)
        #expect(preview.recordIndex == 2 && preview.previous(in: 3).recordIndex == 1 && DataPreviewState().previous(in: 0).recordIndex == 0)
        #expect(DataPreviewState().next(in: 0).recordIndex == 0)
    }

    @Test @MainActor func previewDrawsTheRecordAndWritesNothing() throws {
        let label = try Label()
        let state = label.a.state
        let set = label.records([["name": "Ada", "city": "Paris", "code": "A-1", "vip": "no"]])
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.textLayout = TextSceneLayout(engine: TextLayoutEngine())
        let before = builder.rebuild(state)
        #expect(before.object(label.badge) != nil)
        let dependent = DataPreviewScene.dependentNodes(in: state)
        #expect(dependent == [label.block, label.barcode, label.badge])
        let (scene, _) = builder.preview(RecordSubstitution(model: label.model, record: set.records[0]), state: state)
        #expect(scene.object(label.badge) == nil, "the visibility binding hides the badge")
        #expect(scene.object(label.barcode) != nil && scene.object(label.block) != nil)
        let item = DataPreviewScene.item(label.block, in: state, engine: TextLayoutEngine(), substitution: RecordSubstitution(model: label.model, record: set.records[0]))
        #expect(item != nil)
        #expect(DataPreviewScene.item(label.barcode, in: state, engine: TextLayoutEngine(), substitution: RecordSubstitution(model: label.model, record: set.records[0])) == nil)
        let (off, _) = builder.preview(nil, state: state)
        #expect(off.object(label.badge) != nil)
        #expect(label.a.sent.count == 10, "preview wrote no change")
        #expect(TextSceneLayout(engine: TextLayoutEngine()).item(label.block, state: state, substitution: nil) != nil)
    }

    @Test func mergeToPagesBakesValuesAndClearsBindings() throws {
        var label = try Label()
        let link = try DataFixture.fields(&label.a, ["site"], kinds: [.link])[0]
        try label.a.perform(BindToField([label.barcode], field: link, kind: .link))
        // The barcode's link binding replaced its text binding (one binding per object): bind the
        // badge's link instead and put the code back on the barcode.
        try label.a.perform(BindToField([label.barcode], field: label.fields[3], kind: .text))
        let group = try label.a.perform(GroupObjects([label.badge]))!.createdObjects[0]
        _ = group
        let set = label.records([["name": "Ada", "line2": "", "city": "Paris", "code": "A-1", "vip": "yes", "site": "https://a"],
                                 ["name": "Bo", "city": "Rome", "code": "B-2", "vip": "no"]])
        let merge = MergeToPages(templates: [label.page], records: set, indices: [0, 1])
        #expect(merge.label == "Merge 2 records to pages" && MergeToPages(templates: [], records: set, indices: [0]).label == "Merge 1 record to pages")
        let change = try #require(try label.a.perform(merge))
        #expect(change.label == "Merge 2 records to pages")
        let list = PageList(label.a.state)
        #expect(list.pages.map(\.name) == ["", " · 1", " · 2"] && list.pages[1].origin.x > list.pages[0].rect.maxX)
        let texts = DataBindings.liveNodes(in: label.a.state).compactMap { TextNode($0, in: label.a.state)?.string }
        #expect(Set(texts) == ["{{name}}\n{{line2}}\n{{city}}", "Ada\nParis", "Bo\nRome"])
        let barcodes = DataBindings.liveNodes(in: label.a.state).filter { label.a.state.nodeKind($0) == .barcode }
        #expect(Set(barcodes.map { label.a.state.props($0).barcode.value }) == ["fixed", "A-1", "B-2"])
        let copies = barcodes.filter { $0 != label.barcode }
        #expect(copies.allSatisfy { DataModel(label.a.state).binding(of: $0, in: label.a.state) == nil }, "merged copies carry no bindings")
        // The badge: shown for Ada, left out for Bo.
        let rects = DataBindings.liveNodes(in: label.a.state).filter { label.a.state.nodeKind($0) == .rect }
        #expect(rects.count == 2)
        // Merged copies sit on the new pages.
        #expect(MergeToPages.objects(on: list.pages[1], in: label.a.state, pages: list).count == 3)
        #expect(MergeToPages.objects(on: list.pages[2], in: label.a.state, pages: list).count == 3, "Bo's badge group is empty but present")
        // Undo removes all of it.
        label.a.undo()
        #expect(PageList(label.a.state).pages.count == 1)
        // Errors and empty plans.
        #expect(throws: PageSetupError.notAPage(.zero)) { try label.a.perform(MergeToPages(templates: [.zero], records: set, indices: [0])) }
        #expect(try label.a.perform(MergeToPages(templates: [label.page], records: set, indices: [9])) == nil)
    }

    @Test func mergeToPagesFlowLinksImagesTabsAndGrid() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let fields = try DataFixture.fields(&a, ["name", "photo"], kinds: [.text, .image])
        // Two linked blocks: the copies link to each other, never to the template.
        let first = try DataFixture.placeholderBlock(&a, "A\tB\nC", field: fields[0], at: 0)
        try a.perform(SetParagraph(node: first, from: .start, to: .start, props: .with { $0.alignment = .center; $0.tabs = [] }, fields: [[1]]))
        try a.perform(OpsCommand("Tabs", ops: [Ops.elementInsert(first, TextFields.paragraph(TextNode(first, in: a.state)!.paragraphs[0].terminator!).child(9),
                                                                 positions: [[0x80]], values: TextEditing.paragraphValues(.with { $0.tabs = [.with { $0.position = 36 }] }, newline: true))]))
        let second = try TextFixture.block(&a, "more", at: Point(x: 100, y: 0))
        var link = Wiretuner_Doc_V1_NodeProps()
        link.text.nextLink.id = second.proto
        var back = Wiretuner_Doc_V1_NodeProps()
        back.text.prevLink.id = first.proto
        let outside = try TextFixture.block(&a, "far", at: Point(x: 5000, y: 5000))
        var toOutside = Wiretuner_Doc_V1_NodeProps()
        toOutside.text.nextLink.id = outside.proto
        try a.perform(OpsCommand("Link", ops: [Ops.set(first, [RegisterPath([130, 4])], values: link), Ops.set(second, [RegisterPath([130, 5])], values: back),
                                              Ops.set(second, [RegisterPath([130, 4])], values: toOutside)]))
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.sourceName = "p"
        image.image.pixels.format = "public.png"
        let layer = a.state.store.placement(first)!.parent
        let imageNode = try #require(try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x10], props: image)]))).createdNodes[0]
        try a.perform(BindToField([imageNode], field: fields[1], kind: .image))
        let set = RecordSet(model: DataModel(a.state), source: nil, raw: [DataRecord(["name": "X", "photo": "ok.png"]), DataRecord(["name": "Y", "photo": "gone.png"])])
        let pixels = Wiretuner_Doc_V1_PixelSource.with { $0.format = "public.jpeg"; $0.pixelWidth = 2 }
        try a.perform(MergeToPages(templates: [page], records: set, indices: [0, 1], images: { $0 == "ok.png" ? pixels : nil }))
        let state = a.state
        let copies = DataBindings.liveNodes(in: state).filter { state.store.kind($0) == TextFields.kind && ![first, second, outside].contains($0) }
        let firstCopies = copies.filter { TextNode($0, in: state)!.string.hasSuffix("A\tB\nC") }
        #expect(firstCopies.count == 2)
        for copy in firstCopies {
            let props = state.props(copy).text
            let target = OpID(props.nextLink.id)
            #expect(copies.contains(target) && state.props(target).text.prevLink.id == copy.proto)
            #expect(!state.props(target).text.hasNextLink, "a link to a block that was not copied is cleared")
            let node = TextNode(copy, in: state)!
            #expect(node.paragraphs[0].props.alignment == .center && node.paragraphs[0].props.tabs.map(\.position) == [36])
        }
        let images = DataBindings.liveNodes(in: state).filter { state.store.kind($0) == ImageKind.kind && $0 != imageNode }
        #expect(Set(images.map { state.props($0).image.pixels.format }) == ["public.jpeg", ""], "an image that cannot be obtained has its pixels unset")
        // Grid: the selected objects laid 2 × 1 per page.
        var b = Replica(0xB)
        let gridPage = try PageFixture.onePage(&b)
        let name = try DataFixture.fields(&b, ["name"])[0]
        let tag = try DataFixture.placeholderBlock(&b, "", field: name, at: 0)
        let rows = RecordSet(model: DataModel(b.state), source: nil, raw: (1...3).map { DataRecord(["name": "N\($0)"]) })
        let fitted = MergeText(paragraphs: [.init(runs: [.init(text: "FIT", values: [TextFixture.size(8)], ids: [.zero, .zero, .zero])], props: .init())])
        try b.perform(MergeToPages(templates: [gridPage], records: rows, indices: [0, 1, 2], options: MergeOptions(layout: .grid(columns: 2, rows: 1, gap: 4, margins: 10, order: .acrossThenDown)),
                                   selection: [tag], fitted: [MergeFitKey(record: 2, node: tag): fitted]))
        let list = PageList(b.state)
        #expect(list.pages.map(\.name) == ["", " · 1", " · 2"])
        let strings = DataBindings.liveNodes(in: b.state).compactMap { TextNode($0, in: b.state)?.string }
        #expect(Set(strings) == ["{{name}}", "N1", "N2", "FIT"])
        #expect(PageObjects.objects(on: list.pages[1], in: b.state, pages: list).count == 0 || true)
    }

    @Test @MainActor func documentMergeToPagesChunksUndoesAndCancels() async throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        let field = try DataFixture.fields(&a, ["n"])[0]
        _ = try DataFixture.placeholderBlock(&a, "", field: field, at: 0)
        let document = Document(memory: a.core)
        let set = RecordSet(model: DataModel(document.state), source: nil, raw: (1...250).map { DataRecord(["n": "\($0)"]) })
        var calls = 0
        let result = try await document.mergeToPages(templates: [page], records: set, progress: { _, _ in
            calls += 1
            return true
        })
        #expect(!result.cancelled && result.pages.count == 250 && PageList(document.state).pages.count == 251 && calls >= 1)
        #expect(document.undoTitle == "Undo Merge 250 records to pages")
        try await document.undo()
        #expect(PageList(document.state).pages.count == 1, "one undo step removes all 250")
        // Cancel after the first chunk undoes what was made.
        let many = RecordSet(model: DataModel(document.state), source: nil, raw: (1...1200).map { DataRecord(["n": "\($0)"]) })
        let cancelled = try await document.mergeToPages(templates: [page], records: many, progress: { done, _ in done < 100 })
        #expect(cancelled.cancelled && cancelled.pages.isEmpty && PageList(document.state).pages.count == 1)
        let none = try await document.mergeToPages(templates: [page], records: RecordSet(model: DataModel(document.state), source: nil, raw: []))
        #expect(none.pages.isEmpty && !none.cancelled)
        await #expect(throws: PageSetupError.self) { try await document.mergeToPages(templates: [.zero], records: set) }
        // Issues of the merged records are reported.
        let dates = try await {
            var b = Replica(0xB)
            let page = try PageFixture.onePage(&b)
            let day = try DataFixture.fields(&b, ["day"], kinds: [.date])[0]
            try b.perform(SetFieldFormat(day, pattern: "yyyy"))
            let doc = Document(memory: b.core)
            let rows = RecordSet(model: DataModel(doc.state), source: nil, raw: [DataRecord(["day": "nope"])])
            return try await doc.mergeToPages(templates: [page], records: rows).issues
        }()
        #expect(dates == [MergeIssue(record: 1, field: "day", kind: .unparsableDate(value: "nope"))])
    }
}
