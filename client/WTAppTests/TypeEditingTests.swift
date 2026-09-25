import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document window with the Text and Pointer tools, for the type-editing UI tasks (TYPE-011,
/// TYPE-013, TYPE-014, TYPE-016, TYPE-019).
@MainActor
struct TypeWorld {
    let setup = SetupWindow(tools: [PointerTool.descriptor, TextTool.descriptor])

    init() {
        TextEditorFeatures.shared.showsWindows = false
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var state: EngineState { document.state }

    /// A block holding `text`, selected.
    func block(_ text: String, at point: Point = Point(x: 50, y: 50)) async throws -> OpID {
        let node = try #require(await document.addText(text, at: point))
        window.selection.model.set(Selection([SelectionID(node)]))
        return node
    }

    /// Editing `node` with the Text tool, `range` selected.
    func edit(_ node: OpID, select range: Range<Int>) async {
        window.editText(node, at: .zero)
        window.objectEditing.textSession?.select(anchor: range.lowerBound, focus: range.upperBound)
        await settle()
    }

    var session: TextEditingSession? { window.objectEditing.textSession }

    func settle() async {
        await session?.settle()
        await document.settle()
        await session?.settle()
        await document.settle()
    }

    func close() {
        TextEditorFeatures.shared.closeAll(of: document)
        setup.close()
    }
}

@Suite(.serialized) @MainActor struct TypeEditingTests {
    // MARK: Text Editor (TYPE-011, TYPE-016)

    @Test func theEditorTypesLiveAndKeepsItsSelectionThroughRemoteEdits() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("hello world")
        #expect(await TextEditorFeatures.shared.open(node, in: world.window).value == node)
        let controller = try #require(TextEditorFeatures.shared.controller(for: node, in: world.document))
        #expect(TextEditorFeatures.shared.controller(for: node, in: world.document) === controller)
        #expect(controller.textView.string == "hello world" && controller.model.title.hasPrefix("Text Editor"))
        // Typing in the editor: an ordinary text command.
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        controller.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        #expect(!controller.textView(controller.textView, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementString: ","))
        await controller.model.session.settle()
        await world.document.settle()
        #expect(world.document.string(node) == "hello, world" && controller.textView.string == "hello, world")
        #expect(controller.textView.selectedRange() == NSRange(location: 6, length: 0))
        // A remote insert before the caret moves the text, not the caret off its character.
        let text = try #require(world.state.textNode(node))
        await world.document.receiveRemote(InsertText(node: node, text: ">> ", at: text.anchor(at: 0)))
        #expect(controller.textView.string == ">> hello, world")
        #expect(controller.textView.selectedRange() == NSRange(location: 9, length: 0))
        // Deleting a selection, a paste with line ends, and a refused change while reloading.
        #expect(!controller.textView(controller.textView, shouldChangeTextIn: NSRange(location: 0, length: 3), replacementString: ""))
        await world.settle()
        await controller.model.session.settle()
        #expect(world.document.string(node) == "hello, world")
        controller.model.replace(NSRange(location: 12, length: 0), with: "\r\nmore")
        await controller.model.session.settle()
        #expect(world.document.string(node) == "hello, world\nmore")
        #expect(!controller.textView(controller.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: nil))
        controller.model.replace(NSRange(location: 0, length: 0), with: "")
        // Opening it again brings the same window.
        #expect(TextEditorFeatures.shared.show(node, in: world.window) === controller)
        // A remote delete of the block closes the editor.
        await world.document.receiveRemote(DeleteNodes([node]))
        #expect(TextEditorFeatures.shared.controller(for: node, in: world.document) == nil)
    }

    @Test func twelvePointBlackInvisiblesAndWrapChangeOnlyTheWindow() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Big\tred\u{FFFC}")
        let size = TextFixtureMarks.mark { $0.size = 48 }
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: size)).value
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.fontFamily = "Helvetica" })).value
        let controller = TextEditorFeatures.shared.show(node, in: world.window)
        let hash = world.state.stateHash
        let font = { controller.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont }
        #expect(font()?.pointSize == 12)
        #expect(controller.textView.textStorage?.attribute(.attachment, at: 7, effectiveRange: nil) != nil, "the inline graphic's box")
        controller.twelvePointBox.state = .off
        controller.toggleTwelvePoint(controller.twelvePointBox)
        #expect(font()?.pointSize == 48)
        controller.invisiblesBox.state = .on
        controller.toggleInvisibles(controller.invisiblesBox)
        #expect(controller.textView.layoutManager?.showsInvisibleCharacters == true)
        controller.wrapBox.state = .off
        controller.toggleWrap(controller.wrapBox)
        #expect(controller.textView.textContainer?.widthTracksTextView == false && controller.textView.isHorizontallyResizable)
        #expect(world.state.stateHash == hash, "no document register changed")
        #expect(TextEditorModel.placeholder().image != nil)
        #expect(controller.model.attributes([.with { $0.fontFamily = "NoSuchFamilyAnywhere" }])[.font] != nil, "a missing family shows in the system font")
        #expect(TextEditorModel(document: world.document, node: OpID(counter: 999, replica: 9), sink: world.window.objectEditing).attributedString().length == 0)
        _ = TextEditorModel.placeholder().image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let window = controller.window { TestWindow.prepare(window) }
        controller.show()
        controller.close()
    }

    @Test func theEditorOpensByEachRoute() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let features = TextEditorFeatures.shared
        let node = try await world.block("route")
        // menu:Text[Editor…] on the selected block.
        let commands = features.commands { world.window }
        #expect(commands[0].validation().isEnabled && commands[0].defaultKey == KeyEquivalent("e", [.command, .shift]))
        if case .perform(let run) = commands[0].action { run() }
        try await Task.sleep(for: .milliseconds(50))
        let opened = try #require(features.controller(for: node, in: world.document))
        opened.close()
        #expect(features.controller(for: node, in: world.document) == nil)
        // Nothing selected: disabled; the menu with no window does nothing.
        world.window.selection.model.clear()
        #expect(!commands[0].validation().isEnabled)
        if case .perform(let run) = features.commands(window: { nil })[0].action { run() }
        // Option-double-click with the Pointer.
        world.window.toolManager.select(.pointer)
        let center = try #require(world.document.object(for: SelectionID(node))?.bounds).center
        let tool = try #require(world.window.toolManager.activeTool as? PointerTool)
        tool.mouseDown(world.setup.event(center, .option, clicks: 2))
        tool.mouseUp(world.setup.event(center, .option, clicks: 2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(features.controller(for: node, in: world.document) != nil)
        features.closeAll(of: world.document)
        // Option-click on the block with the Text tool, and on empty page (a new block).
        world.window.toolManager.select(TextTool.id)
        let text = try #require(world.window.toolManager.activeTool as? TextTool)
        text.mouseDown(world.setup.event(center, .option))
        try await Task.sleep(for: .milliseconds(50))
        #expect(features.controller(for: node, in: world.document) != nil)
        features.closeAll(of: world.document)
        text.mouseDown(world.setup.event(Point(x: 300, y: 400), .option))
        try await Task.sleep(for: .milliseconds(100))
        await world.document.settle()
        let created = try #require(world.document.textNodes.first { $0 != node })
        #expect(features.controller(for: created, in: world.document) != nil && world.document.string(created) == "")
        features.closeAll(of: world.document)
        // *Always use Text Editor*: a plain click into a block opens it.
        _ = world.setup.environment.preferences.set(true, for: PreferenceCatalog.Text.alwaysUseEditor)
        text.mouseDown(world.setup.event(center))
        try await Task.sleep(for: .milliseconds(50))
        #expect(features.controller(for: node, in: world.document) != nil)
        #expect(TextToolSettings(preferences: world.setup.environment.preferences).alwaysUseEditor)
        // The Text tool's own block is the menu's target.
        await world.edit(node, select: 0..<2)
        #expect(TextEditorFeatures.target(in: world.window) == node)
    }

    @Test func collaboratorsCaretsShowInTheEditor() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("shared words")
        let text = try #require(world.state.textNode(node))
        let presence = StubPresenceModel()
        let model = TextEditorModel(document: world.document, node: node, sink: world.window.objectEditing)
        let controller = TextEditorController(model: model, presence: presence)
        defer { controller.close() }
        presence.participants = [
            RemoteParticipant(id: "p", name: "Priya", colorIndex: 1, caret: RemoteCaret(node: SelectionID(node), position: text.chars[2])),
            RemoteParticipant(id: "q", name: "Quinn", colorIndex: 2, caret: RemoteCaret(node: SelectionID(node), position: text.chars[0], rangeEnd: text.chars[6])),
            RemoteParticipant(id: "r", name: "Rae", colorIndex: 3, caret: RemoteCaret(node: SelectionID(node), position: .zero)),
            RemoteParticipant(id: "s", name: "Sam", colorIndex: 4, caret: RemoteCaret(node: SelectionID(OpID(counter: 999, replica: 9)), position: .zero)),
        ]
        let marks = model.remoteMarks(presence.participants)
        #expect(marks.map(\.range) == [NSRange(location: 2, length: 0), NSRange(location: 0, length: 6), NSRange(location: 12, length: 0)])
        #expect(marks.map(\.name) == ["Priya", "Quinn", "Rae"])
        // The local user types before a remote caret: it stays on its character.
        model.replace(NSRange(location: 0, length: 0), with: "The ")
        await model.session.settle()
        await world.document.settle()
        #expect(model.remoteMarks(presence.participants).first?.range == NSRange(location: 6, length: 0))
        let view = RemoteCaretView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.marks = [RemoteCaretView.Mark(rect: NSRect(x: 1, y: 20, width: 2, height: 12), color: .red, name: "Priya", isCaret: true),
                      RemoteCaretView.Mark(rect: NSRect(x: 4, y: 20, width: 30, height: 12), color: .blue, name: "Quinn", isCaret: false)]
        #expect(view.hitTest(.zero) == nil && view.isFlipped)
        _ = view.bitmapImageRepForCachingDisplay(in: view.bounds).map { view.cacheDisplay(in: view.bounds, to: $0) }
        // A deleted node shows no carets.
        await world.document.receiveRemote(DeleteNodes([node]))
        #expect(model.remoteMarks(presence.participants).isEmpty)
    }

    @Test func aRemoteDeleteOfTheEditedBlockOffersRestore() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("mine")
        let notice = RemovedTextNotice(window: world.window)
        defer { notice.stop() }
        await world.edit(node, select: 2..<2)
        notice.track()
        #expect(notice.editing == node)
        await world.document.receiveRemote(DeleteNodes([node]))
        await world.settle()
        let posted = try #require(world.window.pageNotices.notices.first)
        #expect(posted.text == RemovedTextNotice.text(author: "Someone") && posted.action == RemovedTextNotice.action)
        world.window.performNotice(posted.id)
        await world.document.settle()
        #expect(world.state.isLive(node) && world.document.undoTitle == "Undo Restore text")
        // Editing that ended with the block alive watches nothing; a local delete posts nothing.
        world.window.objectEditing.textSession = nil
        notice.track()
        #expect(notice.editing == nil)
        await world.edit(node, select: 0..<0)
        notice.track()
        _ = await world.document.perform(DeleteNodes([node])).value
        await world.settle()
        #expect(world.window.pageNotices.notices.isEmpty)
        notice.documentDidChange(nil)
    }

    // MARK: Find and Replace Text (TYPE-013)

    @Test func findReplaceAndReplaceAllOnTheFrontWindow() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let first = try await world.block("colour one", at: Point(x: 20, y: 20))
        let second = try await world.block("two colour three colour", at: Point(x: 20, y: 120))
        world.window.selection.model.clear()
        let model = FindTextModel()
        model.find = "colour"
        model.replacement = "color"
        let match = try #require(model.findNext(in: world.window))
        #expect(match.node == first && world.session?.selectedRange == 0..<6, "the match shows as the Text tool's selection")
        #expect(model.findNext(in: world.window)?.node == second)
        #expect(model.findNext(in: world.window)?.range == 17..<23)
        #expect(model.findNext(in: world.window)?.node == first, "wraps to the start")
        // Replace: the current match, then the next is shown.
        await model.replace(in: world.window)?.value
        await world.settle()
        #expect(world.document.string(first) == "color one" && model.current?.node == second)
        await model.replaceAndFind(in: world.window)?.value
        await world.settle()
        #expect(world.document.string(second) == "two color three colour")
        // Replace All: one change with the documented label.
        let all = try #require(model.replaceAll(in: world.window))
        _ = await all.value
        #expect(world.document.string(second) == "two color three color")
        #expect(world.document.undoTitle == "Undo Replace all 'colour' with 'color' (1)" && model.message == "1 replaced")
        #expect(model.replaceAll(in: world.window) == nil && model.message == "Not found")
        #expect(model.findNext(in: world.window) == nil)
        model.find = ""
        #expect(model.findNext(in: world.window) == nil && model.message == nil)
        #expect(model.replace(in: world.window) == nil)
        // Selection scope: the Text tool's range, then the selected blocks.
        model.find = "o"
        model.scope = .selection
        await world.edit(second, select: 0..<3)
        #expect(model.matches(in: world.window).map(\.range) == [2..<3])
        world.window.objectEditing.textSession = nil
        world.window.selection.model.set(Selection([SelectionID(first)]))
        #expect(model.matches(in: world.window).allSatisfy { $0.node == first })
        world.window.selection.model.clear()
        #expect(model.matches(in: world.window).isEmpty)
        // The Special pop-ups and the limit.
        model.insertSpecial("\u{2014}", intoReplacement: true)
        model.insertSpecial("\t", intoReplacement: false)
        #expect(model.replacement == "color\u{2014}" && model.find == "o\t")
        model.find = String(repeating: "x", count: 300)
        model.replacement = String(repeating: "y", count: 300)
        #expect(model.find.count == 255 && model.replacement.count == 255)
        #expect(FindTextModel.specials.count == 11 && FindTextModel.Scope.selection.title == "Selection" && FindTextModel.Scope.document.id == "document")
    }

    @Test func theFindWindowAndItsCommand() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let features = FindTextFeatures()
        let commands = features.commands { world.window }
        #expect(commands[0].defaultKey == KeyEquivalent("f", .command) && commands[0].validation().isEnabled)
        #expect(!features.commands(window: { nil })[0].validation().isEnabled)
        let panel = features.show(window: { world.window }, ordersFront: false)
        #expect(features.show(window: { world.window }, ordersFront: false) === panel && panel.title == "Find and Replace Text")
        if case .perform(let run) = commands[0].action { run() }
        panel.close()
        let view = FindTextView(model: features.model) { world.window }
        PanelRendering.host(view)
        FindTextView.inserting("\n", features.model, replacement: false)()
        #expect(features.model.find.hasSuffix("\n"))
        var ran = false
        FindTextView.acting({ _, _ in ran = true }, features.model) { world.window }()
        FindTextView.acting({ _, _ in Issue.record("no window") }, features.model) { nil }()
        #expect(ran)
    }

    // MARK: Spelling (TYPE-014)

    /// A dictionary of the words given.
    @MainActor
    final class StubSpelling: SpellingService {
        var words: Set<String>
        private(set) var learned: [String] = []
        private(set) var languages: [String?] = []

        init(_ words: Set<String>) { self.words = words }

        func isCorrect(_ word: String, language: String?) -> Bool {
            languages.append(language)
            return words.contains(word) || learned.contains(word)
        }

        func guesses(for word: String, language: String?) -> [String] { ["guess-\(word)"] }
        func learn(_ word: String) { learned.append(word) }
        func unlearn(_ word: String) { learned.removeAll { $0 == word } }
        func hasLearned(_ word: String) -> Bool { learned.contains(word) }
    }

    @Test func eachSpellingPreferenceChangesTheResults() async throws {
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.hyphenation.language = "fr"
        let world = TypeWorld()
        defer { world.close() }
        let node = try #require(await world.document.perform(CreateTextBlock(.point(Point(x: 10, y: 10)),
            text: "the the teh B2B NASA www.example.com. done", paragraph: paragraph)).value?.createdObjects.first)
        let text = try #require(world.state.textNode(node))
        let service = StubSpelling(["the", "B2B", "NASA", "www", "example", "com", "done"])
        var options = SpellingOptions()
        options.filters = SpellingFilters(ignoreNumbers: false, ignoreAddresses: false, ignoreUppercase: false)
        let all = SpellingChecker(service: service, options: options).issues(in: text)
        #expect(all.map(\.kind) == [.capitalization, .duplicate, .misspelled, .capitalization], "\(all)")
        #expect(all[1].range == 3..<7, "the repeat and its space")
        #expect(service.languages.allSatisfy { $0 == "fr" }, "the paragraph's language wins")
        options.findDuplicates = false
        options.findCapitalization = false
        #expect(SpellingChecker(service: service, options: options).issues(in: text).map(\.word) == ["teh"])
        service.words = ["the", "teh"]
        #expect(SpellingChecker(service: service, options: options).issues(in: text).map(\.word) == ["B2B", "NASA", "www", "example", "com", "done"])
        options.filters.ignoreNumbers = true
        options.filters.ignoreAddresses = true
        options.filters.ignoreUppercase = true
        #expect(SpellingChecker(service: service, options: options).issues(in: text).map(\.word) == ["done"])
        options.learnsLowercase = true
        #expect(SpellingChecker(service: service, options: options).learnedForm("Teh") == "teh")
        #expect(SpellingChecker(service: service, options: SpellingOptions()).learnedForm("Teh") == "Teh")
        // The preferences.
        let preferences = world.setup.environment.preferences
        _ = preferences.set("lowercase", for: PreferenceCatalog.Spelling.learnedWordCase)
        _ = preferences.set("en_GB", for: PreferenceCatalog.Spelling.dictionary)
        let read = SpellingOptions(preferences: preferences)
        #expect(read.learnsLowercase && read.language == "en_GB" && read.findDuplicates)
        #expect(all.map(\.message).prefix(3) == ["Capitalize the start of the sentence: the", "Duplicate word: the", "Not in dictionary: teh"])
        #expect(all.map(\.suggestion) == ["The", "", nil, "Done"])
    }

    @Test func theSpellingWindowCorrectsIgnoresAndLearns() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Teh cat sat. Mispeled word teh")
        let service = StubSpelling(["cat", "sat", "word", "The"])
        let model = SpellingModel(service: service)
        world.window.selection.model.clear()
        let first = try #require(model.findNext(in: world.window))
        #expect(first.word == "Teh" && model.correction == "guess-Teh" && world.session?.selectedRange == 0..<3)
        model.correction = "The"
        await model.change(in: world.window)?.value
        await world.settle()
        #expect(world.document.string(node) == "The cat sat. Mispeled word teh" && world.document.undoTitle == "Undo Correct spelling")
        #expect(model.current?.word == "Mispeled")
        // Learn writes nothing to the document.
        let hash = world.state.stateHash
        model.learn(in: world.window)
        #expect(service.learned == ["Mispeled"] && world.state.stateHash == hash && model.current?.word == "teh")
        model.unlearn()
        #expect(service.learned == ["Mispeled"], "Unlearn takes the current word out")
        model.ignore(in: world.window)
        #expect(model.current == nil && model.message == "No spelling problems found")
        #expect(model.change(in: world.window) == nil)
        model.learn(in: world.window)
        model.unlearn()
        model.ignore(in: world.window)
        // The window, the commands and the canvas underlines.
        let features = SpellingFeatures(service: service)
        let preferences = world.setup.environment.preferences
        let commands = features.commands(window: { world.window }, preferences: preferences)
        #expect(commands.map(\.title) == ["Spelling…", "Check Spelling…", "Check Spelling While Typing"])
        #expect(commands[0].validation().isEnabled && commands[2].validation().isChecked)
        if case .perform(let run) = commands[2].action { run() }
        #expect(!preferences[PreferenceCatalog.Spelling.checkWhileTyping])
        if case .perform(let run) = commands[2].action { run() }
        #expect(!features.commands(window: { nil }, preferences: preferences)[0].validation().isEnabled)
        let panel = features.show(window: { world.window }, ordersFront: false)
        #expect(features.show(window: { world.window }, ordersFront: false) === panel)
        if case .perform(let run) = commands[0].action { run() }
        panel.close()
        PanelRendering.host(SpellingView(model: features.model) { world.window })
        SpellingView.acting({ _, _ in }, features.model) { world.window }()
        SpellingView.acting({ _, _ in Issue.record("no window") }, features.model) { nil }()
        // Check while typing: the Text tool's block is underlined.
        await world.edit(node, select: 0..<0)
        let typing = TypingSpelling(window: world.window, checker: { SpellingChecker(service: service, options: SpellingOptions()) }, isOn: { true })
        #expect(typing.issues().map(\.word) == ["teh"])
        #expect(typing.issues().map(\.word) == ["teh"], "cached")
        #expect(typing.underlines(viewport: world.window.viewport).count == 1)
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        typing.draw(in: context, viewport: world.window.viewport)
        let off = TypingSpelling(window: world.window, checker: { SpellingChecker(service: service, options: SpellingOptions()) }, isOn: { false })
        #expect(off.issues().isEmpty)
        off.draw(in: context, viewport: world.window.viewport)
        // The system service answers without the network.
        let system = SystemSpellingService()
        #expect(system.isCorrect("house", language: "en") && !system.isCorrect("hsoue", language: "en"))
        _ = system.guesses(for: "hsoue", language: "en")
        system.ignore("hsoue")
        #expect(system.isCorrect("hsoue", language: "en"))
        _ = system.hasLearned("wiretunerword")
    }

    @Test func aSpellingCorrectionConcurrentWithTypingKeepsTheTypedCharacters() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("recieve")
        let text = try #require(world.state.textNode(node))
        let match = TextMatch(node: node, range: 0..<7, first: text.chars[0], last: text.chars[6])
        // The remote replica types at the end of the word before the correction arrives.
        let base = world.state
        var remote = DocumentCore(state: base, replica: 0xBEEF)
        let typed = try #require(try remote.perform(InsertText(node: node, text: "d", at: .end), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        _ = await world.window.objectEditing.perform(ReplaceText([match], with: "receive", label: ReplaceText.correctSpelling)).value
        _ = await world.document.receive(typed).value
        await world.document.settle()
        #expect(world.document.string(node) == "received")
    }

    // MARK: Nudges (TYPE-019)

    @Test func nudgesAddUpToOneChangeAndAPauseMakesTwo() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("AVATAR")
        await world.edit(node, select: 1..<1)
        let nudger = TypeNudger.nudger(for: world.window.objectEditing)
        #expect(TypeNudger.nudger(for: world.window.objectEditing) === nudger)
        nudger.pause = .milliseconds(200)
        let before = world.document.undoTitle
        for _ in 0..<10 { #expect(nudger.nudge(TypeNudge(kind: .kerning, delta: 1))) }
        try await Task.sleep(for: .milliseconds(400))
        _ = await nudger.written?.value
        await world.settle()
        // Kerning at the insertion point: a span-1 mark on the character before it.
        let text = try #require(world.state.textNode(node))
        #expect(TextLayoutReading.attributes(text.values(at: 0)).kerning == 10 && TextLayoutReading.attributes(text.values(at: 1)).kerning == 0)
        #expect(world.document.undoTitle == "Undo Kern" && before != world.document.undoTitle)
        _ = await world.document.undo().value
        await world.settle()
        #expect(TextLayoutReading.attributes(try #require(world.state.textNode(node)).values(at: 0)).kerning == 0, "one undo step")
        // Two bursts: two changes.
        _ = await world.document.redo().value
        nudger.nudge(TypeNudge(kind: .kerning, delta: 1))
        _ = await nudger.flush()?.value
        nudger.nudge(TypeNudge(kind: .kerning, delta: -2))
        _ = await nudger.flush()?.value
        await world.settle()
        #expect(TextLayoutReading.attributes(try #require(world.state.textNode(node)).values(at: 0)).kerning == 9)
        // Range kerning, baseline shift and size over a selection; another kind flushes.
        await world.edit(node, select: 0..<3)
        nudger.nudge(TypeNudge(kind: .kerning, delta: 10))
        nudger.nudge(TypeNudge(kind: .baselineShift, delta: 2))
        nudger.nudge(TypeNudge(kind: .size, delta: 1))
        _ = await nudger.flush()?.value
        await world.settle()
        let styled = TextLayoutReading.attributes(try #require(world.state.textNode(node)).values(at: 1))
        #expect(styled.rangeKerning == 10 && styled.baselineShift == 2 && styled.size == 13)
        // At an insertion point, baseline shift goes to the pending format (2 before it, plus 3).
        await world.edit(node, select: 2..<2)
        #expect(nudger.nudge(TypeNudge(kind: .baselineShift, delta: 3)))
        await world.settle()
        #expect(world.session?.pendingFormat.contains { $0.baselineShift == 5 } == true)
        // Nothing to write: a caret at the start, no text session.
        await world.edit(node, select: 0..<0)
        nudger.nudge(TypeNudge(kind: .kerning, delta: 1))
        #expect(nudger.flush() == nil)
        #expect(nudger.flush() == nil)
        world.window.objectEditing.textSession = nil
        #expect(!nudger.nudge(TypeNudge(kind: .size, delta: 1)))
        #expect(TypeNudger.command(.size, delta: 0, node: node, range: 0..<1, in: try #require(world.state.textNode(node))) == nil)
        #expect(TypeNudger.command(.size, delta: 1, node: node, range: 50..<60, in: try #require(world.state.textNode(node))) == nil)
    }

    @Test func theNudgeKeys() throws {
        #expect(TypeNudge(keyCode: TypeNudge.kernRight, modifiers: [.command, .option]) == TypeNudge(kind: .kerning, delta: 1))
        #expect(TypeNudge(keyCode: TypeNudge.kernLeft, modifiers: [.command, .option, .shift]) == TypeNudge(kind: .kerning, delta: -10))
        #expect(TypeNudge(keyCode: TypeNudge.up, modifiers: [.control, .option]) == TypeNudge(kind: .baselineShift, delta: 1))
        #expect(TypeNudge(keyCode: TypeNudge.down, modifiers: [.control, .option, .shift]) == TypeNudge(kind: .baselineShift, delta: -10))
        #expect(TypeNudge(keyCode: TypeNudge.period, modifiers: [.command, .shift]) == TypeNudge(kind: .size, delta: 1))
        #expect(TypeNudge(keyCode: TypeNudge.comma, modifiers: [.command, .shift]) == TypeNudge(kind: .size, delta: -1))
        #expect(TypeNudge(keyCode: TypeNudge.kernLeft, modifiers: [.command]) == nil)
        #expect(TypeNudge(keyCode: 0, modifiers: [.command, .option]) == nil)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: TypeNudge.kernRight))
        #expect(TypeNudge(event: event)?.kind == .kerning)
        let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
                                               context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: TypeNudge.kernRight))
        #expect(TypeNudge(event: up) == nil)
    }

    @Test func theTextToolRoutesNudgeKeys() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("key")
        await world.edit(node, select: 1..<1)
        let tool = try #require(world.window.toolManager.activeTool as? TextTool)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: TypeNudge.kernRight))
        #expect(tool.keyDown(event))
        #expect(TypeNudger.nudger(for: world.window.objectEditing).pending?.delta == 1)
        TypeNudger.nudger(for: world.window.objectEditing).flush()
    }
}

/// Mark values for the app tests.
enum TextFixtureMarks {
    static func mark(_ build: (inout Wiretuner_Doc_V1_TextMarkValue) -> Void) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        build(&value)
        return value
    }
}
