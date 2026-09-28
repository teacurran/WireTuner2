import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
@testable import WireTuner

/// The Features editor, the rename sheet's feature-file button (FONT-022) and opening or importing
/// UFO packages (FONT-024's app glue).
@Suite @MainActor struct TypefaceFeaturesEditorTests {
    /// A Basic Latin typeface with `f_i` (a ligature), `a.sc` and `b.sc`, and its Features editor.
    func editorFixture() async throws -> (TypefaceWindowFixture, FeaturesEditorController) {
        let fixture = await TypefaceWindowFixture.typeface()
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "f_i", kind: .ligature), NewGlyph(name: "a.sc"), NewGlyph(name: "b.sc")])).value
        #expect(fixture.environment.commands.perform(TypefaceFeatures.ID.featuresWindow))
        let editor = try #require(fixture.features.featureEditors[fixture.document.id])
        return (fixture, editor)
    }

    /// Types `string` at `offset` as the text view would ask for it, one keystroke at a time.
    func type(_ string: String, at offset: Int, in editor: FeaturesEditorController) async {
        var at = offset
        for scalar in string.unicodeScalars {
            _ = editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: at, length: 0), replacementString: String(scalar))
            await editor.model.document.settle()
            at += String(scalar).utf16.count
        }
    }

    func host(_ window: NSWindow?) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
    }

    @Test func typingChecksUnderlinesAndSelectsErrors() async throws {
        let (fixture, editor) = try await editorFixture()
        defer {
            editor.window?.close()
            fixture.close()
        }
        #expect(editor.window?.identifier?.rawValue == "typeface.features" && fixture.features.showFeatures() === editor)
        #expect(editor.model.summary == "No problems" && editor.textView.string.isEmpty)
        // A paste, then a rule typed inside the feature: it checks clean.
        #expect(!editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "feature liga {\n} liga;"))
        await fixture.document.settle()
        #expect(editor.textView.string == "feature liga {\n} liga;")
        await type("sub f i by f_i;\n", at: 15, in: editor)
        #expect(editor.textView.string == "feature liga {\nsub f i by f_i;\n} liga;")
        editor.check(nil)
        #expect(editor.model.report.isClean && editor.model.summary == "1 warning")
        #expect(editor.textView.selectedRange() == NSRange(location: 31, length: 0))
        // The colours reach the storage.
        let storage = try #require(editor.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == FeaturesEditorController.color(.keyword))
        #expect(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == FeaturesEditorController.color(.tag))
        // An unknown glyph is underlined by the live check, within its 300 ms.
        let started = ContinuousClock.now
        await type("sub q by qq;", at: 31, in: editor)
        let typed = ContinuousClock.now
        while editor.model.underlines().isEmpty, ContinuousClock.now - typed < .seconds(3) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let underline = try #require(editor.model.underlines().first)
        #expect(editor.model.checkedAt.map { $0 - typed < .seconds(1) } == true, "checked \(ContinuousClock.now - started) after typing began")
        #expect((editor.textView.string as NSString).substring(with: underline.range) == "qq" && underline.tooltip.contains("qq"))
        #expect(storage.attribute(.underlineStyle, at: underline.range.location, effectiveRange: nil) as? Int == NSUnderlineStyle.thick.rawValue)
        #expect(editor.model.summary.hasPrefix("1 error"))
        // Clicking the error in the strip selects its line.
        let row = try #require(editor.strip.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Error") })
        row.performClick(nil)
        #expect(editor.textView.selectedRange() == NSRange(location: 31, length: 19) && row.title.contains("line 3"))
        // Every edit is undoable, a word at a time.
        _ = await fixture.document.undo().value
        #expect(editor.textView.string.hasSuffix("sub q by } liga;"))
        host(editor.window)
        #expect(editor.lineNumbers.lineTops().map(\.line) == [1, 2, 3])
    }

    @Test func completionBracketsAndTheGeneratedPane() async throws {
        let (fixture, editor) = try await editorFixture()
        defer {
            editor.window?.close()
            fixture.close()
        }
        _ = editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "@caps = [A B];\nfeature liga {\nsub f_")
        await fixture.document.settle()
        // One name completes at once.
        let end = editor.textView.string.utf16.count
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.complete()
        await fixture.document.settle()
        #expect(editor.textView.string.hasSuffix("sub f_i"))
        // A class completes after its @.
        func append(_ string: String) async {
            _ = editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: editor.textView.string.utf16.count, length: 0),
                                replacementString: string)
            await fixture.document.settle()
            editor.textView.setSelectedRange(NSRange(location: editor.textView.string.utf16.count, length: 0))
        }
        await append(" by @")
        editor.complete()
        await fixture.document.settle()
        #expect(editor.textView.string.hasSuffix("by @caps"))
        // Several are offered; the chosen one replaces the partial name.
        var offered: [String] = []
        editor.showCompletions = { names, _ in offered = names }
        await append(" a")
        editor.complete()
        #expect(offered.count > 1 && offered.contains("a.sc"))
        let item = NSMenuItem(title: "a.sc", action: nil, keyEquivalent: "")
        item.representedObject = FeaturesEditorController.CompletionChoice(name: "a.sc", range: NSRange(location: editor.textView.string.utf16.count - 1, length: 1))
        editor.chooseCompletion(item)
        await fixture.document.settle()
        #expect(editor.textView.string.hasSuffix("by @caps a.sc"))
        editor.chooseCompletion(NSMenuItem())
        // Outside a rule nothing completes; Control-Space asks.
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        offered = []
        editor.complete()
        #expect(offered.isEmpty)
        let control = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
                                                     characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        editor.textView.keyDown(with: control)
        // The bracket before the caret lights its partner.
        _ = editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: editor.textView.string.utf16.count, length: 0), replacementString: ";\n}")
        await fixture.document.settle()
        editor.textView.setSelectedRange(NSRange(location: editor.textView.string.utf16.count, length: 0))
        let open = (editor.textView.string as NSString).range(of: "{")
        #expect(editor.highlightedBracket == open)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(editor.highlightedBracket == nil)
        // The Generated pane shows the automatic liga; the disclosure hides it.
        editor.check(nil)
        #expect(editor.generatedView.string.contains("sub f i by f_i;") && !editor.generatedScroll.isHidden)
        editor.disclosure.state = .off
        editor.toggleGenerated(nil)
        #expect(editor.generatedScroll.isHidden)
        host(editor.window)
    }

    @Test func insertClassFromSuffixAndCollaborators() async throws {
        let (fixture, editor) = try await editorFixture()
        defer {
            editor.window?.close()
            fixture.close()
        }
        let registry = fixture.environment.commands
        // No editor in front: stubbed, since the default reads the key window, and whether the
        // editor this test just opened became key depends on the tests before it.
        fixture.features.frontEditor = { nil }
        #expect(registry.command(TypefaceFeatures.ID.insertClassFromSuffix)?.validation().reason == TypefaceFeatures.noFeaturesEditor)
        fixture.features.frontEditor = { editor }
        #expect(registry.command(TypefaceFeatures.ID.insertClassFromSuffix)?.validation().isEnabled == true)
        #expect(registry.perform(TypefaceFeatures.ID.insertClassFromSuffix))
        let sheet = try #require(editor.window?.attachedSheet)
        #expect(sheet.identifier?.rawValue == "sheet.classFromSuffix")
        editor.window?.endSheet(sheet)
        editor.insertClassFromSuffix(nil)
        if let again = editor.window?.attachedSheet { editor.window?.endSheet(again) }
        let model = ClassFromSuffixModel { editor.model.insertClasses(suffix: $0) }
        model.suffix = ".zz"
        #expect(!model.commit() && model.problem?.contains(".zz") == true)
        model.suffix = ".sc"
        #expect(model.commit())
        await fixture.document.settle()
        #expect(editor.textView.string == "@sc_from = [a b];\n@sc_to = [a.sc b.sc];\n")
        let hosting = NSHostingView(rootView: ClassFromSuffixSheet(model: model, close: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        hosting.layoutSubtreeIfNeeded()

        // A collaborator's caret shows; this person's caret is published as the selection moves.
        let text = FeatureFileText(fixture.document.state)
        let presence = StubPresenceModel(participants: [
            RemoteParticipant(id: "p", name: "Priya", colorIndex: 1,
                              caret: RemoteCaret(node: SelectionID(WellKnown.settings), position: text.chars[3], text: FontFields.features)),
            RemoteParticipant(id: "t", name: "Tom", colorIndex: 2, caret: RemoteCaret(node: SelectionID(WellKnown.settings), position: text.chars[1],
                                                                                        rangeEnd: text.chars[5], text: FontFields.features)),
            RemoteParticipant(id: "q", name: "Quinn", colorIndex: 3, caret: RemoteCaret(node: SelectionID(WellKnown.settings), position: .zero)),
        ])
        var published: [PresenceCaret?] = []
        let second = FeaturesEditorController(model: FeaturesEditorModel(document: fixture.document), showGenerated: false, presence: presence) {
            published.append($0)
        }
        #expect(second.remoteMarks.count == 2 && second.remoteMarks.contains { $0.isCaret && $0.name == "Priya" })
        #expect(second.generatedScroll.isHidden)
        second.textView.setSelectedRange(NSRange(location: 2, length: 3))
        let caret = try #require(published.last ?? nil)
        #expect(caret.node == WellKnown.settings && caret.text == FontFields.features && caret.position == text.chars[5] && caret.rangeEnd == text.chars[2])
        // A collaborator typing elsewhere converges, and the selection stays on its characters.
        var remote = DocumentCore(state: fixture.document.state, replica: 0xBEEF)
        let typed = try #require(try remote.perform(FeatureFileText(remote.state).edit(replacing: 0..<0, with: "# top\n"),
                                                     recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        _ = await fixture.document.receive(typed).value
        await fixture.document.settle()
        #expect(second.textView.string.hasPrefix("# top\n@sc_from") && editor.textView.string == second.textView.string)
        #expect(second.textView.selectedRange() == NSRange(location: 8, length: 3))
        presence.participants = []
        #expect(second.remoteMarks.isEmpty)
        second.window?.close()
        #expect(published.last == .some(nil))
        // Closing forgets the editor.
        editor.window?.close()
        #expect(fixture.features.featureEditors.isEmpty)
    }

    @Test func theRenameSheetRenamesInTheFeatureFile() async throws {
        let (fixture, editor) = try await editorFixture()
        defer {
            editor.window?.close()
            fixture.close()
        }
        editor.model.insert("feature ss01 { sub a by a.sc; } ss01;")
        await fixture.document.settle()
        let a = fixture.glyph("a")
        let model = RenameGlyphModel(document: fixture.document, glyph: a, perform: { fixture.window.typefacePerform($0) })
        #expect(model.oldName == "a" && model.usesNotice == "Used in the feature file, 1 place.")
        let hosting = NSHostingView(rootView: RenameGlyphSheet(model: model, close: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        hosting.layoutSubtreeIfNeeded()
        model.name = "a b"
        #expect(!model.renameOnly() && model.problem?.contains("not a valid") == true)
        model.name = "b"
        #expect(!model.renameEverywhere() && model.problem?.contains("Another glyph") == true)
        model.name = "a"
        #expect(model.renameOnly())
        model.name = "alpha"
        #expect(model.renameEverywhere())
        await fixture.document.settle()
        #expect(GlyphIndex(fixture.document.state).glyph(named: "alpha") != nil && editor.textView.string == "feature ss01 { sub alpha by a.sc; } ss01;")
        // A glyph the file does not use: plain Rename.
        let unused = RenameGlyphModel(document: fixture.document, glyph: fixture.glyph("c"), perform: { fixture.window.typefacePerform($0) })
        #expect(unused.usesNotice == nil)
        let plain = NSHostingView(rootView: RenameGlyphSheet(model: unused, close: {}))
        plain.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        plain.layoutSubtreeIfNeeded()
        unused.name = "cee"
        #expect(unused.renameOnly())
        await fixture.document.settle()
        #expect(GlyphIndex(fixture.document.state).glyph(named: "cee") != nil)
        // From the Glyph menu, on the selected glyph.
        let registry = fixture.environment.commands
        #expect(!(registry.command(TypefaceFeatures.ID.renameGlyph)?.validation().isEnabled ?? true))
        fixture.mode.grid?.model.select([fixture.glyph("d")])
        #expect(registry.perform(TypefaceFeatures.ID.renameGlyph))
        #expect(fixture.window.window?.attachedSheet?.identifier?.rawValue == "sheet.renameGlyph")
        if let sheet = fixture.window.window?.attachedSheet { fixture.window.window?.endSheet(sheet) }
        fixture.front = nil
        #expect(fixture.features.presentRenameGlyph() == nil && fixture.features.showFeatures() == nil)
        #expect(!(registry.command(TypefaceFeatures.ID.featuresWindow)?.validation().isEnabled ?? true))
    }

    @Test func ufoPackagesOpenAndImport() async throws {
        let source = await TypefaceWindowFixture.typeface()
        defer { source.close() }
        let a = try #require(GlyphCanvas.handle(for: source.glyph("A"), of: source.document))
        _ = await source.box(50, -600, 400, 600, on: a)
        _ = await source.document.perform(SetKernPair(source.glyph("A"), source.glyph("V"), to: -80)).value
        _ = await source.document.perform(FeatureFileText(source.document.state).edit(replacing: 0..<0, with: "feature ss01 { sub A by V; } ss01;\n")).value
        let folder = FileManager.default.temporaryDirectory.appending(path: "WireTunerUFOOpen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ufo = folder.appending(path: "Marlowe.ufo")
        _ = try UFOExport.write(source.document.state, to: ufo, options: UFOExportOptions())
        let junk = folder.appending(path: "junk.ufo")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        #expect(FontImportController.isUFO(ufo) && !FontImportController.isUFO(folder.appending(path: "x.otf")))

        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        var created: [DocumentHandle] = []
        fixture.features.createDocument = { title in
            let handle = DocumentHandle.memory(title: title)
            created.append(handle)
            return handle
        }
        var alerts: [(String, String)] = []
        fixture.features.alert = { message, detail, _ in alerts.append((message, detail)) }
        // Opened (from Open Font… or the Finder): a new typeface document with the package's contents.
        fixture.features.chooseFontFile = { _ in ufo }
        let report = try #require(await fixture.features.openFontFile().value)
        let opened = try #require(created.first)
        #expect(created.first?.title == "Marlowe" && DocumentKind(opened.state) == .typeface)
        #expect(GlyphIndex(opened.state).glyph(named: "A") != nil && FeatureFileText(opened.state).string.contains("sub A by V;"))
        #expect(alerts.isEmpty == report.isEmpty)
        #expect(!fixture.features.opens(folder.appending(path: "x.otf")))
        #expect(fixture.features.opens(ufo))
        for _ in 0..<200 where created.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(created.count == 2)
        // Imported into the front typeface: collisions follow the grid's rules; the feature file stays.
        _ = await fixture.document.perform(NewTypeface(family: "Front", style: "Regular", set: nil)).value
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(scalar: 0x41)])).value
        fixture.features.chooseUFO = { _ in ufo }
        #expect(fixture.environment.commands.command(TypefaceFeatures.ID.importUFO)?.validation().isEnabled == true)
        let imported = try #require(await fixture.features.importUFOIntoTypeface().value)
        #expect(GlyphIndex(fixture.document.state).glyph(named: "V") != nil && created.count == 2)
        #expect(imported.contains { $0.contains("feature file") } && FeatureFileText(fixture.document.state).string.isEmpty)
        // A folder that is not a UFO says so; cancelling does nothing; a non-typeface does nothing.
        fixture.features.chooseUFO = { _ in junk }
        #expect(await fixture.features.importUFOIntoTypeface().value == nil && alerts.last?.0.contains("could not be opened") == true)
        #expect(alerts.last?.1.contains("metainfo") == true)
        fixture.features.chooseUFO = { _ in nil }
        #expect(await fixture.features.importUFOIntoTypeface().value == nil)
        let illustration = TypefaceWindowFixture()
        defer { illustration.close() }
        #expect(await illustration.features.importUFOIntoTypeface().value == nil)
        // No document can be made: nothing happens.
        fixture.features.createDocument = { _ in nil }
        #expect(await fixture.features.openUFO(ufo).value == nil)
        let failure = await FontImportController(document: fixture.document).importUFO(folder.appending(path: "none.ufo"), newDocument: false)
        if case .success = failure { Issue.record("a missing package read") }
    }
}
