import Testing
import WTGeometry
import WTRender
@testable import WTText

/// Character ids <-> glyph positions: carets, remote carets and hit testing (creating-text,
/// "Layout"; TXT-001 "Done when": carets survive remote edits).
@Suite struct CaretTests {
    static let replicaA: UInt64 = 1
    static let replicaB: UInt64 = 2

    /// "Hello brave new world" with ids from replica A, wrapped to two lines.
    static let words = "Hello brave new world, how are you today"

    @Test func caretsSitAtGlyphEdges() {
        let layout = Fixture.layout(CaretTests.words, in: [Fixture.block(width: 120)])
        let glyphs = layout.glyphs()
        for glyph in glyphs {
            let caret = layout.caret(atOffset: glyph.offset)!
            #expect(approx(caret.baseline.x, glyph.origin.x, 0.001))
            #expect(approx(caret.baseline.y, glyph.origin.y, 0.001))
            #expect(caret.top.y < caret.baseline.y && caret.bottom.y > caret.baseline.y)
            #expect(caret.container == 0 && caret.offset == glyph.offset)
        }
        let count = CaretTests.words.unicodeScalars.count
        let end = layout.caret(atOffset: count)!
        let last = glyphs.last!
        #expect(approx(end.baseline.x, last.origin.x + last.advance, 0.001))
        #expect(layout.caret(atOffset: count + 1) == nil)
        #expect(layout.caret(atOffset: -1) == nil)
    }

    @Test func anchorsChooseTheirSideOfASoftBreak() {
        let layout = Fixture.layout(CaretTests.words, in: [Fixture.block(width: 120)])
        let wrap = layout.lineRanges[0].upperBound  // the first character of line 2
        let before = layout.caret(for: .before(layout.charID(at: wrap)!))!
        let after = layout.caret(for: .after(layout.charID(at: wrap - 1)!))!
        #expect(before.baseline.y > after.baseline.y, "after the space ending line 1 stays on line 1")
        #expect(approx(before.baseline.x, 0, 1.5))
        #expect(after.offset == before.offset)
        #expect(layout.caret(atOffset: wrap, upstream: true)!.baseline.y == after.baseline.y)
        #expect(layout.caret(atOffset: 3, upstream: true) == layout.caret(atOffset: 3), "upstream only matters at a line break")
        // After a newline is the start of the next paragraph.
        let paragraphs = Fixture.layout("one\ntwo", in: [Fixture.block()])
        let newline = paragraphs.charID(at: 3)!
        let afterNewline = paragraphs.caret(for: .after(newline))!
        #expect(afterNewline.offset == 4 && approx(afterNewline.baseline.x, 0))
        #expect(afterNewline.baseline.y > paragraphs.caret(for: .before(newline))!.baseline.y)
        // Unknown ids and characters that were not laid out have no caret.
        #expect(layout.caret(for: .before(CharID(counter: 999, replica: 9))) == nil)
        let overflow = Fixture.layout(CaretTests.words, in: [Fixture.block(width: 60, height: 15)])
        #expect(overflow.caret(for: .before(overflow.charID(at: 30)!)) == nil)
    }

    @Test func hitTestsFindTheNearestBoundary() {
        let layout = Fixture.layout(CaretTests.words, in: [Fixture.block(width: 120)])
        let count = CaretTests.words.unicodeScalars.count
        let wraps = Set(layout.lineRanges.dropLast().map(\.upperBound))
        for offset in 0...count where !wraps.contains(offset) {
            let caret = layout.caret(atOffset: offset)!
            #expect(layout.offset(at: caret.baseline, inContainer: 0) == offset)
        }
        // Past the end of a wrapped line: before its trailing space, not onto the next line.
        let firstLine = layout.lineRanges[0]
        let far = Point(x: 500, y: layout.lineOrigins[0].y)
        #expect(layout.offset(at: far, inContainer: 0) == firstLine.upperBound - 1)
        // Above the text: the first line; below it: the last.
        #expect(layout.offset(at: Point(x: -10, y: -50), inContainer: 0) == 0)
        #expect(layout.offset(at: Point(x: 500, y: 500), inContainer: 0) == count)
        // Anchors: before the character at the boundary, after the last at the end.
        #expect(layout.anchor(at: Point(x: -10, y: -50), inContainer: 0) == .before(layout.charID(at: 0)!))
        #expect(layout.anchor(at: Point(x: 500, y: 500), inContainer: 0) == .after(layout.charID(at: count - 1)!))
        #expect(layout.anchor(at: .zero, inContainer: 3) == nil)
        let empty = Fixture.layout("", in: [Fixture.block()])
        #expect(empty.anchor(at: .zero, inContainer: 0) == nil)
        #expect(empty.offset(at: .zero, inContainer: 0) == 0)
    }

    /// The layout of `text` with explicit ids.
    static func content(_ text: String, ids: [CharID]) -> TextContent {
        let paragraphs = text.unicodeScalars.filter { $0 == "\n" }.count + 1
        return TextContent(runs: [TextRun(text, attributes: Fixture.body)], paragraphs: Array(repeating: ParagraphStyle(), count: paragraphs), charIDs: ids)
    }

    static func ids(_ count: Int, replica: UInt64, from counter: UInt64) -> [CharID] {
        (0..<UInt64(count)).map { CharID(counter: counter + $0, replica: replica) }
    }

    @Test func caretsSurviveRemoteEdits() {
        let engine = TextLayoutEngine()
        let first = "First paragraph.\n"
        let second = "Second paragraph with my caret."
        var ids = CaretTests.ids((first + second).unicodeScalars.count, replica: CaretTests.replicaA, from: 1)
        let original = engine.layout(CaretTests.content(first + second, ids: ids), in: [Fixture.block(width: 400)])
        // My caret: before "my".
        let myOffset = (first + second).unicodeScalars.count - 9
        let mine = CharAnchor.before(ids[myOffset])
        let before = original.caret(for: mine)!

        // A collaborator types at the start of my paragraph: my caret moves right by exactly
        // the width of what they typed, and stays on its character.
        let typed = "Hey! "
        let typedIDs = CaretTests.ids(typed.unicodeScalars.count, replica: CaretTests.replicaB, from: 100)
        let insertAt = first.unicodeScalars.count
        ids.insert(contentsOf: typedIDs, at: insertAt)
        let text = first + typed + second
        let edited = engine.layout(CaretTests.content(text, ids: ids), in: [Fixture.block(width: 400)])
        let after = edited.caret(for: mine)!
        let typedWidth = TextLayoutEngine().layout(TextContent(typed, attributes: Fixture.body), in: [Fixture.block(width: 400)]).caret(atOffset: typed.unicodeScalars.count)!.baseline.x
        #expect(approx(after.baseline.x - before.baseline.x, typedWidth, 0.01))
        #expect(after.baseline.y == before.baseline.y)
        let myGlyph = edited.glyphs().first { $0.offset == edited.offset(of: ids[myOffset + typed.unicodeScalars.count])! }!
        #expect(approx(after.baseline.x, myGlyph.origin.x, 0.001))
        // The remote caret, at the end of what they typed, maps too.
        let theirs = edited.caret(for: .after(typedIDs.last!))!
        #expect(approx(theirs.baseline.x, typedWidth, 0.01))

        // They delete the first paragraph: my caret moves up a line, same x.
        let trimmedIDs = Array(ids.dropFirst(first.unicodeScalars.count))
        let trimmed = engine.layout(CaretTests.content(typed + second, ids: trimmedIDs), in: [Fixture.block(width: 400)])
        let moved = trimmed.caret(for: mine)!
        #expect(approx(moved.baseline.x, after.baseline.x, 0.001))
        #expect(moved.baseline.y < after.baseline.y)

        // They delete my character: the anchor is gone (the engine then gives its offset).
        var gone = trimmedIDs
        gone.remove(at: trimmedIDs.firstIndex(of: ids[myOffset + typed.unicodeScalars.count])!)
        var goneText = Array((typed + second).unicodeScalars)
        goneText.remove(at: trimmedIDs.firstIndex(of: ids[myOffset + typed.unicodeScalars.count])!)
        let deleted = engine.layout(CaretTests.content(String(String.UnicodeScalarView(goneText)), ids: gone), in: [Fixture.block(width: 400)])
        #expect(deleted.caret(for: mine) == nil)

        // A rewrap under the caret: narrower block, the caret follows its character.
        let narrow = engine.layout(CaretTests.content(text, ids: ids), in: [Fixture.block(width: 90)])
        let wrapped = narrow.caret(for: mine)!
        let glyph = narrow.glyphs().first { $0.offset == narrow.offset(of: ids[myOffset + typed.unicodeScalars.count])! }!
        #expect(approx(wrapped.baseline.x, glyph.origin.x, 0.001) && approx(wrapped.baseline.y, glyph.origin.y, 0.001))
    }

    @Test func idsAreNormalizedToTheText() {
        // Too few ids: the rest get synthetic ones; too many: the extra are dropped.
        let short = TextContent(runs: [TextRun("abc", attributes: Fixture.body)], paragraphs: [], charIDs: [CharID(counter: 7, replica: 1)])
        let layout = TextLayoutEngine().layout(short, in: [Fixture.block()])
        #expect(layout.charID(at: 0) == CharID(counter: 7, replica: 1))
        #expect(layout.charID(at: 2) == CharID(counter: 2, replica: .max))
        #expect(layout.charID(at: 3) == nil)
        #expect(layout.offset(of: CharID(counter: 2, replica: .max)) == 2)
        let long = TextContent(runs: [TextRun("a", attributes: Fixture.body)], charIDs: CaretTests.ids(5, replica: 1, from: 1))
        let longLayout = TextLayoutEngine().layout(long, in: [Fixture.block()])
        #expect(longLayout.offset(of: CharID(counter: 3, replica: 1)) == nil)
        // A duplicated id keeps its first offset.
        let duplicate = TextContent(runs: [TextRun("ab", attributes: Fixture.body)], charIDs: [CharID(counter: 1, replica: 1), CharID(counter: 1, replica: 1)])
        #expect(TextLayoutEngine().layout(duplicate, in: [Fixture.block()]).offset(of: CharID(counter: 1, replica: 1)) == 0)
    }

    @Test func surrogatePairsAreOneCharacter() {
        let text = "a😀b"
        let layout = Fixture.layout(text, in: [Fixture.block()])
        #expect(layout.characterCount == 3)
        let glyphs = layout.glyphs()
        #expect(glyphs.map(\.offset) == [0, 1, 2])
        #expect(approx(layout.caret(atOffset: 2)!.baseline.x, glyphs[2].origin.x, 0.001))
    }
}
