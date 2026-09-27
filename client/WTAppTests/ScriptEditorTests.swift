import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// DATA-013 and DATA-014: the Script Editor (run and stop, errors with line and column, Save and
/// Save to Document, *Reload* on a remote save, completion from the typings), the Scripts menu from
/// the watched folder and the front document, `wt.ui` on a window, and the typings installed in
/// the Scripts folder.
@Suite(.serialized) @MainActor struct ScriptEditorTests {
    static func folder() throws -> ScriptsFolder {
        let url = TestEnvironment.temporaryDirectory().appending(path: "Scripts")
        return ScriptsFolder(url: url)
    }

    @MainActor
    struct World {
        let data = DataWorld()
        let scripts: ScriptFeatures
        var menuChanges = 0

        init() throws {
            scripts = ScriptFeatures(folder: try ScriptEditorTests.folder())
            scripts.data = data.features
            let window = data.window
            scripts.install(commands: data.setup.environment.commands, watch: false) { [weak window] in window }
        }

        var registry: CommandRegistry { data.setup.environment.commands }
        func close() { data.close() }
    }

    // MARK: Folder

    @Test func theScriptsFolderGetsTheTypingsAndListsScriptsWithSubfolders() throws {
        let folder = try Self.folder()
        #expect(try folder.installTypings())
        #expect(try !folder.installTypings(), "unchanged typings are not written again")
        #expect(try String(contentsOf: folder.url.appending(path: ScriptTypings.fileName), encoding: .utf8) == ScriptTypings.declarations)
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: ScriptsFolder.readmeName).path))
        try Data("x".utf8).write(to: folder.url.appending(path: ScriptTypings.fileName))
        #expect(try folder.installTypings(), "an outdated copy is replaced")
        try FileManager.default.createDirectory(at: folder.url.appending(path: "Labels"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: folder.url.appending(path: "Number.js"))
        try Data("2".utf8).write(to: folder.url.appending(path: "Labels/Badges.JS"))
        try Data("3".utf8).write(to: folder.url.appending(path: "notes.txt"))
        let entries = folder.entries()
        #expect(entries.map(\.title) == ["Badges", "Number"] && entries[0].folders == ["Labels"] && entries[1].folders.isEmpty)
        #expect(entries[0].commandID == CommandID("script:Labels/Badges.JS"))
        #expect(ScriptsFolder(url: URL(filePath: "/no/such/folder")).entries().isEmpty)
        #expect(try ScriptsFolder.defaultURL().path.hasSuffix("WireTuner/Scripts"))
    }

    @Test func theWatcherReportsChangesInTheFolder() async throws {
        let folder = try Self.folder()
        try folder.installTypings()
        var changes = 0
        let watcher = try #require(FolderWatcher(url: folder.url, latency: 0.05) { changes += 1 })
        try Data("1".utf8).write(to: folder.url.appending(path: "New.js"))
        for _ in 0..<100 where changes == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes > 0)
        watcher.stop()
        watcher.stop()
    }

    // MARK: Menu

    @Test func theScriptsMenuListsFolderAndDocumentScriptsAndRunsThem() async throws {
        var world = try World()
        defer { world.close() }
        let counter = MenuChanges()
        world.scripts.menuDidChange = { counter.count += 1 }
        #expect(world.registry.command(ScriptFeatures.ID.editor)?.menuPath?.components == ["Window"])
        #expect(world.registry.command(ScriptFeatures.ID.openFolder)?.menuPath?.components == ["Scripts"])
        var revealed: [URL] = []
        world.scripts.reveal = { revealed.append($0) }
        world.registry.perform(ScriptFeatures.ID.openFolder)
        #expect(revealed == [world.scripts.folder.url])
        // A file added shows after Reload; a subfolder becomes a submenu.
        try FileManager.default.createDirectory(at: world.scripts.folder.url.appending(path: "Tools"), withIntermediateDirectories: true)
        try Data("wt.document.createRectangle({ x: 10, y: 10 });".utf8).write(to: world.scripts.folder.url.appending(path: "Tools/Box.js"))
        world.registry.perform(ScriptFeatures.ID.reload)
        #expect(counter.count == 1)
        let box = CommandID("script:Tools/Box.js")
        #expect(world.registry.command(box)?.menuPath?.components == ["Scripts", "Tools"] && world.registry.command(box)?.title == "Box")
        // Nothing ran on its own.
        #expect(world.scripts.runs == 0)
        world.registry.perform(box)
        for _ in 0..<200 where world.scripts.runs == 0 || world.data.document.changeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await world.data.document.settle()
        #expect(world.scripts.runs == 1)
        // A document script appears under Document Scripts when the front window changes or it is saved.
        let saved = try #require(await world.data.document.perform(SaveScript(name: "Stamp", source: "console.log('hi')")).value?.createdObjects.first)
        world.scripts.frontWindowChanged()
        let id = CommandID(ScriptFeatures.ID.documentPrefix + "\(saved.counter)-\(saved.replica)")
        #expect(world.registry.command(id)?.menuPath?.components == ["Scripts", "Document Scripts"] && world.registry.command(id)?.title == "Stamp")
        #expect(world.registry.command(id)?.validation() == .enabled)
        world.scripts.frontWindowChanged()
        _ = await world.data.document.perform(SaveScript(name: "", source: "x")).value
        await world.data.document.settle()
        #expect(world.registry.commands.contains { $0.title == "Untitled script" })
        world.registry.perform(id)
        for _ in 0..<200 where world.scripts.runs < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.scripts.runs == 2)
        // A script deleted leaves the menu.
        _ = await world.data.document.perform(DeleteScript(saved)).value
        await world.data.document.settle()
        #expect(world.registry.command(id) == nil)
        world.scripts.runDocumentScript(saved)
        world.scripts.runFile(URL(filePath: "/no/such.js"))
        // Without a window: nothing runs, nothing is listed.
        world.scripts.window = { nil }
        #expect(await world.scripts.run("1", name: "x") == nil)
        world.scripts.documentScriptsChanged()
        world.menuChanges = counter.count
        let editor = world.scripts.showEditor()
        #expect(editor.window?.title == "Script Editor" && world.scripts.showEditor() === editor)
        editor.close()
    }

    final class MenuChanges {
        var count = 0
    }

    @Test func aRunReachesTheDocumentTheRecordsAndTheConsole() async throws {
        let world = try World()
        defer { world.close() }
        _ = await world.data.fields(["name"])
        await world.data.paste("name\nAnn\nBo\n")
        var lines: [ScriptConsoleEntry] = []
        let result = await world.scripts.run("console.log(wt.records.all().length); wt.document.createRectangle({ x: 1, y: 2 });", name: "Count") { lines.append($0) }
        await world.data.document.settle()
        #expect(result?.error == nil && result?.changes == 1)
        for _ in 0..<100 where lines.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(lines.map(\.text) == ["2"] && world.data.document.undoTitle.hasPrefix("Undo Script"))
        // An error brings the editor forward (Show script console on error).
        let failed = await world.scripts.run("throw new Error('boom')", name: "Bad")
        #expect(failed?.error != nil && world.scripts.editor?.window?.isVisible == true)
        world.scripts.editor?.close()
    }

    // MARK: wt.ui

    @Test func wtUIShowsAlertsPanelsAndTheProgressSheet() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let ui = ScriptUI(window: setup.window, data: nil)
        var responses: [NSApplication.ModalResponse] = [.alertFirstButtonReturn]
        var alerts: [NSAlert] = []
        ui.runAlert = { alert, _ in
            alerts.append(alert)
            if let field = alert.accessoryView as? NSTextField { field.stringValue = "typed" }
            if let popUp = alert.accessoryView as? NSPopUpButton { popUp.selectItem(at: 1) }
            return responses.isEmpty ? .alertSecondButtonReturn : responses.removeFirst()
        }
        #expect(await ui.handle("alert", ["Hello"]) is NSNull && alerts.last?.messageText == "Hello")
        responses = [.alertFirstButtonReturn]
        #expect(await ui.handle("confirm", ["Sure?"]) as? Bool == true)
        #expect(await ui.handle("confirm", ["Sure?"]) as? Bool == false)
        responses = [.alertFirstButtonReturn]
        #expect(await ui.handle("prompt", ["Name?", "Ann"]) as? String == "typed")
        #expect(await ui.handle("prompt", ["Name?"]) is NSNull)
        responses = [.alertFirstButtonReturn]
        #expect(await ui.handle("choose", ["Pick", ["A", "B"]]) as? String == "B")
        #expect(await ui.handle("choose", ["Pick", 3]) is NSNull)
        // Files: contents in, a writer token out -- never a path.
        let file = try DataFileReaderFixtures.file("in.txt", "contents")
        ui.chooseOpen = { panel, _ in
            #expect(panel.allowedContentTypes.map(\.preferredFilenameExtension) == ["txt"])
            return file
        }
        #expect(await ui.handle("openFile", [["types": ["txt"]]]) as? String == "contents")
        ui.chooseOpen = { _, _ in nil }
        #expect(await ui.handle("openFile", []) is NSNull)
        let out = file.deletingLastPathComponent().appending(path: "out.txt")
        ui.chooseSave = { panel, _ in
            #expect(panel.nameFieldStringValue == "report.txt")
            return out
        }
        let token = try #require(await ui.handle("saveFile", [["suggestedName": "report.txt"]]) as? String)
        #expect(!token.contains("/"))
        #expect(await ui.handle("write", [token, "written"]) is NSNull)
        #expect(try String(contentsOf: out, encoding: .utf8) == "written")
        #expect(await ui.handle("write", ["unknown", "x"]) is NSNull)
        ui.chooseSave = { _, _ in nil }
        #expect(await ui.handle("saveFile", []) is NSNull)
        // Progress: the sheet, its updates and Cancel.
        #expect(await ui.handle("progress", ["Working"]) is NSNull)
        #expect(ui.progressSheet != nil && setup.window.window?.attachedSheet?.identifier?.rawValue == "sheet.scriptProgress")
        ui.update(0.5, "half")
        #expect(ui.progress.fraction == 0.5 && ui.progress.text == "half")
        Render.view(ScriptProgressSheet(model: ui.progress))
        var cancelled = false
        ui.onCancel = { cancelled = true }
        ui.progress.cancel()
        #expect(cancelled)
        #expect(await ui.handle("progressDone", []) is NSNull && ui.progressSheet == nil)
        #expect(await ui.handle("nothing", []) == nil)
        // The host blocks the script's thread while the main actor answers.
        let host = WindowScriptHost(ui: ui)
        ui.runAlert = { _, _ in .alertFirstButtonReturn }
        let answer = await Task.detached { (try? host.ui("confirm", ["?"])) as? Bool }.value
        #expect(answer == true)
        let nothing = await Task.detached { (try? host.ui("alert", ["x"])).map { _ in "present" } ?? "absent" }.value
        #expect(nothing == "absent")
        let unknown = await Task.detached { () -> String in
            do { _ = try host.ui("bogus", []); return "" } catch { return String(describing: error) }
        }.value
        #expect(unknown == "wt.ui.bogus is not available")
        #expect(await Task.detached { host.progress(0.2, "a") }.value)
        ui.progress.cancel()
        #expect(await Task.detached { host.progress(0.3, "b") }.value == false)
    }

    // MARK: Editor

    @Test func theEditorRunsSavesAndReloads() async throws {
        let world = try World()
        defer { world.close() }
        let model = ScriptEditorModel(features: world.scripts)
        #expect(model.choices.map(\.title) == ["Untitled"] && model.choice == .untitled)
        // Run: output in the console; an error with its line and column.
        model.text = "console.log('one');\nconsole.warn('two');\nnope();"
        await model.run()
        #expect(model.console.map(\.level).contains(.log) && model.errorLocation?.line == 3 && !model.isRunning)
        #expect(model.console.map(ScriptEditorModel.line).contains { $0.hasPrefix("⚠︎") })
        #expect(ScriptEditorModel.line(ScriptConsoleEntry(.request, "GET")) == "→ GET" && ScriptEditorModel.line(ScriptConsoleEntry(.table, "t")) == "t")
        model.clearConsole()
        model.stop()
        // Save to Document, then Save writes the document script; a remote save shows Reload.
        model.name = "Namer"
        model.text = "console.log(1)"
        #expect(await model.saveToDocument())
        guard case .document(let id) = model.choice else { throw CancellationError() }
        #expect(model.choices.map(\.title).contains("Document: Namer"))
        model.text = "console.log(2)"
        #expect(await model.save())
        #expect(DocumentScript.script(id, in: world.data.document.state)?.source == "console.log(2)")
        model.text = "console.log(3) // local edit"
        _ = await world.data.document.receiveRemote(SaveScript(id, name: "Namer", source: "console.log('theirs')"))
        model.documentChanged()
        #expect(model.reloadNotice && model.text == "console.log(3) // local edit")
        model.reload()
        #expect(!model.reloadNotice && model.text == "console.log('theirs')")
        _ = await world.data.document.receiveRemote(SaveScript(id, name: "Namer", source: "console.log('theirs')"))
        model.documentChanged()
        // Files: open, save; an untitled script saves into the folder.
        try world.scripts.folder.installTypings()
        let url = world.scripts.folder.url.appending(path: "Hello.js")
        try Data("console.log('file')".utf8).write(to: url)
        #expect(model.choices.contains { $0.choice == .file(url) })
        model.choose(.file(url))
        #expect(model.text == "console.log('file')" && model.name == "Hello")
        model.text = "console.log('edited')"
        #expect(await model.save())
        #expect(try String(contentsOf: url, encoding: .utf8) == "console.log('edited')")
        model.choose(.untitled)
        #expect(model.text == ScriptEditorModel.untitledSource)
        model.chooseSaveURL = { name, folder in folder.appending(path: name + ".js") }
        #expect(await model.save())
        #expect(model.choice == .file(world.scripts.folder.url.appending(path: "Untitled.js")))
        model.choose(.untitled)
        model.chooseSaveURL = { _, _ in nil }
        #expect(!(await model.save()))
        model.chooseSaveURL = { _, _ in URL(filePath: "/no/such/folder/x.js") }
        #expect(!(await model.save()))
        model.choose(.file(URL(filePath: "/no/such/folder/y.js")))
        #expect(!(await model.save()))
        model.choose(.document(OpID(counter: 999, replica: 9)))
        // Completion from the typings.
        #expect(model.completions(before: "wt.document.cre").map(\.name).contains("createRectangle"))
        // Without a window: nothing to run on, nowhere to save.
        world.scripts.window = { nil }
        let orphan = ScriptEditorModel(features: world.scripts)
        orphan.choose(.document(id))
        await orphan.run()
        #expect(orphan.console.last?.text == "No document is open.")
        #expect(!(await orphan.saveToDocument()))
        let detached = ScriptEditorModel(features: nil)
        await detached.run()
        #expect(!(await detached.save()))
    }

    @Test func theEditorWindowColorsTheBufferAndMarksTheErrorLine() async throws {
        let world = try World()
        defer { world.close() }
        let model = ScriptEditorModel(features: world.scripts)
        let controller = ScriptEditorController(model: model)
        defer { controller.close() }
        Render.view(ScriptEditorView(model: model), size: CGSize(width: 720, height: 560))
        ScriptEditorView.choose(model).wrappedValue = .untitled
        #expect(ScriptEditorView.choose(model).wrappedValue == .untitled)
        model.text = "throw 1"
        model.chooseSaveURL = { _, _ in nil }
        ScriptEditorView.run(model)()
        ScriptEditorView.save(model)()
        ScriptEditorView.saveToDocument(model)()
        for _ in 0..<200 where model.isRunning || model.errorLocation == nil { try await Task.sleep(for: .milliseconds(10)) }
        Render.view(ScriptEditorView(model: model), size: CGSize(width: 720, height: 560))
        // The text view: coloring on change, the error line marked, completion.
        let editor = ScriptTextEditor(model: model)
        let coordinator = editor.makeCoordinator()
        let scroll = NSScrollView()
        let textView = ScriptTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.documentView = textView
        coordinator.textView = textView
        textView.delegate = coordinator
        editor.update(textView)
        #expect(textView.string == model.text)
        textView.string = "const a = 1; // note"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(model.text == "const a = 1; // note")
        textView.completionSource = { prefix in model.completions(before: prefix).map(\.name) }
        textView.string = "wt.ui.al"
        var index = 0
        #expect(textView.completions(forPartialWordRange: NSRange(location: 6, length: 2), indexOfSelectedItem: &index) == ["alert"])
        textView.completionSource = nil
        #expect(textView.completions(forPartialWordRange: NSRange(location: 6, length: 2), indexOfSelectedItem: &index) == [])
        let lone = ScriptTextEditor.Coordinator(model: model)
        lone.textDidChange(Notification(name: NSText.didChangeNotification))
        Render.view(ScriptEditorView(model: model), size: CGSize(width: 720, height: 560))
    }

    // MARK: Syntax and completion

    @Test func syntaxColoringFindsCommentsStringsNumbersAndKeywords() {
        let text = "const x = 12.5; // note\nlet s = \"a\\\"b\" + 'c' + `t\n`; /* block */ return x2;\n\"open"
        let tokens = ScriptSyntax.tokens(in: text).map { ((text as NSString).substring(with: $0.range), $0.token) }
        #expect(tokens.contains { $0 == ("const", .keyword) } && tokens.contains { $0 == ("12.5", .number) } && tokens.contains { $0 == ("// note", .comment) })
        #expect(tokens.contains { $0 == ("\"a\\\"b\"", .string) } && tokens.contains { $0 == ("'c'", .string) } && tokens.contains { $0 == ("`t\n`", .string) })
        #expect(tokens.contains { $0 == ("/* block */", .comment) } && tokens.contains { $0 == ("return", .keyword) } && !tokens.contains { $0.0 == "x2" })
        #expect(tokens.last?.1 == .string, "an unclosed string runs to the end of its line")
        #expect(ScriptSyntax.tokens(in: "/* open").first?.token == .comment)
        let storage = NSTextStorage(string: text)
        ScriptSyntax.highlight(storage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == ScriptSyntax.color(.keyword))
        #expect([ScriptSyntax.Token.comment, .string, .number].map(ScriptSyntax.color).count == 3)
        #expect(ScriptSyntax.range(ofLine: 2, in: "a\nbc\nd") == NSRange(location: 2, length: 3))
        #expect(ScriptSyntax.range(ofLine: 1, in: "a") == NSRange(location: 0, length: 1))
        #expect(ScriptSyntax.range(ofLine: 5, in: "a\nb") == nil && ScriptSyntax.range(ofLine: 0, in: "a") == nil)
    }

    @Test func completionReadsTheTypings() {
        let completions = ScriptCompletions()
        let top = completions.members(after: "wt").map(\.name)
        #expect(["document", "documents", "fetch", "ui", "records"].allSatisfy(top.contains))
        #expect(completions.members(after: "wt.document").map(\.name).contains("transaction"))
        #expect(completions.members(after: "wt.document").first { $0.name == "transaction" }?.doc.contains("undo step") == true)
        #expect(completions.members(after: "wt.ui").map(\.name).contains("progress"))
        #expect(completions.members(after: "block").map(\.name).contains("bringToFront"), "anything else reads as an object")
        #expect(completions.members(after: "Rect").map(\.name) == ["x", "y", "width", "height"])
        #expect(completions.completions(before: "  w").map(\.name) == ["wt"] && completions.completions(before: "").isEmpty)
        #expect(completions.completions(before: "wt.records.").map(\.name).contains("merge"))
        #expect(completions.completions(before: "x = wt.fe").map(\.name) == ["fetch"])
    }

    // MARK: The app

    @Test func theAppInstallsTheDataMergeAndScriptsMenus() async throws {
        let suite = TestDefaults()
        let delegate = launchedDelegate(suite)
        defer { closeAll(delegate) }
        #expect(delegate.commands.command(DataFeatures.ID.merge) != nil && delegate.commands.command(ScriptFeatures.ID.reload) != nil)
        #expect(delegate.panels.descriptor(for: "data") != nil)
        #expect(FileManager.default.fileExists(atPath: delegate.scripts.folder.url.appending(path: ScriptTypings.fileName).path))
        #expect(!delegate.scripts.folder.url.path.contains("Application Support"), "a test launch keeps its own folder")
        delegate.scripts.menuDidChange()
        #expect(delegate.dataMerge.services.client() == nil && delegate.dataMerge.services.accountID() == nil)
        #expect(await delegate.dataMerge.services.scope(DocumentHandle.memory(title: "Scope")) == nil)
        delegate.dataMerge.showPanel("data")
        #expect(delegate.commands.menuTitles.contains("Scripts"))
    }
}
