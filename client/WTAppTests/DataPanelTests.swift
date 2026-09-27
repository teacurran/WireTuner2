import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// DATA-017: the Data panel, its commands and the window's data session -- records from each
/// source kind, the record navigator and the preview, the canvas marks, the *field removed*
/// notice -- and the field sheets.
@Suite(.serialized) @MainActor struct DataPanelTests {
    // MARK: Panel and commands

    @Test func thePanelAndTheDataMergeCommandsFollowTheFrontWindow() async throws {
        let world = DataWorld()
        defer { world.close() }
        let registry = world.setup.environment.commands
        #expect(world.setup.environment.panels.descriptor(for: "data")?.title == "Data")
        for id in [DataFeatures.ID.insertField, DataFeatures.ID.insertBarcode, DataFeatures.ID.credentials, DataFeatures.ID.showHosts] {
            #expect(registry.command(id)?.validation() == .enabled, "\(id)")
        }
        #expect(registry.command(DataFeatures.ID.refresh)?.validation() == .disabled(DataFeatures.noSource))
        #expect(registry.command(DataFeatures.ID.merge)?.validation() == .disabled(DataFeatures.noRecords))
        #expect(registry.command(DataFeatures.ID.togglePreview)?.validation() == .disabled(DataFeatures.noRecords))
        #expect(registry.command(DataFeatures.ID.nextRecord)?.defaultKey == nil, "Cmd+Option+Right is the glyph strip's (FONT)")
        #expect(registry.command(DataFeatures.ID.insertField)?.menuPath?.components == ["File", "Data Merge"])
        let ids = await world.fields(["name", "city"])
        await world.paste("name\tcity\nAnn\tParis\nBo\tRome\n")
        #expect(world.session.records.count == 2)
        #expect(registry.command(DataFeatures.ID.refresh)?.validation() == .enabled)
        #expect(registry.command(DataFeatures.ID.togglePreview)?.validation() == .checked(false))
        registry.perform(DataFeatures.ID.togglePreview)
        #expect(world.session.preview.showing && world.document.recordPreview != nil)
        registry.perform(DataFeatures.ID.nextRecord)
        #expect(world.session.currentIndex == 1 && world.session.value(of: ids[0]) == "Bo")
        registry.perform(DataFeatures.ID.previousRecord)
        #expect(world.session.currentIndex == 0)
        registry.perform(DataFeatures.ID.togglePreview)
        #expect(!world.session.preview.showing && world.document.recordPreview == nil)
        // Every command runs from the menu; the sheets come up on the window.
        let sheets: [(CommandID, String)] = [(DataFeatures.ID.insertField, "sheet.insertField"), (DataFeatures.ID.insertBarcode, "sheet.insertBarcode"),
                                             (DataFeatures.ID.credentials, "sheet.credentials"), (DataFeatures.ID.showHosts, "sheet.hosts"), (DataFeatures.ID.merge, "sheet.merge")]
        for (id, sheet) in sheets {
            registry.perform(id)
            #expect(world.window.window?.attachedSheet?.identifier?.rawValue == sheet)
            world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        }
        registry.perform(DataFeatures.ID.refresh)
        registry.perform(DataFeatures.ID.embedSample)
        registry.perform(DataFeatures.ID.embedAll)
        registry.perform(DataFeatures.ID.addFieldsFromSource)
        registry.perform(DataFeatures.ID.exportData)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        // Without a window nothing is enabled.
        world.features.window = { nil }
        #expect(registry.command(DataFeatures.ID.insertField)?.validation() == .disabled(DataFeatures.noDocument))
        #expect(registry.command(DataFeatures.ID.refresh)?.validation() == .disabled(DataFeatures.noDocument))
        #expect(registry.command(DataFeatures.ID.merge)?.validation() == .disabled(DataFeatures.noDocument))
        #expect(registry.command(DataFeatures.ID.togglePreview)?.validation() == .disabled(DataFeatures.noDocument))
        #expect(world.features.front == nil && world.features.addFieldsFromSource() == nil && world.features.presentMerge() == nil)
        #expect(world.features.presentInsertField() == nil && world.features.presentFieldSheet(editing: nil) == nil && world.features.presentInsertBarcode() == nil)
        #expect(world.features.presentCredentials() == nil && world.features.presentHosts() == nil && world.features.presentWebSource(editing: nil) == nil)
        #expect(world.features.presentScriptSource() == nil && world.features.presentFileSheet(URL(filePath: "/tmp/x.csv"), json: false) == nil)
        #expect(world.features.connectPastedTable() == nil && world.features.connect(FileSourceModel(url: URL(filePath: "/none.csv"), json: false)) == nil)
        #expect(await world.features.exportData() == nil)
        await world.features.chooseFile(json: false)
        _ = DataPanel.optionsMenu(world.features).map(\.title)
    }

    @Test func thePanelBodyReadsTheSessionAndItsControlsWriteOneChangeEach() async throws {
        let world = DataWorld()
        defer { world.close() }
        let state = world.features.panel
        Render.view(DataPanelBody(state: state, features: world.features))
        state.window = { nil }
        Render.view(DataPanelBody(state: state, features: world.features))
        state.window = { world.window }
        let ids = await world.fields(["name", "amount"], kinds: [.text, .number])
        _ = await world.placeholderText("Hello ", field: ids[0])
        await world.paste("name\tamount\tzip\nAnn\t5\t111\nBo\t7\t222\n")
        let model = DataPanelModel(features: world.features, window: world.window, session: world.session)
        #expect(model.sourceTitle == "Pasted table (Pasted table)" && model.recordCount == 2 && model.recordNumber == 1)
        #expect(model.fieldRows.map(\.name) == ["name", "amount"] && model.fieldRows[0].uses == 1 && model.fieldRows[0].value == "Ann")
        #expect(model.columns == ["name", "amount", "zip"] && !model.showsMapping)
        #expect(model.sampleRows.columns == ["name", "amount", "zip"] && model.sampleRows.rows.count == 2)
        #expect(model.parameters.isEmpty)
        Render.view(DataPanelBody(state: state, features: world.features))
        // The mapping pairs a field with another column; choosing its own name unpairs it.
        DataPanelContent.mapping(ids[1], model).wrappedValue = "zip"
        await world.document.settle()
        #expect(model.path(of: ids[1]) == "zip" && model.showsMapping && world.document.undoTitle == "Undo Change mapping")
        #expect(world.session.value(of: ids[1]) == "111")
        Render.view(DataPanelBody(state: state, features: world.features))
        DataPanelContent.mapping(ids[1], model).wrappedValue = "zip"
        DataPanelContent.mapping(ids[1], model).wrappedValue = "amount"
        await world.document.settle()
        #expect(model.path(of: ids[1]) == "amount")
        #expect(model.path(of: OpID(counter: 999, replica: 9)) == "")
        // The navigator and the preview.
        let preview = DataPanelContent.preview(model)
        preview.wrappedValue = true
        #expect(preview.wrappedValue && world.document.recordPreview != nil)
        DataPanelContent.go(model)(2)
        #expect(model.recordNumber == 2)
        world.session.go(to: 99)
        #expect(model.recordNumber == 2)
        Render.view(DataPanelBody(state: state, features: world.features))
        preview.wrappedValue = false
        // Deleting a used field asks first; the answer decides.
        world.window.confirm = { _, _ in false }
        DataPanelContent.delete(ids[0], model)()
        await world.document.settle()
        #expect(world.session.model.field(ids[0]) != nil)
        world.window.confirm = { _, _ in true }
        DataPanelContent.delete(ids[0], model)()
        await world.document.settle()
        #expect(world.session.model.field(ids[0]) == nil && world.document.undoTitle == "Undo Delete field")
        model.deleteField(ids[0])
        model.deleteField(ids[1])
        await world.document.settle()
        #expect(world.session.model.fields.isEmpty)
        // The field sheet and Insert Field open from the rows.
        DataPanelContent.edit(ids[1], model)()
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        model.addField()
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        DataPanelContent.insert(ids[1], model)()
        model.merge()
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        // Connect… and Disconnect.
        // (Pasted Table reads the general pasteboard; its own test uses a private one.)
        for kind in DataPanelModel.Connect.allCases where kind != .pasted {
            DataPanelContent.connect(kind, model)()
            world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        }
        model.refresh()
        model.disconnect()
        await world.document.settle()
        #expect(world.session.model.activeSource == nil, "the Connect… items above may still be landing, so the undo title is not checked")
        let none = DataPanelModel(features: world.features, window: world.window, session: world.session)
        #expect(none.sourceTitle == "None" && !none.showsMapping)
        none.disconnect()
        #expect(DataPanelModel.kindTitle(.file) == "File" && DataPanelModel.kindTitle(.http) == "Web API" && DataPanelModel.kindTitle(.script) == "Script"
            && DataPanelModel.kindTitle(.unspecified) == "Unknown")
    }

    @Test func apiSourcesFetchThroughTheServiceWithTypedParameters() async throws {
        let world = DataWorld(pages: [[["$.name": "Ann", "id": "1"]], [["$.name": "Bo", "id": "2"]]])
        defer { world.close() }
        let ids = await world.fields(["name", "id"])
        var source = Wiretuner_Doc_V1_DataSource()
        source.name = "Orders"
        source.spec.kind = .http
        source.spec.http.url = "https://api.example.com/orders?since={{since}}"
        source.spec.http.params = [.with { $0.name = "since"; $0.defaultValue = "2026" }]
        source.mapping = [.with { $0.field = ids[0].elementID; $0.path = "$.name" }]
        _ = await world.document.perform(AddSource(source)).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.records.isEmpty && world.session.origin == .none)
        let model = DataPanelModel(features: world.features, window: world.window, session: world.session)
        #expect(model.parameters.map(\.name) == ["since"] && model.parameters[0].placeholder == "2026")
        DataPanelContent.parameter("since", model).wrappedValue = "2027"
        #expect(DataPanelContent.parameter("since", model).wrappedValue == "2027")
        Render.view(DataPanelBody(state: world.features.panel, features: world.features))
        await world.session.refresh()
        #expect(world.session.records.count == 2 && world.session.value(of: ids[0]) == "Ann")
        #expect(world.transport.snapshot.fetches.last?.params["since"] == "2027")
        if case .fetched = world.session.origin {} else { Issue.record("fetched") }
        #expect(world.session.status.contains("2 records -- fetched"))
        // The fetch is cached: a fresh load reads it.
        await world.session.load()
        #expect(world.session.origin == .cached && world.session.status == "2 records -- last fetch on this Mac")
        // A host not yet permitted: consent on a personal document, then the fetch again.
        world.transport.update { $0.guarded = "api.example.com" }
        await world.session.refresh()
        #expect(world.transport.snapshot.allowed == ["api.example.com"] && world.session.message == nil)
        // Denied consent fails with the documented message.
        world.transport.update { $0.guarded = "other.example.com" }
        world.features.services.consent = { _, _ in false }
        world.session.services = world.features.services
        await world.session.refresh()
        #expect(world.session.message == "Fetching from other.example.com was not permitted.")
        // A team document names the admins instead.
        world.transport.update { $0.admins = "Priya" }
        await world.session.refresh()
        #expect(world.session.message == "other.example.com is not a permitted host. Ask Priya to permit it.")
        // Offline: the embedded sample stays.
        world.transport.update { $0.guarded = nil; $0.failure = DataServiceError.offline }
        await world.session.refresh()
        #expect(world.session.message == DataServiceMessages.offline)
        // Signed out, or a URL that is not https.
        world.session.services.client = { nil }
        await world.session.refresh()
        #expect(world.session.message == DataServiceMessages.signedOut)
        let source2 = try #require(world.session.model.activeSource)
        _ = await world.document.perform(EditSource(source2.id, spec: .with { $0.http.url = "" }, paths: [[4, 2]])).value
        await world.document.settle()
        await world.session.refresh()
        #expect(world.session.message == "The source’s URL must be an https address.")
        #expect(world.session.effectiveParams(source2)["since"] == "2027")
    }

    @Test func fileScriptAndSampleSourcesLoadLocallyAndRefreshOnRequest() async throws {
        let world = DataWorld()
        defer { world.close() }
        _ = await world.fields(["name"])
        // A file source with a bookmark reads the file; Refresh reads it again.
        let url = try DataFileReaderFixtures.file("people.csv", "name;city\nAnn;Paris\nBo;Rome\n")
        let file = FileSourceModel(url: url, json: false)
        #expect(file.delimiter == ";" && file.encoding == "utf-8" && file.preview?.records.count == 2 && file.error == nil && !file.isJSON)
        _ = await world.features.connect(file)?.value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.records.count == 2 && world.session.origin == .file(name: "people.csv") && world.session.status == "2 records")
        try Data("name;city\nAnn;Paris\nBo;Rome\nCy;Oslo\n".utf8).write(to: url)
        await world.session.refresh()
        #expect(world.session.records.count == 3)
        // Embedding a sample asks the first time; later refreshes embed it again silently.
        world.session.confirmEmbed = { _, _ in false }
        #expect(await world.session.embed(all: false) == false)
        world.session.confirmEmbed = { _, _ in true }
        #expect(await world.session.embed(all: false))
        await world.document.settle()
        #expect(world.session.model.activeSource?.sample?.recordCount == 3 && world.document.undoTitle == "Undo Embed sample")
        #expect(await world.session.embed(all: true))
        await world.document.settle()
        #expect(world.session.model.activeSource?.sample?.complete == true)
        world.setup.environment.preferences.set(true, for: PreferenceCatalog.Automation.embedSampleRecords)
        await world.session.refresh()
        // The file gone: the sample is shown with the reason.
        try FileManager.default.removeItem(at: url)
        await world.session.load()
        #expect(world.session.message?.contains("showing the embedded sample") == true)
        if case .sample(3, false) = world.session.origin {} else { Issue.record("sample \(world.session.origin)") }
        await world.session.refresh()
        // A collaborator's copy has no bookmark: the sample, or nothing.
        let source = try #require(world.session.model.activeSource)
        _ = await world.document.perform(EditSource(source.id, spec: .with { $0.file.bookmark = Data() }, paths: [[2, 7]])).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.message == "The file is on another Mac -- showing the embedded sample.")
        await world.session.refresh()
        #expect(world.session.message == "The file is on another Mac; only that Mac can refresh it.")
        _ = await world.document.perform(SetSample(source.id, nil)).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.message?.hasPrefix("The file is on another Mac. Embed") == true && world.session.origin == .none)
        // A sample whose blob this Mac lacks.
        var missing = Wiretuner_Doc_V1_EmbeddedRecords()
        missing.blobSha256 = Data(repeating: 7, count: 32)
        missing.mediaType = "text/csv"
        _ = await world.document.perform(SetSample(source.id, missing)).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.message == "The file is on another Mac -- showing the embedded sample.")
        // A script source runs only on Refresh.
        let script = try #require(await world.document.perform(SaveScript(name: "People", source: "export function records(params) { return [{ name: 'Zoë' }, { name: params.x || 'Yan' }]; }")).value?.createdObjects.first)
        let scripts = ScriptSourceModel(scripts: DocumentScript.list(world.document.state))
        #expect(scripts.chosen == script && scripts.source?.spec.script.script.id == script.proto)
        _ = await world.document.perform(AddSource(scripts.source!)).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.records.isEmpty)
        await world.session.refresh()
        #expect(world.session.records.count == 2 && world.session.value(of: world.session.model.fields[0].id) == "Zoë")
        _ = await world.document.perform(DeleteScript(script)).value
        await world.document.settle()
        await world.session.refresh()
        #expect(world.session.message == "The source’s script is missing.")
        let bad = try #require(await world.document.perform(SaveScript(name: "Bad", source: "export function records() { throw new Error('nope'); }")).value?.createdObjects.first)
        var badSource = Wiretuner_Doc_V1_DataSource()
        badSource.spec.kind = .script
        badSource.spec.script.script.id = bad.proto
        _ = await world.document.perform(AddSource(badSource)).value
        await world.document.settle()
        await world.session.refresh()
        #expect(world.session.message?.contains("nope") == true)
        // No source: nothing, and Refresh does nothing.
        _ = await world.document.perform(SetActiveSource(nil)).value
        await world.document.settle()
        await world.session.load()
        await world.session.refresh()
        let embedded = await world.session.embed(all: false)
        #expect(world.session.status == "No source connected" && !embedded)
    }

    @Test func pastingReplacesThePastedRowsAndExportWritesTheResolvedRecords() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["name", "amount"], kinds: [.text, .number])
        _ = await world.document.perform(SetFieldFormat(ids[1], pattern: "0.00", locale: "en_US")).value
        await world.paste("name\tamount\nAnn\t5\n")
        #expect(world.session.records.count == 1 && world.session.status == "1 record")
        await world.paste("name\tamount\nAnn\t5\nBo\t\n")
        #expect(world.session.records.count == 2 && world.session.model.sources.count == 1, "pasting again replaces the rows")
        let table = DataFeatures.exportTable(world.session.records)
        #expect(table.columns == ["record", "name", "amount"] && table.records[0] == DataRecord(["record": "1", "name": "Ann", "amount": "5.00"]))
        #expect(table.records[1]["amount"] == nil)
        let destination = TestEnvironment.temporaryDirectory().appending(path: "export.csv")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(await world.features.exportData(to: destination) == destination)
        let written = try Data(contentsOf: destination)
        #expect(written.starts(with: [0xEF, 0xBB, 0xBF]))
        // DATA-022: the save panel's options -- fields, a range, no record column.
        let options = DataExportOptionsModel(records: world.session.records)
        #expect(options.fields.map(\.name) == ["name", "amount"] && options.chosen.count == 2 && options.to == 2 && options.export == DataExport(fields: options.chosen))
        options.binding(options.fields[1].id).wrappedValue = false
        #expect(!options.binding(options.fields[1].id).wrappedValue)
        options.binding(options.fields[1].id).wrappedValue = true
        options.binding(options.fields[1].id).wrappedValue = false
        options.allRecords = false
        options.from = 2
        options.to = 9
        options.recordColumn = false
        #expect(options.export == DataExport(fields: [options.fields[0].id], range: 2...2, recordColumn: false))
        Render.view(DataExportOptionsView(model: options))
        #expect(await world.features.exportData(to: destination, options: options.export) == destination)
        let chosenText = try String(contentsOf: destination, encoding: .utf8)
        #expect(chosenText.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline) == ["name", "Bo"])
        // A place that cannot be written says so.
        #expect(await world.features.exportData(to: URL(filePath: "/no/such/place/x.csv")) == nil)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        // Add Fields from Source adds the columns that are not fields yet.
        _ = await world.features.addFieldsFromSource()?.value
        #expect(world.features.addFieldsFromSource() == nil, "nothing left to add")
        // An empty pasteboard.
        let empty = NSPasteboard(name: NSPasteboard.Name("DataPanelTests-empty"))
        empty.clearContents()
        #expect(world.features.connectPastedTable(from: empty) == nil)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        // A blob store that fails leaves the document alone.
        world.features.blobs.directory = { throw CocoaError(.fileNoSuchFile) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DataPanelTests-fail"))
        pasteboard.clearContents()
        pasteboard.setString("a\n1\n", forType: .string)
        #expect(await world.features.connectPastedTable(from: pasteboard)?.value == nil)
        world.session.blobs = world.features.blobs
        world.session.confirmEmbed = { _, _ in true }
        let stored = await world.session.embed(all: false)
        #expect(!stored && world.session.message?.hasPrefix("The sample could not be stored") == true)
    }

    // MARK: Notices and marks

    @Test func aRemoteDeleteOfAUsedFieldPostsRestoreAndTheCanvasMarksPlaceholders() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["name", "flag"], kinds: [.text, .boolean])
        let text = try #require(await world.placeholderText("Dear ", field: ids[0]))
        let rect = await world.document.addRectangles([Rect(x: 300, y: 300, width: 20, height: 20)])[0]
        _ = await world.document.perform(BindToField([rect.opID], field: ids[1], kind: .visibility)).value
        await world.document.settle()
        _ = world.session
        _ = await world.document.receiveRemote(DeleteField(ids[0]))
        #expect(world.window.pageNotices.notices.map(\.action) == ["Restore field"])
        #expect(world.window.pageNotices.notices[0].text == "The field “name” was removed; 1 place uses it")
        world.window.performNotice(world.window.pageNotices.notices[0].id)
        await world.document.settle()
        #expect(DataModel(world.document.state).field(ids[0]) != nil)
        // Two uses are counted.
        #expect(world.document.state.textNode(text) != nil)
        _ = await world.placeholderText("Hi ", field: ids[0], at: Point(x: 60, y: 200))
        _ = await world.document.receiveRemote(DeleteField(ids[0]))
        #expect(world.window.pageNotices.notices.last?.text.hasSuffix("2 places use it") == true)
        // The marks: a red placeholder, a missing badge after the boolean field goes.
        let overlay = try #require(world.features.overlay(for: world.window))
        overlay.refresh()
        #expect(overlay.spans.count == 2 && overlay.spans.allSatisfy(\.missing) && overlay.badges == [DataCanvasOverlay.Badge(node: rect.opID, missing: false)])
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        world.window.canvas.furnitureDrawer?(context)
        overlay.draw(in: context, viewport: world.window.canvas.viewport)
        overlay.highlights = { false }
        overlay.previewing = { true }
        overlay.draw(in: context, viewport: world.window.canvas.viewport)
        _ = await world.document.perform(DeleteField(ids[1])).value
        overlay.refresh()
        #expect(overlay.badges == [DataCanvasOverlay.Badge(node: rect.opID, missing: true)])
        // A session with no window posts nothing.
        let orphan = DataSession(document: world.document)
        orphan.postRemoved([])
        orphan.close()
        orphan.close()
        // Attaching twice reuses the session; closing the window forgets it.
        #expect(world.features.attach(world.window) === world.session)
        world.features.windowBecameMain(world.window)
        world.features.windowBecameMain(nil)
        world.features.detach(world.window)
        world.features.detach(world.window)
        #expect(world.features.overlay(for: world.window) == nil)
    }

    // MARK: Field sheets

    @Test func theFieldSheetAddsAndEditsFieldsOneChangePerSetting() async throws {
        let world = DataWorld()
        defer { world.close() }
        let script = try #require(await world.document.perform(SaveScript(name: "Upper", source: "export function transform(v) { return String(v).toUpperCase(); }")).value?.createdObjects.first)
        let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> = { world.document.perform($0) }
        let add = FieldSheetModel(document: world.document, field: nil, perform: perform)
        #expect(add.title == "Add Field" && add.button == "Add" && !add.usesFormat && add.scripts.map(\.id) == [script])
        Render.view(FieldSheet(model: add, close: {}))
        add.name = "1bad"
        #expect(!add.commit() && add.error?.contains("not a valid field name") == true)
        add.name = "price"
        add.kind = .number
        #expect(add.usesFormat && add.patterns == FieldSheetModel.numberPatterns)
        FieldSheet.pattern("#,##0.00", add)()
        add.transform = script
        Render.view(FieldSheet(model: add, close: {}))
        var closed = 0
        FieldSheet.commit(add, { closed += 1 })()
        #expect(closed == 1)
        await world.document.settle()
        try await Task.sleep(for: .milliseconds(50))
        await world.document.settle()
        let price = try #require(DataModel(world.document.state).field(named: "price"))
        #expect(price.kind == .number && price.pattern == "#,##0.00" && price.transform == script)
        let duplicate = FieldSheetModel(document: world.document, field: nil, perform: perform)
        duplicate.name = "PRICE"
        #expect(!duplicate.commit() && duplicate.error == "A field named “price” already exists.")
        // Editing writes each changed setting as its own labelled change.
        let edit = FieldSheetModel(document: world.document, field: price.id, perform: perform)
        #expect(edit.title == "Edit Field" && edit.button == "Save" && edit.name == "price")
        edit.name = "cost"
        edit.kind = .date
        #expect(edit.patterns == FieldSheetModel.datePatterns)
        edit.pattern = "Short"
        edit.locale = "de_DE"
        edit.transform = nil
        #expect(edit.commit())
        await world.document.settle()
        let cost = try #require(DataModel(world.document.state).field(price.id))
        #expect(cost.name == "cost" && cost.kind == .date && cost.pattern == "Short" && cost.locale == "de_DE" && cost.transform == nil)
        #expect(edit.commit(), "nothing changed: nothing written")
        let plain = FieldSheetModel(document: world.document, field: price.id, perform: perform)
        plain.locale = "fr_FR"
        #expect(plain.commit())
        await world.document.settle()
        #expect(DataModel(world.document.state).field(price.id)?.locale == "fr_FR")
        // The sheet from the features, and Insert Field.
        let sheet = try #require(world.features.presentFieldSheet(editing: nil))
        #expect(sheet.field == nil && world.window.window?.attachedSheet?.identifier?.rawValue == "sheet.dataField")
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        let insert = try #require(world.features.presentInsertField())
        #expect(insert.chosen == price.id)
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
        Render.view(InsertFieldSheet(model: insert, close: {}))
        Render.view(InsertFieldSheet(model: InsertFieldModel(fields: []) { _ in }, close: {}))
        // No text block to insert into: a status message.
        InsertFieldSheet.commit(insert, {})()
        // One selected block takes the placeholder at its end.
        let node = try #require(await world.document.addText("Total: ", at: Point(x: 50, y: 50)))
        world.window.selection.model.set(Selection([SelectionID(node)]))
        #expect(world.features.insertField(price.id, in: world.window))
        await world.document.settle()
        #expect(world.document.state.textNode(node)?.string == "Total: {{cost}}")
        // With the Text tool editing, at its insertion point.
        let session = TextEditingSession(document: world.document, sink: world.window.objectEditing, target: .node(node))
        world.window.objectEditing.textSession = session
        session.select(anchor: 0, focus: 0)
        #expect(world.features.insertField(price.id, in: world.window))
        await session.settle()
        await world.document.settle()
        #expect(world.document.state.textNode(node)?.string == "{{cost}}Total: {{cost}}")
        world.window.objectEditing.textSession = nil
    }
}

/// Files for the reader-backed sources.
enum DataFileReaderFixtures {
    static func file(_ name: String, _ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DataFixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
