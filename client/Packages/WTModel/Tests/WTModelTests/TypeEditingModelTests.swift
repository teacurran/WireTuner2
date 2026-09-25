import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// The model halves of the type-editing UI tasks: Find and Replace Text (TYPE-013), spelling's
/// passes (TYPE-014), tab stops (TYPE-023), text wrap (TYPE-039), alt text (OBJ-040) and the
/// graphics replace (OBJ-023).
@Suite struct TypeEditingModelTests {
    /// A replica with a layer and a block holding `text`.
    static func block(_ text: String) throws -> (Replica, OpID) {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let node = try TextFixture.block(&a, text)
        return (a, node)
    }

    // MARK: Find and replace (TYPE-013)

    @Test func findMatchesCaseWholeWordsAndRanges() throws {
        let (a, node) = try Self.block("Colour colour COLOUR colours")
        let text = TextFixture.text(a, node)
        #expect(TextFinder.matches(TextSearch("colour"), in: text).map(\.range) == [0..<6, 7..<13, 14..<20, 21..<27])
        #expect(TextFinder.matches(TextSearch("colour", matchCase: true), in: text).map(\.range) == [7..<13, 21..<27])
        #expect(TextFinder.matches(TextSearch("colour", wholeWord: true), in: text).map(\.range) == [0..<6, 7..<13, 14..<20])
        #expect(TextFinder.matches(TextSearch("colour"), in: text, within: 5..<20).map(\.range) == [7..<13, 14..<20])
        #expect(TextFinder.matches(TextSearch(""), in: text).isEmpty)
        #expect(TextFinder.matches(TextSearch("COLOURS", wholeWord: true), in: text).map(\.range) == [21..<28])
        // A capital whose lowercase is two scalars is compared as it is.
        let (c, dotted) = try Self.block("İstanbul istanbul")
        #expect(TextFinder.matches(TextSearch("İ"), in: TextFixture.text(c, dotted)).map(\.range) == [0..<1])
        #expect(TextFinder.matches(TextSearch("oo"), in: text).isEmpty)
        // Overlapping candidates: "aaa" in "aaaa" matches once.
        let (b, other) = try Self.block("aaaa")
        #expect(TextFinder.matches(TextSearch("aa"), in: TextFixture.text(b, other)).map(\.range) == [0..<2, 2..<4])
        // The search string stops at 255 characters.
        #expect(TextSearch(String(repeating: "x", count: 300)).find.count == 255)
        // Nodes in stacking order, and within a selection.
        #expect(TextFinder.nodes(in: a.state) == [node])
        #expect(TextFinder.nodes(in: a.state, within: [node]) == [node])
        #expect(TextFinder.matches(TextSearch("COLOUR", matchCase: true), in: a.state, nodes: [node, OpID(counter: 999, replica: 9)]).count == 1)
    }

    @Test func replaceAllIsOneChangeWithTheLabelAndOpPattern() throws {
        var (a, node) = try Self.block("colour and colour")
        // A size mark on the character before the second match only: the replacement clears it.
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 10), to: TextFixture.at(a, node, 11), value: TextFixture.mark { $0.kerning = 5 }))
        let bold = TextFixture.mark { $0.fontStyle = "Bold" }
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 11), to: .end, value: bold))
        let before = TextFixture.text(a, node)
        let matches = TextFinder.matches(TextSearch("colour"), in: before)
        let label = ReplaceText.replaceAllLabel("colour", "color", count: matches.count)
        #expect(label == "Replace all 'colour' with 'color' (2)")
        let change = try #require(try a.perform(ReplaceText(matches, with: "color", label: label)))
        #expect(change.label == label)
        let inserts = change.ops.compactMap { op -> Wiretuner_Doc_V1_TextInsert? in if case .textInsert(let i)? = op.op { i } else { nil } }
        let deletes = change.ops.filter { if case .textDelete? = $0.op { true } else { false } }
        #expect(inserts.map(\.chars) == ["color", "color"] && deletes.count == 2)
        // Each replacement sits between the character before the match and the match's first.
        #expect(OpID(element: inserts[1].leftOrigin) == before.chars[10] && OpID(element: inserts[1].rightOrigin) == before.chars[11])
        #expect(OpID(element: inserts[0].leftOrigin) == nil, "the start of the text")
        let after = TextFixture.text(a, node)
        #expect(after.string == "color and color")
        // The second replacement keeps the bold of the word it replaced.
        #expect(after.values(at: 12).contains(bold) && !after.values(at: 2).contains(bold))
        // A replacement of nothing deletes; a match that is gone is skipped.
        let gone = TextFinder.matches(TextSearch("color"), in: after)
        try a.perform(ReplaceText([gone[0]], with: "", label: "Replace"))
        #expect(TextFixture.text(a, node).string == " and color")
        #expect(try a.perform(ReplaceText([gone[0]], with: "x", label: "Replace")) == nil)
        #expect(ReplaceText.resolve(gone[0], in: TextFixture.text(a, node)) == nil)
        // A newline in the replacement splits the paragraph.
        let rest = TextFinder.matches(TextSearch("and"), in: TextFixture.text(a, node))
        try a.perform(ReplaceText(rest, with: "\n", label: ReplaceText.correctSpelling))
        #expect(TextFixture.text(a, node).paragraphs.count == 2)
        #expect(throws: TextEditError.notText(OpID(counter: 99, replica: 9))) {
            try a.perform(ReplaceText([TextMatch(node: OpID(counter: 99, replica: 9), range: 0..<1, first: .zero, last: .zero)], with: "", label: "x"))
        }
    }

    @Test func replaceAllConcurrentWithTypingKeepsTheTypedLetters() throws {
        // "colour" + a concurrent "s" at the end, replaced with "color": "colors".
        var pair = Pair()
        _ = try LayerFixture.layers(["Art"], on: &pair.a)
        let node = try TextFixture.block(&pair.a, "colour")
        pair.sync()
        let matches = TextFinder.matches(TextSearch("colour"), in: TextFixture.text(pair.a, node))
        try pair.a.perform(ReplaceText(matches, with: "color", label: "Replace all"))
        try pair.b.perform(InsertText(node: node, text: "s", at: .end))
        pair.sync()
        #expect(TextFixture.text(pair.a, node).string == "colors" && pair.a.state.stateHash == pair.b.state.stateHash)
        // A letter typed mid-word lands after the replacement.
        var mid = Pair()
        _ = try LayerFixture.layers(["Art"], on: &mid.a)
        let word = try TextFixture.block(&mid.a, "colour")
        mid.sync()
        try mid.a.perform(ReplaceText(TextFinder.matches(TextSearch("colour"), in: TextFixture.text(mid.a, word)), with: "color", label: "Replace all"))
        try mid.b.perform(InsertText(node: word, text: "x", at: TextFixture.at(mid.b, word, 3)))
        mid.sync()
        #expect(TextFixture.text(mid.a, word).string == "colorx" && mid.a.state.stateHash == mid.b.state.stateHash)
    }

    @Test func searchingTwoHundredThousandCharactersIsFast() throws {
        let (a, node) = try Self.block(String(repeating: "lorem ipsum dolor sit amet ", count: 7_500))
        let text = TextFixture.text(a, node)
        #expect(text.length >= 200_000)
        let clock = ContinuousClock()
        var found = 0
        let elapsed = clock.measure { found = TextFinder.matches(TextSearch("dolor", wholeWord: true), in: text).count }
        #expect(found == 7_500)
        // 100 ms is the budget; a debug build on a loaded machine gets ten times that here.
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }

    // MARK: Spelling passes (TYPE-014)

    @Test func spellingPassesAndFilters() throws {
        let scalars = Array("the the cat's  paws. next line 3D www.example.com B2B NASA".unicodeScalars)
        let words = SpellingPasses.words(scalars)
        #expect(words.map(\.word) == ["the", "the", "cat's", "paws", "next", "line", "3D", "www", "example", "com", "B2B", "NASA"])
        #expect(SpellingPasses.duplicates(words, in: scalars).map(\.range) == [4..<7])
        #expect(SpellingPasses.capitalization(words, in: scalars).map(\.word) == ["the", "next"])
        #expect(SpellingPasses.words(Array("'quoted' it's".unicodeScalars)).map(\.word) == ["quoted", "it's"])
        #expect(SpellingPasses.capitalization([], in: []).isEmpty)
        let token = SpellingPasses.token(around: words[8].range, in: scalars)
        #expect(token == "www.example.com")
        let filters = SpellingFilters(ignoreNumbers: true, ignoreAddresses: true, ignoreUppercase: true)
        #expect(filters.ignores("3D", token: "3D") && filters.ignores("example", token: token) && filters.ignores("NASA", token: "NASA"))
        #expect(!filters.ignores("cat", token: "cat") && !filters.ignores("A", token: "A"))
        let none = SpellingFilters(ignoreNumbers: false, ignoreAddresses: false, ignoreUppercase: false)
        #expect(!none.ignores("3D", token: "3D") && !none.ignores("example", token: token) && !none.ignores("NASA", token: "NASA"))
        for address in ["http://x.org", "mailto:a", "/usr/bin", "~/Documents", "./a", "me@example.com"] { #expect(SpellingPasses.isAddress(address)) }
        for plain in ["word", "@home", "a@b"] { #expect(!SpellingPasses.isAddress(plain)) }
        var a = Replica(0xA)
        var paragraph = Wiretuner_Doc_V1_ParagraphProps()
        paragraph.hyphenation.language = "de"
        let node = try TextFixture.block(&a, "Haus", paragraph: paragraph)
        #expect(SpellingPasses.language(of: TextFixture.text(a, node).paragraphs[0]) == "de")
        let plainNode = try TextFixture.block(&a, "house")
        #expect(SpellingPasses.language(of: TextFixture.text(a, plainNode).paragraphs[0]) == nil)
    }

    // MARK: Tab stops (TYPE-023)

    @Test func tabStopsArePlacedMovedEditedAndRemovedPerParagraph() throws {
        var (a, node) = try Self.block("one\ntwo")
        let all = (TextFixture.at(a, node, 0), Anchor.end)
        try a.perform(AddTabStop(node: node, from: all.0, to: all.1, stop: .with { $0.kind = .right; $0.position = 72 }))
        try a.perform(AddTabStop(node: node, from: all.0, to: all.1, stop: .with { $0.kind = .wrapping; $0.position = 36; $0.leader = "." }))
        var paragraphs = TextFixture.text(a, node).paragraphs
        #expect(paragraphs.map { TextTabs.stops($0).map(\.stop.position) } == [[36, 72], [36, 72]])
        #expect(TextTabs.stops(paragraphs[0])[0].stop.leader == "", "a wrapping stop takes no leader")
        let move = SetTabStop(node: node, from: all.0, to: all.1, at: 72, stop: .with { $0.position = 100 }, fields: [.position])
        #expect(move.label == "Move Tab")
        try a.perform(move)
        let edit = SetTabStop(node: node, from: all.0, to: all.1, at: 100, stop: .with { $0.kind = .decimal; $0.leader = "-" }, fields: [.kind, .leader])
        #expect(edit.label == "Edit Tab")
        try a.perform(edit)
        paragraphs = TextFixture.text(a, node).paragraphs
        #expect(TextTabs.stops(paragraphs[1]).map(\.stop.kind) == [.wrapping, .decimal])
        #expect(TextTabs.stops(paragraphs[1])[1].stop.leader == "-")
        #expect(throws: TextEditError.invalidValue("leader")) {
            try a.perform(SetTabStop(node: node, from: all.0, to: all.1, at: 36, stop: .with { $0.leader = "." }, fields: [.leader]))
        }
        #expect(throws: TextEditError.invalidValue("fields")) {
            try a.perform(SetTabStop(node: node, from: all.0, to: all.1, at: 36, stop: .init(), fields: []))
        }
        #expect(throws: TextEditError.invalidValue("position")) {
            try a.perform(AddTabStop(node: node, from: all.0, to: all.1, stop: .with { $0.position = .infinity }))
        }
        // Only the caret's paragraph.
        let delete = DeleteTabStop(node: node, from: TextFixture.at(a, node, 5), to: TextFixture.at(a, node, 5), at: 36)
        #expect(delete.label == "Delete Tab")
        try a.perform(delete)
        paragraphs = TextFixture.text(a, node).paragraphs
        #expect(TextTabs.stops(paragraphs[0]).count == 2 && TextTabs.stops(paragraphs[1]).count == 1)
        #expect(try a.perform(DeleteTabStop(node: node, from: all.0, to: all.1, at: 500)) == nil)
    }

    @Test func twoReplicasAddingDifferentStopsKeepBoth() throws {
        var pair = Pair()
        let node = try TextFixture.block(&pair.a, "tabs")
        pair.sync()
        try pair.a.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = 20 }))
        try pair.b.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = 40 }))
        pair.sync()
        #expect(TextTabs.stops(TextFixture.text(pair.a, node).paragraphs[0]).map(\.stop.position) == [20, 40])
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    // MARK: Text wrap (TYPE-039)

    @Test func textWrapIsWrittenAndCollectedFromObjectsInFront() throws {
        var (a, node) = try Self.block("Body text that wraps around the pull quote in front of it")
        let art = LayerOrder(a.state).layers.first!.id
        let square = try LayerFixture.object(LayerFixture.rect(on: art, x: 10, size: 20), on: &a)
        let pullQuote = try a.perform(CreateTextBlock(.area(Rect(x: 5, y: 5, width: 40, height: 20)), text: "Quote"))!.createdObjects[0]
        #expect(TextWrapping.exclusions(for: node, in: a.state).isEmpty)
        let set = SetTextWrap([square, pullQuote], enabled: true, standoff: 6)
        #expect(set.label == "Text Wrap")
        try a.perform(set)
        #expect(TextWrapping.wrap(of: square, in: a.state)?.standoff == 6)
        #expect(TextWrapping.wrappingObjects(for: node, in: a.state) == [square, pullQuote])
        let exclusions = TextWrapping.exclusions(for: node, in: a.state)
        #expect(exclusions.count == 2 && exclusions.allSatisfy { $0.standoff == 6 })
        #expect(TextLayoutReading.sources(node, in: a.state).contains(square))
        // Objects behind do not wrap the text in front of them.
        #expect(TextWrapping.wrappingObjects(for: pullQuote, in: a.state).isEmpty)
        let wrapped = TextWrapping.wrapped(TextLayoutReading.container(TextFixture.text(a, node)), text: node, in: a.state)
        guard case .block(let block) = wrapped else { Issue.record("block"); return }
        #expect(block.exclusions.count == 2)
        let path = TextWrapping.wrapped(.path(PathText(contour: Contour(polygon: [.zero, Point(x: 1, y: 0)], closed: false))), text: node, in: a.state)
        if case .block = path { Issue.record("a path container is left alone") }
        // Off, then groups refused.
        let remove = SetTextWrap([square], enabled: false)
        #expect(remove.label == "Remove Text Wrap")
        try a.perform(remove)
        #expect(TextWrapping.wrap(of: square, in: a.state) == nil)
        let group = try a.perform(GroupObjects([square]))!.createdObjects[0]
        #expect(!TextWrapping.isWrappable(group, in: a.state))
        #expect(throws: TextWrapError.notWrappable(group)) { try a.perform(SetTextWrap([group], enabled: true)) }
        #expect(throws: TextEditError.invalidValue("standoff")) { try a.perform(SetTextWrap([pullQuote], enabled: true, standoff: .nan)) }
        #expect(!TextWrapping.isWrappable(OpID(counter: 999, replica: 9), in: a.state))
        #expect(TextWrapping.wrappingObjects(for: OpID(counter: 999, replica: 9), in: a.state).isEmpty)
        // A chart wraps with its bounds; an auto-sized text block has no frame; a deleted object
        // and a group written by another client do not wrap.
        let chart = try a.perform(CreateChart(size: Size(width: 30, height: 30), transform: .translation(x: 50, y: 0)))!.createdObjects[0]
        let auto = try TextFixture.block(&a, "auto", at: Point(x: 80, y: 0))
        let gone = try LayerFixture.object(LayerFixture.rect(on: art, x: 90), on: &a)
        try a.perform(SetTextWrap([chart, auto, gone], enabled: true, standoff: 2))
        try a.perform(DeleteNodes([gone]))
        let kind = NodeKind.group.rawValue
        try a.perform(OpsCommand("Wrap group", ops: [Ops.set(group, [TextWrapFields.enabled(kind)], values: NavigationFields.values(kind: kind) { $0.textWrap.enabled = true })]))
        #expect(TextWrapping.wrap(of: group, in: a.state) == nil && TextWrapping.wrap(of: gone, in: a.state) == nil)
        let later = TextWrapping.exclusions(for: node, in: a.state)
        #expect(later.count == 2, "the pull quote and the chart")
    }

    @Test func standoffAndEnableFromTwoReplicasBothApply() throws {
        var pair = Pair()
        _ = try LayerFixture.layers(["Art"], on: &pair.a)
        let square = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.a.perform(OpsCommand("Standoff", ops: [Ops.set(square, [TextWrapFields.standoff(NodeKind.rect.rawValue)],
                                                                 values: NavigationFields.values(kind: NodeKind.rect.rawValue) { $0.textWrap.standoff = 9 })]))
        try pair.b.perform(OpsCommand("Enable", ops: [Ops.set(square, [TextWrapFields.enabled(NodeKind.rect.rawValue)],
                                                               values: NavigationFields.values(kind: NodeKind.rect.rawValue) { $0.textWrap.enabled = true })]))
        pair.sync()
        #expect(TextWrapping.wrap(of: square, in: pair.a.state) == .with { $0.enabled = true; $0.standoff = 9 })
    }

    // MARK: Alt text (OBJ-040)

    @Test func altTextDecorativeAndReadableNodes() throws {
        var (a, text) = try Self.block("Caption")
        let art = LayerOrder(a.state).layers.first!.id
        let logo = try LayerFixture.object(LayerFixture.rect(on: art), on: &a)
        let rule = try LayerFixture.object(LayerFixture.rect(on: art, x: 20), on: &a)
        #expect(a.state.accessibleDescription(of: text) == "Caption" && a.state.accessibleDescription(of: logo) == nil)
        let set = SetAlt([logo], alt: String(repeating: "x", count: 600))
        #expect(set.label == "Change alt text" && SetAlt([logo, rule], alt: "").label == "Change alt text of 2 objects")
        try a.perform(set)
        #expect(a.state.accessibleDescription(of: logo)?.count == 512)
        try a.perform(SetAlt([logo], alt: "Company logo"))
        try a.perform(SetDecorative([rule], decorative: true))
        #expect(SetDecorative([rule], decorative: false).label == "Not decorative" && SetDecorative([rule], decorative: true).label == "Decorative")
        #expect(a.state.isReadable(logo) && !a.state.isReadable(rule))
        // Ticking decorative keeps the alt text.
        try a.perform(SetDecorative([logo], decorative: true))
        #expect(!a.state.isReadable(logo) && NavigationFields.common(of: logo, in: a.state)?.alt == "Company logo")
        try a.perform(SetDecorative([logo], decorative: false))
        // A group with alt text is one readable node; without, its readable members.
        let group = try a.perform(GroupObjects([logo, rule]))!.createdObjects[0]
        #expect(a.state.readableNodes([group, text]) == [logo, text])
        try a.perform(SetAlt([group], alt: "Letterhead"))
        #expect(a.state.readableNodes([group]) == [group] && a.state.isReadable(group))
        #expect(a.state.readableNodes([OpID(counter: 999, replica: 9)]).isEmpty)
    }

    @Test func concurrentAltAndDecorativeEditsKeepBoth() throws {
        var pair = Pair()
        _ = try LayerFixture.layers(["Art"], on: &pair.a)
        let logo = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.a.perform(SetAlt([logo], alt: "From A"))
        try pair.b.perform(SetDecorative([logo], decorative: true))
        pair.sync()
        let common = try #require(NavigationFields.common(of: logo, in: pair.a.state))
        #expect(common.alt == "From A" && common.decorative)
        try pair.a.perform(SetAlt([logo], alt: "A again"))
        try pair.b.perform(SetAlt([logo], alt: "B"))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }

    // MARK: Graphics replace (OBJ-023)

    @Test func numberEditsParseAndApply() {
        #expect(NumberEdit("2") == .set(2) && NumberEdit("-3") == .set(-3) && NumberEdit("+1") == .add(1))
        #expect(NumberEdit("*2") == .multiply(2) && NumberEdit("×2") == .multiply(2) && NumberEdit("/4") == .divide(4) && NumberEdit("÷2") == .divide(2))
        for bad in ["", "abc", "+", "*x", "/0", "/"] { #expect(NumberEdit(bad) == nil, "\(bad)") }
        #expect(NumberEdit.add(1).apply(2) == 3 && NumberEdit.multiply(2).apply(2) == 4 && NumberEdit.divide(2).apply(2) == 1 && NumberEdit.set(5).apply(2) == 5)
    }

    @Test func replacingAColorAcross500ObjectsIsOneLabelledChange() throws {
        var a = Replica(0xA)
        let art = try LayerFixture.layers(["Art"], on: &a)[0]
        let red = AttributeQueryTests.red, blue = AttributeQueryTests.blue
        var nodes: [OpID] = []
        for index in 0..<500 {
            let node = try LayerFixture.object(LayerFixture.rect(on: art, x: Double(index) * 12), on: &a)
            nodes.append(node)
        }
        try a.perform(AddAppearance.fill(nodes, .with { $0.settings.kind = .basic; $0.settings.basic.color = red }))
        let text = try TextFixture.block(&a, "red words")
        try a.perform(TextColor.fill(node: text, from: .start, to: .end, red))
        try a.perform(ApplyMark(node: text, from: .start, to: TextFixture.at(a, text, 3), value: TextFixture.size(20)))
        let other = try TextFixture.block(&a, "blue words")
        try a.perform(TextColor.fill(node: other, from: .start, to: .end, blue))
        let candidates = AttributeQuery.candidates(.document, in: a.state)
        let chunks = ReplaceGraphics.chunks(.color(from: red, to: blue), candidates: candidates, in: a.state)
        #expect(chunks.count == 1 && chunks[0].label == "Replace color in 501 objects", "the blue text is not a match")
        let change = try #require(try a.perform(chunks[0]))
        #expect(change.label == "Replace color in 501 objects")
        #expect(AttributeQuery(.color(blue), in: .document).run(in: a.state).count == 502, "and the text that was blue")
        #expect(AttributeQuery(.color(red), in: .document).run(in: a.state).isEmpty)
        // Split by the op limit: parts with a suffix.
        let parts = ReplaceGraphics.chunks(.color(from: blue, to: red), candidates: candidates, limit: 200, in: a.state)
        #expect(parts.count == 3 && parts[0].label == "Replace color in 502 objects (1/3)")
        #expect(ReplaceGraphics.chunks(.color(from: red, to: blue), candidates: candidates, in: a.state).isEmpty)
        #expect(ReplaceGraphics(.rotate(10), candidates: nodes).label == "Replace rotation in 500 objects")
    }

    @Test func eachReplaceAttributeWritesItsRegisters() throws {
        var a = Replica(0xA)
        let art = try LayerFixture.layers(["Art"], on: &a)[0]
        let one = try LayerFixture.object(LayerFixture.rect(on: art, x: 0), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: art, x: 100), on: &a)
        let three = try LayerFixture.object(LayerFixture.rect(on: art, x: 300), on: &a)
        let nodes = [one, two, three]
        try a.perform(AddAppearance.fill([one], .with { $0.settings.kind = .basic }))
        func perform(_ edit: GraphicEdit, _ candidates: [OpID]) throws -> Wiretuner_Doc_V1_Change? {
            try a.perform(ReplaceGraphics(edit, candidates: ReplaceGraphics.matches(edit, in: candidates, state: a.state)))
        }
        // Stroke width: the default 1 pt strokes become 3 pt, then doubled.
        try perform(.strokeWidth(ValueRange(min: 0.5, max: 1.5), to: .set(3)), nodes)
        #expect(AttributeQuery(.strokeWidth(.exactly(3)), in: .document).run(in: a.state).count == 3)
        try perform(.strokeWidth(ValueRange(min: 3), to: .multiply(2)), nodes)
        #expect(AttributeQuery(.strokeWidth(.exactly(6)), in: .document).run(in: a.state).count == 3)
        #expect(ReplaceGraphics.matches(.strokeWidth(ValueRange(min: 6), to: .set(6)), in: nodes, state: a.state).isEmpty)
        // Rotate about each object's own centre: centres stay put.
        let centres = nodes.map { Objects.bounds(of: $0, in: a.state)!.center }
        try perform(.rotate(90), nodes)
        for (node, centre) in zip(nodes, centres) {
            let after = Objects.bounds(of: node, in: a.state)!.center
            #expect(abs(after.x - centre.x) < 1e-6 && abs(after.y - centre.y) < 1e-6)
        }
        #expect(ReplaceGraphics.matches(.rotate(360), in: nodes, state: a.state).isEmpty)
        // Scale about the centre.
        try perform(.scale(x: 200, y: 50), [one])
        let scaled = Objects.bounds(of: one, in: a.state)!
        #expect(abs(scaled.center.x - centres[0].x) < 1e-6)
        #expect(ReplaceGraphics.matches(.scale(x: 100, y: 100), in: nodes, state: a.state).isEmpty)
        // Halftones removed.
        try a.perform(SetObjectHalftone([two], halftone: .with { $0.frequency = 60 }))
        #expect(ReplaceGraphics.matches(.remove(.halftones), in: nodes, state: a.state) == [two])
        try perform(.remove(.halftones), nodes)
        #expect(ReplaceGraphics.matches(.remove(.halftones), in: nodes, state: a.state).isEmpty)
        // Invisible objects deleted.
        let appearance = AppearanceEditing.stack(three, in: a.state)
        for row in appearance { try a.perform(RemoveAppearance(node: three, row: row)) }
        #expect(ReplaceGraphics.matches(.remove(.invisible), in: nodes, state: a.state) == [three])
        try perform(.remove(.invisible), nodes)
        #expect(!a.state.isLive(three))
        // Simplify paths over a point count.
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (1, 0.1), (2, 0), (3, 0.1), (4, 0), (4, 4), (0, 4)]), on: &a)
        #expect(ReplaceGraphics.matches(.simplify(points: 10, amount: 50), in: [path], state: a.state).isEmpty)
        #expect(ReplaceGraphics.matches(.simplify(points: 3, amount: 50), in: [path, one], state: a.state) == [path])
        #expect(GraphicEdit.simplify(points: 3, amount: 50).noun == "path points")
        #expect(GraphicEdit.remove(.invisible).noun == "invisible objects" && GraphicEdit.remove(.halftones).noun == "halftones")
        #expect(GraphicEdit.blendSteps(ValueRange(), to: .set(3)).noun == "blend steps" && GraphicEdit.scale(x: 1, y: 1).noun == "scale")
        #expect(GraphicEdit.strokeWidth(ValueRange(), to: .set(1)).noun == "stroke width")
        // Blend steps.
        let start = try BlendCommandTests.square(&a, x: 500)
        let end = try BlendCommandTests.square(&a, x: 600)
        try a.perform(Blend([start, end]))
        let blend = try #require(BlendCommandTests.blend(of: start, a.state))
        let steps = Double(a.state.props(blend).blend.steps)
        try perform(.blendSteps(ValueRange(), to: .add(2)), [blend, one])
        #expect(Double(a.state.props(blend).blend.steps) == steps + 2)
        #expect(ReplaceGraphics.matches(.blendSteps(ValueRange(min: 5000), to: .set(2)), in: [blend], state: a.state).isEmpty)
        #expect(ReplaceGraphics.matches(.blendSteps(ValueRange(), to: .set(0)), in: [blend], state: a.state).isEmpty)
        #expect(ReplaceGraphics.matches(.rotate(10), in: [OpID(counter: 999, replica: 9)], state: a.state).isEmpty)
    }

    @Test func aReplaceConcurrentWithARemoteWidthEditConvergesPerRegister() throws {
        var pair = Pair()
        let art = try LayerFixture.layers(["Art"], on: &pair.a)[0]
        let one = try LayerFixture.object(LayerFixture.rect(on: art), on: &pair.a)
        let two = try LayerFixture.object(LayerFixture.rect(on: art, x: 50), on: &pair.a)
        pair.sync()
        let edit = GraphicEdit.strokeWidth(ValueRange(), to: .set(4))
        try pair.a.perform(ReplaceGraphics(edit, candidates: [one, two]))
        let row = AppearanceEditing.stack(two, in: pair.b.state).first { $0.list == .strokes }!
        try pair.b.perform(SetStrokeWidth([(two, row.element)], width: 9))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(AttributeQuery(.strokeWidth(.exactly(4)), in: .document).run(in: pair.a.state).contains(one))
    }
}
