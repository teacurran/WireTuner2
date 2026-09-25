import AppKit
import WTCRDT
import WTModel

/// The Text Editor window (editing-text.adoc, "The Text Editor window"; TYPE-011): an `NSTextView`
/// bound both ways to one text node.  Local edits are refused by the view and performed as text
/// commands through the model; every document change reloads the storage and puts the selection
/// back from the session's anchors, so a collaborator typing in the same block (on the canvas or
/// in their own editor) never moves this window's selection off its characters.  The window
/// closes itself when the node is deleted.
@MainActor
final class TextEditorController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    let model: TextEditorModel
    let textView: NSTextView
    let presence: (any PresenceProviding)?
    private(set) var twelvePointBox: NSButton!
    private(set) var invisiblesBox: NSButton!
    private(set) var wrapBox: NSButton!
    private let caretOverlay = RemoteCaretView()
    private var observation: DocumentHandle.ObservationToken?
    private var presenceToken: UUID?
    /// While the storage is being replaced from the document, selection changes are not edits.
    private var reloading = false
    /// Called when the window closes (the registry forgets it).
    var onClose: (@MainActor () -> Void)?

    init(model: TextEditorModel, presence: (any PresenceProviding)? = nil) {
        self.model = model
        self.presence = presence
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320), textContainer: container)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("text-editor")
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        observation = model.document.observe { [weak self] _ in self?.documentDidChange() }
        presenceToken = presence?.observe { [weak self] in self?.updateRemoteCarets() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TextEditorController is built in code") }

    private func buildContent(in window: NSWindow) {
        twelvePointBox = NSButton(checkboxWithTitle: "12 point black", target: self, action: #selector(toggleTwelvePoint(_:)))
        invisiblesBox = NSButton(checkboxWithTitle: "Show invisibles", target: self, action: #selector(toggleInvisibles(_:)))
        wrapBox = NSButton(checkboxWithTitle: "Wrap to window", target: self, action: #selector(toggleWrap(_:)))
        twelvePointBox.setAccessibilityIdentifier("textEditor.twelvePoint")
        invisiblesBox.setAccessibilityIdentifier("textEditor.invisibles")
        wrapBox.setAccessibilityIdentifier("textEditor.wrap")
        let options = NSStackView(views: [twelvePointBox, invisiblesBox, wrapBox])
        options.orientation = .horizontal
        options.spacing = 16
        textView.delegate = self
        textView.isRichText = false
        // The editor's text is plain; the shared font and color panels have nothing to send it.
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("textEditor.text")
        textView.addSubview(caretOverlay)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let stack = NSStackView(views: [options, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        window.contentView = stack
        syncOptions()
    }

    /// Shows the window, frontmost.
    func show() {
        window?.title = model.title
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    // MARK: Options

    @objc func toggleTwelvePoint(_ sender: NSButton) {
        model.twelvePointBlack = sender.state == .on
        reload()
    }

    @objc func toggleInvisibles(_ sender: NSButton) {
        model.showInvisibles = sender.state == .on
        syncOptions()
    }

    @objc func toggleWrap(_ sender: NSButton) {
        model.wrapToWindow = sender.state == .on
        syncOptions()
    }

    /// The checkboxes, the invisibles and the wrapping follow the model.
    func syncOptions() {
        twelvePointBox.state = model.twelvePointBlack ? .on : .off
        invisiblesBox.state = model.showInvisibles ? .on : .off
        wrapBox.state = model.wrapToWindow ? .on : .off
        textView.layoutManager?.showsInvisibleCharacters = model.showInvisibles
        textView.layoutManager?.showsControlCharacters = model.showInvisibles
        let container = textView.textContainer
        container?.widthTracksTextView = model.wrapToWindow
        textView.isHorizontallyResizable = !model.wrapToWindow
        if !model.wrapToWindow {
            container?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count))
    }

    // MARK: Binding

    /// Replaces the storage with the node's text and puts the selection back from the anchors.
    func reload() {
        reloading = true
        defer { reloading = false }
        textView.textStorage?.setAttributedString(model.attributedString())
        let length = textView.string.utf16.count
        let range = model.selectedRange
        textView.setSelectedRange(NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
        window?.title = model.title
        updateRemoteCarets()
    }

    private func documentDidChange() {
        model.session.documentDidChange()
        guard model.isLive else {
            close()
            return
        }
        reload()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !reloading, let replacementString else { return false }
        model.replace(affectedCharRange, with: replacementString)
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !reloading else { return }
        model.select(textView.selectedRange())
    }

    /// The collaborators' carets and selections drawn over the text.
    func updateRemoteCarets() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        caretOverlay.frame = textView.bounds
        caretOverlay.marks = model.remoteMarks(presence?.participants ?? []).map { mark in
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: mark.range.location, length: max(mark.range.length, 0)), actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            if mark.range.length == 0 {
                let line = layout.extraLineFragmentRect.height > 0 && mark.range.location >= textView.string.utf16.count
                    ? layout.extraLineFragmentRect : rect
                rect = NSRect(x: rect.minX, y: line.minY, width: 2, height: max(line.height, 12))
            }
            return RemoteCaretView.Mark(rect: rect.offsetBy(dx: origin.x, dy: origin.y), color: mark.color, name: mark.name, isCaret: mark.range.length == 0)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        if let observation { model.document.stopObserving(observation) }
        observation = nil
        if let presenceToken { presence?.stopObserving(presenceToken) }
        presenceToken = nil
        onClose?()
        onClose = nil
    }
}

/// The collaborators' marks in the editor: a tinted range, or a caret with the name beside it.
final class RemoteCaretView: NSView {
    struct Mark: Equatable {
        var rect: NSRect
        var color: NSColor
        var name: String
        var isCaret: Bool
    }

    var marks: [Mark] = [] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            if mark.isCaret {
                mark.color.setFill()
                mark.rect.fill()
                let label = NSAttributedString(string: mark.name, attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: mark.color])
                label.draw(at: NSPoint(x: mark.rect.maxX + 2, y: mark.rect.minY - 10))
            } else {
                mark.color.withAlphaComponent(0.25).setFill()
                mark.rect.fill()
            }
        }
    }
}
