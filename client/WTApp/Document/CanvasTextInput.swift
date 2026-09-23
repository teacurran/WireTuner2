import AppKit
import WTGeometry

/// The canvas as a text input client (creating-text.adoc, "Client"; TYPE-003): while the Text
/// tool edits a block, keys go through `interpretKeyEvents`, and the input method's calls --
/// committed text, marked text, key-binding selectors, the ranges and rectangles it asks about --
/// are forwarded to the tool (`ToolManager.textInput`).  With no text being edited the canvas has
/// no input context and every call is a no-op.
extension CanvasView: @preconcurrency NSTextInputClient {
    override var inputContext: NSTextInputContext? {
        toolManager?.textInput == nil ? nil : super.inputContext
    }

    /// Hands `event` to the text system (`CanvasHost`); false when no text is being edited.
    func interpretKeys(_ event: NSEvent) -> Bool {
        guard toolManager?.textInput != nil, inputContext != nil else { return false }
        interpretKeyEvents([event])
        return true
    }

    static func string(_ value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        toolManager?.textInput?.insertText(Self.string(string), replacementRange: replacementRange.location == NSNotFound ? nil : replacementRange)
        setNeedsOverlayDisplay()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        toolManager?.textInput?.setMarkedText(Self.string(string), selectedRange: selectedRange)
        setNeedsOverlayDisplay()
    }

    func unmarkText() {
        toolManager?.textInput?.unmarkText()
        setNeedsOverlayDisplay()
    }

    override func doCommand(by selector: Selector) {
        // Unbound keys the text system reports are swallowed rather than beeping.
        toolManager?.textInput?.doCommand(NSStringFromSelector(selector))
        setNeedsOverlayDisplay()
    }

    func selectedRange() -> NSRange {
        toolManager?.textInput?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        toolManager?.textInput?.markedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        toolManager?.textInput?.hasMarkedText ?? false
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let (string, actual) = toolManager?.textInput?.attributedSubstring(range) else { return nil }
        actualRange?.pointee = actual
        return string
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The insertion point on screen, where the input method puts its candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let caret = toolManager?.textInput?.caretRect else { return .zero }
        return screenRect(ofPasteboardRect: caret)
    }

    /// A pasteboard rectangle in screen coordinates (through the view's y-up space and its window).
    func screenRect(ofPasteboardRect rect: Rect) -> NSRect {
        let view = rect.applying(viewport.pasteboardToView)
        let appKit = NSRect(x: view.minX, y: Double(bounds.height) - view.maxY, width: view.width, height: view.height)
        let inWindow = convert(appKit, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
