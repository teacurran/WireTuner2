import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// TYPE-016 on text on a path: a collaborator's caret stands across the path at its character,
/// leaning with the glyph, and their selection tints the glyphs along the curve.
@Suite(.serialized) @MainActor struct RemoteCaretsOnPathTests {
    @Test func aRemoteCaretOnAVerticalPathLiesAcrossIt() async throws {
        let document = DocumentHandle.memory(title: "Path carets")
        let text = try #require(await document.addText("Hello path", at: Point(x: 40, y: 40)))
        let path = try #require(await document.addPath([Point(x: 200, y: 20), Point(x: 200, y: 380)]))
        _ = await document.perform(AttachTextToPath(text: text, path: path.opID)).value
        await document.settle()
        #expect(TextOnPathMenu.isOnPath(text, in: document.state))
        let chars = try #require(document.state.textNode(text)).chars
        let viewport = Viewport(size: Size(width: 400, height: 400))
        let overlay = PresenceOverlay(document: document, viewport: viewport)
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1)
        priya.caret = RemoteCaret(node: SelectionID(text), position: chars[3])
        let caret = try #require(overlay.carets([priya]).first)
        // The glyphs run down the path, so the caret's ends differ across it, not along it.
        #expect(abs(caret.top.x - caret.bottom.x) > 5 && abs(caret.top.y - caret.bottom.y) < 1)
        #expect(caret.rect.minX <= min(caret.top.x, caret.bottom.x) + 0.01 && caret.rect.width >= abs(caret.top.x - caret.bottom.x) - 0.01)
        let midX = (caret.top.x + caret.bottom.x) / 2
        // Across the glyphs as drawn: within the block's painted bounds, which follow the path.
        let bounds = try #require(document.object(for: SelectionID(text))?.bounds).applying(viewport.pasteboardToView)
        #expect(midX >= bounds.minX - 2 && midX <= bounds.maxX + 2 && bounds.height > bounds.width, "on the vertical path")
        // Further along the text is further down the path.
        priya.caret = RemoteCaret(node: SelectionID(text), position: chars[6])
        let later = try #require(overlay.carets([priya]).first)
        #expect(later.top.y > caret.top.y)
        // A range tints each glyph along the path.
        priya.caret = RemoteCaret(node: SelectionID(text), position: chars[0], rangeEnd: chars[4])
        #expect(overlay.textSelections([priya]).count == 4)
        overlay.draw(in: TextToolTests.context(), participants: [priya], options: PresenceDisplayOptions(), clock: CursorLabelClock())
    }
}
