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

/// The edges of the data merge and scripting UI: every report kind, singular counts, missing
/// values, sessions without a window, sheets built from existing sources, the Scripts menu's
/// watcher and selection, and the view branches the main suites do not reach.
@Suite(.serialized) @MainActor struct DataUIEdgeTests {
    static func endSheet(_ world: DataWorld) {
        world.window.window?.attachedSheet.map { world.window.window?.endSheet($0) }
    }

    /// The first view of type `T` under `view`.
    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }

    @Test func theMergeSheetsEdges() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["person", "vip", "extra"], kinds: [.text, .boolean, .text])
        let page = world.document.activePage.rect
        let area = Rect(x: page.minX + 20, y: page.minY + 20, width: 30, height: 14)
        let text = try #require(await world.document.perform(CreateTextBlock(.area(area), text: "Name: ")).value?.createdObjects.first)
        _ = await world.document.perform(InsertPlaceholder(node: text, at: .end, field: ids[0])).value
        _ = await world.document.perform(InsertPlaceholder(node: text, at: .start, field: ids[2])).value
        let rect = await world.document.addRectangles([Rect(x: page.minX + 100, y: page.minY + 100, width: 20, height: 20)])[0].opID
        _ = await world.document.perform(BindToField([rect], field: ids[1], kind: .visibility)).value
        await world.paste("person\nAnnabelle Montgomery-Smythe\n")
        let model = MergeSheetModel(window: world.window, session: world.session)
        #expect(model.summary == "1 record on 1 page")
        #expect(model.warnings.contains { $0.contains("no column for") })
        _ = await world.document.perform(DeleteField(ids[1])).value
        await world.document.settle()
        #expect(model.warnings.contains("A bound object’s field is missing: it merges unbound."))
        // A block too small overflows even at the minimum size.
        model.shrinkToFit = true
        model.minimumSize = 30
        let fitted = model.fitted(world.session.records, indices: [0, 5])
        #expect(fitted.issues.contains { if case .overflow = $0.kind { true } else { false } })
        model.usesGrid = true
        world.window.selection.model.set(Selection([SelectionID(rect)]))
        #expect(try model.output().count == 1)
        model.usesGrid = false
        model.target = .printer
        model.runPrint = { _ in }
        await model.merge()
        #expect(model.message == "Sent 1 page to the printer.")
        let kinds: [MergeIssue.Kind] = [.overflow(node: text), .unfetchableImage(url: "u"), .unencodableBarcode(node: text), .unparsableDate(value: "d"),
                                        .unparsableNumber(value: "n"), .transformFailed(message: "m"), .transformTimeout, .missingField(name: "f"), .emptyField]
        #expect(Set(kinds.map { model.describe(MergeIssue(record: 1, kind: $0)) }).count == kinds.count)
        #expect(model.describe(MergeIssue(record: 4, kind: .emptyField)) == "Record 4: no value")
        // No records: the print view has no pages.
        let empty = try MergeOutput(state: world.document.state, records: RecordSet(model: DataModel(world.document.state), source: nil, raw: []), templates: [world.document.activePage.id])
        let view = MergePrintView(output: empty, textLayout: TextSceneLayout(engine: world.document.textEngine))
        var range = NSRange()
        #expect(view.knowsPageRange(&range) && range.length == 0 && view.rectForPage(1) == .zero)
    }

    @Test func thePanelsEdges() async throws {
        let world = DataWorld()
        defer { world.close() }
        let ids = await world.fields(["name", "city"])
        _ = await world.placeholderText("A ", field: ids[0])
        _ = await world.placeholderText("B ", field: ids[0], at: Point(x: 60, y: 200))
        await world.paste("name\tcity\nAnn\t\n")
        _ = await world.document.perform(EditSource(world.session.model.activeSource!.id, name: "")).value
        _ = await world.document.perform(SetMapping(world.session.model.activeSource!.id, field: ids[1], path: "$.town")).value
        await world.document.settle()
        let model = DataPanelModel(features: world.features, window: world.window, session: world.session)
        #expect(model.sourceTitle == "Untitled (Pasted table)" && model.sampleRows.rows == [["Ann", ""]] && model.showsMapping)
        Render.view(DataPanelBody(state: world.features.panel, features: world.features))
        _ = await world.document.perform(SetMapping(world.session.model.activeSource!.id, field: ids[1], path: "city")).value
        await world.document.settle()
        #expect(model.showsMapping, "a mapping entry keeps the table showing")
        var confirmed: [String] = []
        world.window.confirm = { message, detail in
            confirmed.append(detail)
            return false
        }
        model.deleteField(ids[0])
        #expect(confirmed.first?.hasPrefix("2 places use it") == true)
        // Every Options menu item runs.
        for item in world.setup.environment.panels.descriptor(for: "data")!.optionsMenu() {
            item.action()
            Self.endSheet(world)
        }
        try await Task.sleep(for: .milliseconds(50))
        Self.endSheet(world)
        // Connect > Web API edits the connected API source.
        var source = Wiretuner_Doc_V1_DataSource()
        source.spec.kind = .http
        source.spec.http.url = "https://api.example.com"
        source.spec.http.params = [.with { $0.name = "q"; $0.defaultValue = "x" }]
        _ = await world.document.perform(AddSource(source)).value
        await world.document.settle()
        let api = DataPanelModel(features: world.features, window: world.window, session: world.session)
        api.connect(.web)
        let sheet = try #require(world.window.window?.attachedSheet)
        let host = try #require(sheet.contentViewController as? NSHostingController<WebSourceSheet>)
        #expect(host.rootView.model.editing == api.source?.id && host.rootView.model.params.map(\.name) == ["q"])
        Self.endSheet(world)
        // The session's edges: a sample not on this Mac, a sample shown as such, no records to go to.
        var sample = Wiretuner_Doc_V1_EmbeddedRecords()
        sample.blobSha256 = Data(repeating: 1, count: 32)
        sample.mediaType = "text/csv"
        let apiSource = try #require(world.session.model.activeSource)
        _ = await world.document.perform(SetSample(apiSource.id, sample)).value
        await world.document.settle()
        await world.session.load()
        #expect(world.session.message == "The embedded sample is not on this Mac yet.")
        world.session.go(to: 3)
        await world.session.embed(all: false)
        world.transport.update { $0.pages = [[["name": "Zed"]]] }
        await world.session.refresh()
        #expect(await world.session.embed(all: false))
        await world.document.settle()
        world.session.services.client = { nil }
        await world.session.load()
        #expect(world.session.status == "1 record -- embedded sample")
        #expect(await world.session.scriptFetcher() == nil)
        // A session with no window writes through the document; team documents get no consent.
        let orphan = DataSession(document: world.document, services: world.features.services, blobs: world.features.blobs)
        await orphan.load()
        orphan.confirmEmbed = { _, _ in true }
        #expect(await orphan.embed(all: false))
        orphan.services.scope = { _ in DataScope(kind: .team(id: "t", name: "T"), canManage: false) }
        orphan.services.client = { world.client }
        #expect(await orphan.scriptFetcher() != nil)
        orphan.close()
    }

    @Test func theSheetsEdges() async throws {
        let world = DataWorld()
        defer { world.close() }
        let script = try #require(await world.document.perform(SaveScript(name: "", source: "export function transform(v) { return v; }")).value?.createdObjects.first)
        let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> = { world.document.perform($0) }
        let field = FieldSheetModel(document: world.document, field: nil, perform: perform)
        field.name = "total"
        field.kind = .number
        field.pattern = "0"
        Render.view(FieldSheet(model: field, close: {}))
        field.kind = .text
        #expect(field.commit())
        await world.document.settle()
        let total = try #require(DataModel(world.document.state).field(named: "total"))
        #expect(total.pattern == "", "a text field keeps no format")
        let edit = FieldSheetModel(document: world.document, field: total.id, perform: perform)
        edit.kind = .number
        edit.pattern = "0.0"
        edit.transform = script
        Render.view(FieldSheet(model: edit, close: {}))
        #expect(edit.commit())
        await world.document.settle()
        #expect(DataModel(world.document.state).field(total.id)?.pattern == "0.0")
        Render.view(ScriptSourceSheet(model: ScriptSourceModel(scripts: DocumentScript.list(world.document.state)), connect: {}, close: {}))
        // A file sheet on a file that is gone: the defaults, and an error.
        let missing = FileSourceModel(url: URL(filePath: "/no/such/list.tsv"), json: false)
        #expect(missing.delimiter == "\t" && missing.error != nil)
        let csv = FileSourceModel(url: URL(filePath: "/no/such/list.csv"), json: false)
        #expect(csv.delimiter == ",")
        let ragged = try DataFileReaderFixtures.file("ragged.csv", "a,b\n1\n")
        let raggedModel = FileSourceModel(url: ragged, json: false)
        Render.view(FileSourceSheet(model: raggedModel, connect: {}, close: {}))
        // The sheets' own buttons connect.
        let file = try DataFileReaderFixtures.file("list.csv", "name\nAnn\n")
        _ = world.features.presentFileSheet(file, json: false)
        let fileHost = try #require(world.window.window?.attachedSheet?.contentViewController as? NSHostingController<FileSourceSheet>)
        fileHost.rootView.connect()
        Self.endSheet(world)
        await world.document.settle()
        #expect(world.session.model.activeSource?.kind == .file)
        // Pasting while a file source is connected adds a pasted source.
        await world.paste("name\nBo\n")
        #expect(world.session.model.sources.count == 2 && world.session.model.activeSource?.kind == .pasted)
        _ = world.features.presentScriptSource()
        let scriptHost = try #require(world.window.window?.attachedSheet?.contentViewController as? NSHostingController<ScriptSourceSheet>)
        scriptHost.rootView.connect()
        Self.endSheet(world)
        await world.document.settle()
        #expect(world.session.model.activeSource?.kind == .script)
        // The Web sheet from an existing source: parameters, GET without a body, typed values.
        var source = Wiretuner_Doc_V1_DataSource()
        source.spec.kind = .http
        source.spec.http.url = "https://api.example.com"
        source.spec.http.params = [.with { $0.name = "q"; $0.defaultValue = "x" }]
        source.spec.http.credentialName = "gone"
        _ = await world.document.perform(AddSource(source)).value
        await world.document.settle()
        let web = WebSourceModel(session: world.session, source: world.session.model.activeSource)
        web.body = "ignored"
        web.timeout = 0
        world.session.params["q"] = ""
        #expect(web.http.bodyTemplate.isEmpty && web.request.source.timeoutS == 30 && web.request.params["q"] == "x" && web.request.hasSourceID)
        world.transport.update { $0.failure = DataServiceError.offline }
        await web.loadCredentials()
        #expect(web.credentials.isEmpty)
        Render.view(WebSourceSheet(model: web, close: {}))
        _ = world.session.model.fields
        web.params[0].value = "y"
        web.mapping[OpID(counter: 1, replica: 1)] = nil
        #expect(WebSourceSheet.mapping(OpID(counter: 5, replica: 5), web).wrappedValue == "")
        #expect(web.connect())
        await world.document.settle()
        #expect(world.session.model.activeSource?.spec.http.params.first?.defaultValue == "y")
        await web.test()
        Render.view(WebSourceSheet(model: web, close: {}))
    }

    @Test func theScriptsEdges() async throws {
        let world = DataWorld()
        defer { world.close() }
        let folder = ScriptsFolder(url: TestEnvironment.temporaryDirectory().appending(path: "Scripts"))
        let scripts = ScriptFeatures(folder: folder)
        scripts.reload()
        scripts.data = world.features
        let window = world.window
        scripts.install(commands: world.setup.environment.commands, watch: true) { [weak window] in window }
        let changed = MenuCounter()
        scripts.menuDidChange = { changed.count += 1 }
        try Data("1".utf8).write(to: folder.url.appending(path: "Watched.js"))
        for _ in 0..<150 where changed.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changed.count > 0 && world.setup.environment.commands.command(CommandID("script:Watched.js")) != nil)
        world.setup.environment.commands.perform(ScriptFeatures.ID.editor)
        world.setup.environment.commands.perform(ScriptFeatures.ID.editorFromScripts)
        scripts.editor?.close()
        // The menu follows the front window's document; nothing changes, nothing rebuilds.
        scripts.frontWindowChanged()
        scripts.frontWindowChanged()
        scripts.documentScriptsChanged()
        let other = SetupWindow()
        defer { other.close() }
        scripts.window = { other.window }
        scripts.frontWindowChanged()
        scripts.window = { [weak window] in window }
        scripts.frontWindowChanged()
        _ = await world.document.perform(SaveScript(name: "Doc", source: "1")).value
        await world.document.settle()
        let command = try #require(world.setup.environment.commands.commands.first { $0.id.rawValue.hasPrefix(ScriptFeatures.ID.documentPrefix) })
        scripts.window = { nil }
        #expect(command.validation() == .disabled(DataFeatures.noDocument))
        scripts.window = { [weak window] in window }
        // A script sets the selection; an error without a console shows the editor unless turned off.
        let rect = await world.document.addRectangles([Rect(x: 10, y: 10, width: 10, height: 10)])[0]
        let result = await scripts.run("wt.document.selection = wt.document.objects;", name: "Select all")
        for _ in 0..<100 where world.window.selection.model.selection.ids.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result?.error == nil && world.window.selection.model.selection.ids.contains(rect))
        world.setup.environment.preferences.set(false, for: PreferenceCatalog.Automation.scriptConsoleOnError)
        _ = await scripts.run("throw 1", name: "Quiet")
        #expect(scripts.editor?.window?.isVisible != true)
        scripts.data = nil
        _ = await scripts.run("throw 1", name: "Loud")
        scripts.editor?.close()
        // The editor's view branches: an error line, console levels, the chooser's entries.
        try FileManager.default.createDirectory(at: folder.url.appending(path: "Sub"), withIntermediateDirectories: true)
        try Data("2".utf8).write(to: folder.url.appending(path: "Sub/Inner.js"))
        _ = await world.document.perform(SaveScript(name: "", source: "3")).value
        await world.document.settle()
        let model = ScriptEditorModel(features: scripts)
        #expect(model.choices.contains { $0.title == "Sub › Inner" } && model.choices.contains { $0.title == "Document: Untitled script" })
        model.text = "console.error('bad');\nnope()"
        await model.run()
        let rendered = Render.view(ScriptEditorView(model: model), size: CGSize(width: 720, height: 560))
        let textView = try #require(Self.find(ScriptTextView.self, in: rendered))
        #expect(textView.completionSource?("wt.") .isEmpty == false)
        model.documentChanged()
        world.window.objectEditing.textSession = nil
        scripts.window = { nil }
        model.choose(.document(OpID(counter: 1, replica: 1)))
        let scriptID = try #require(DocumentScript.list(world.document.state).first?.id)
        scripts.window = { [weak window] in window }
        model.choose(.document(scriptID))
        scripts.window = { nil }
        #expect(!(await model.save()))
        _ = ScriptFeatures()
    }

    final class MenuCounter {
        var count = 0
    }

    @Test func theSmallEdges() async throws {
        #expect(ScriptSyntax.tokens(in: "'abc\nx").first.map { $0.range.length } == 4, "a quoted string ends at a line break")
        #expect(ScriptSyntax.tokens(in: "'a\\").first.map { $0.range.length } == 3, "an escape at the end stays inside the text")
        let ui = ScriptUI(window: nil, data: nil)
        ui.runAlert = { _, _ in .alertFirstButtonReturn }
        #expect(await ui.handle("alert", [42]) is NSNull)
        #expect(await ui.handle("choose", ["only a message"]) is NSNull)
        #expect(await ui.handle("progress", []) is NSNull && ui.progressSheet == nil)
        Render.view(ScriptProgressSheet(model: ScriptProgressModel()))
        // Barcode section defaults and a script source's fetched hosts.
        let world = DataWorld()
        defer { world.close() }
        let barcode = try #require(await world.document.perform(InsertBarcode("12345", symbology: .code128)).value?.createdObjects.first)
        await world.document.settle()
        let section = try #require(BarcodeSectionModel(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(barcode)]))))
        #expect(section.quietZone == 10 && section.field == nil)
        Render.view(BarcodeSectionView(model: section))
        let script = try #require(await world.document.perform(SaveScript(name: "Remote", source: """
        export async function records() { const r = await wt.fetch("https://Data.Example.com/x"); return [{ ok: String(r.status) }]; }
        """)).value?.createdObjects.first)
        var source = Wiretuner_Doc_V1_DataSource()
        source.spec.kind = .script
        source.spec.script.script.id = script.proto
        _ = await world.document.perform(AddSource(source)).value
        await world.document.settle()
        await world.session.refresh()
        #expect(world.session.scriptHosts == ["data.example.com"] || world.session.scriptHosts == ["Data.Example.com"])
        #expect(HostsModel.referenced(world.session).contains { $0.by == "Script" })
        // Kept for the source (DATA-015): another session on the document lists them before any run.
        let reopened = DataSession(document: world.document)
        reopened.hostStorage = world.session.hostStorage
        await reopened.load()
        #expect(reopened.scriptHosts == ["data.example.com"])
        reopened.close()
    }
}
