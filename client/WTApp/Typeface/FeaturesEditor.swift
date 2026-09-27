import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The Features editor's model (opentype-features.adoc, "The Features editor"; FONT-022): the
/// document's feature file as `FeatureFileText`, the checker's report against the font
/// (`FeatureFileContext`), run 300 ms after the last change and at once with btn:[Check], and the
/// generated text for the *Generated* pane.  Edits are `EditFeatureFile` changes built from the
/// characters the view showed; the selection is held as the characters its ends are before, so a
/// collaborator's typing elsewhere never moves it.  Offsets the view speaks are UTF-16.
@MainActor
final class FeaturesEditorModel {
    let document: DocumentHandle
    private(set) var text: FeatureFileText
    private(set) var context: FeatureFileContext
    private(set) var report: FeatureChecker.Report
    /// The last time the report was brought up to date (the live check's clock).
    private(set) var checkedAt: ContinuousClock.Instant?
    /// How long after the last change the live check runs.
    var checkDelay: Duration = .milliseconds(300)
    /// Called after every check (the window repaints the underlines and the strip).
    var didCheck: (@MainActor () -> Void)?
    private var pendingCheck: Task<Void, Never>?
    /// The selection's ends: the characters they are before (zero: the end).
    private(set) var selectionStart: OpID = .zero
    private(set) var selectionEnd: OpID = .zero

    init(document: DocumentHandle) {
        self.document = document
        let state = document.state
        text = FeatureFileText(state)
        context = FeatureFileContext(state)
        report = context.check(text.string)
    }

    var scalars: [Unicode.Scalar] { Array(text.string.unicodeScalars) }

    /// The UTF-16 range of the scalars `range`.
    func utf16Range(_ range: Range<Int>) -> NSRange {
        let all = scalars
        let lower = TextNavigation.utf16Offset(range.lowerBound, in: all)
        return NSRange(location: lower, length: TextNavigation.utf16Offset(range.upperBound, in: all) - lower)
    }

    // MARK: Reading

    /// Reads the text again after a change; true when it changed.  The check follows.
    @discardableResult
    func reload() -> Bool {
        let fresh = FeatureFileText(document.state)
        let changed = fresh != text
        text = fresh
        scheduleCheck()
        return changed
    }

    /// The live check: `checkDelay` after the last call.
    func scheduleCheck() {
        pendingCheck?.cancel()
        let delay = checkDelay
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    /// btn:[Check]: the font's names and generated features read again, the text checked now.
    func check() {
        pendingCheck?.cancel()
        pendingCheck = nil
        let state = document.state
        text = FeatureFileText(state)
        context = FeatureFileContext(state)
        report = context.check(text.string)
        checkedAt = .now
        didCheck?()
    }

    /// "No problems", or the count of errors and warnings.
    var summary: String {
        let errors = report.errors.count
        let warnings = report.issues.count - errors
        guard errors + warnings > 0 else { return "No problems" }
        let parts = [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil, warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// The coloured spans, UTF-16.
    func spans() -> [(range: NSRange, kind: FeatureSpan.Kind)] {
        FeatureEditing.spans(text.string).map { (utf16Range($0.range), $0.kind) }
    }

    /// The red underlines: unknown glyph and class names, with the tooltip (the nearest glyph name).
    func underlines() -> [(range: NSRange, tooltip: String)] {
        report.issues.compactMap { issue in
            FeatureEditing.underline(issue, in: text.string).map { range in
                (utf16Range(range), issue.suggestion.map { "\(issue.message) Nearest: \($0)" } ?? issue.message)
            }
        }
    }

    /// The line of `issue`, UTF-16 (what clicking it in the strip selects).
    func lineRange(of issue: FeatureIssue) -> NSRange? {
        FeatureEditing.lineRange(issue.location.line, in: text.string).map(utf16Range)
    }

    /// The bracket matching the one at the caret, UTF-16.
    func matchingBracket(caret: Int) -> NSRange? {
        let offset = TextNavigation.scalarOffset(caret, in: scalars)
        return FeatureEditing.matchingBracket(in: text.string, caret: offset).map { utf16Range($0..<($0 + 1)) }
    }

    /// Control-Space at `caret`: the partial name's range and the names that complete it; nil
    /// outside a `sub` or `pos` rule.
    func completions(caret: Int) -> (range: NSRange, names: [String])? {
        let offset = TextNavigation.scalarOffset(caret, in: scalars)
        guard let (prefix, start) = FeatureEditing.completionPrefix(in: text.string, caret: offset) else { return nil }
        return (utf16Range(start..<offset), FeatureEditing.completions(for: prefix, glyphs: context.glyphs, text: text.string))
    }

    // MARK: Selection and editing

    /// The selection, UTF-16, as its characters read now.
    var selectedRange: NSRange {
        let state = document.state
        let start = text.offset(of: selectionStart, in: state) ?? text.count
        let end = text.offset(of: selectionEnd, in: state) ?? text.count
        return utf16Range(min(start, end)..<max(start, end))
    }

    /// The view's selection changed.
    func select(_ range: NSRange) {
        let scalarRange = TextNavigation.scalarRange(range, in: scalars)
        selectionStart = text.char(at: scalarRange.lowerBound)
        selectionEnd = text.char(at: scalarRange.upperBound)
    }

    /// Replaces `range` (UTF-16, as the view showed the text) with `string`; the caret goes after
    /// the new text.  A keystroke (`typing`) joins the word's undo step.
    @discardableResult
    func replace(_ range: NSRange, with string: String, typing: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        let scalarRange = TextNavigation.scalarRange(range, in: scalars)
        let edit = text.edit(replacing: scalarRange, with: string, typing: typing)
        selectionStart = edit.before
        selectionEnd = edit.before
        return document.perform(edit)
    }

    /// Replaces the selection with `string` (a completion, inserted classes).
    @discardableResult
    func insert(_ string: String) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        replace(selectedRange, with: string, typing: false)
    }

    /// *Insert Class from Suffix…*: the two classes at the caret, or false when no glyph has a
    /// variant with the suffix.
    @discardableResult
    func insertClasses(suffix: String) -> Bool {
        guard let classes = FeatureEditing.classesFromSuffix(suffix, glyphs: context.glyphs) else { return false }
        insert(classes)
        return true
    }

    // MARK: Collaborators

    /// This person's caret for presence: the feature text of the settings node.
    var presenceCaret: PresenceCaret {
        PresenceCaret(node: WellKnown.settings, text: FontFields.features, position: selectionEnd,
                      rangeEnd: selectionStart == selectionEnd ? nil : selectionStart)
    }

    /// The collaborators' carets and selections in the feature file.
    func remoteMarks(_ participants: [RemoteParticipant]) -> [TextEditorModel.RemoteMark] {
        let state = document.state
        return participants.compactMap { participant in
            guard let caret = participant.caret, caret.node.opID == WellKnown.settings, caret.text == FontFields.features,
                  let offset = text.offset(of: caret.position, in: state) else { return nil }
            let other = caret.rangeEnd.flatMap { text.offset(of: $0, in: state) } ?? offset
            return TextEditorModel.RemoteMark(range: utf16Range(min(offset, other)..<max(offset, other)),
                                              color: NSColor(cgColor: participant.color.cgColor) ?? .systemBlue, name: participant.name)
        }
    }
}

/// The editor's text view: Control-Space asks for completions.
final class FeatureTextView: NSTextView {
    var complete: (@MainActor () -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " " {
            complete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Line numbers beside the feature text.
final class FeatureLineNumbers: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("FeatureLineNumbers is built in code") }

    /// The line number and the top of each line fragment that starts a line, in the text view's
    /// coordinates.
    func lineTops() -> [(line: Int, y: CGFloat)] {
        guard let textView, let layout = textView.layoutManager else { return [] }
        let string = textView.string as NSString
        guard layout.numberOfGlyphs > 0 else { return [(1, textView.textContainerOrigin.y)] }
        var result: [(Int, CGFloat)] = []
        var index = 0
        var line = 1
        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            result.append((line, layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y))
            line += 1
            index = NSMaxRange(lineRange)
        }
        if string.hasSuffix("\n") {
            result.append((line, layout.extraLineFragmentRect.minY + textView.textContainerOrigin.y))
        }
        return result
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        for (line, y) in lineTops() {
            let label = NSAttributedString(string: "\(line)", attributes: attributes)
            let point = convert(NSPoint(x: 0, y: y), from: textView)
            guard point.y > rect.minY - 20, point.y < rect.maxY + 20 else { continue }
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - 4, y: point.y + 1))
        }
    }
}

/// The Features editor window (menu:Window[Features]): the feature file with line numbers,
/// syntax colours, bracket matching, red underlines under unknown names, collaborators' carets,
/// btn:[Check] (kbd:[Cmd+K]), btn:[Insert Class from Suffix…], the error strip (a click selects the
/// line) and the read-only *Generated* pane with its disclosure button.
@MainActor
final class FeaturesEditorController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    let model: FeaturesEditorModel
    let presence: (any PresenceProviding)?
    /// Publishes this person's caret (the document window's presence publisher).
    var publishCaret: @MainActor (PresenceCaret?) -> Void
    let textView = FeatureTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    let generatedView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 160))
    private(set) var checkButton: NSButton!
    private(set) var suffixButton: NSButton!
    private(set) var disclosure: NSButton!
    private(set) var summaryLabel: NSTextField!
    private(set) var strip: NSStackView!
    private(set) var generatedScroll: NSScrollView!
    private(set) var lineNumbers: FeatureLineNumbers!
    private let caretOverlay = RemoteCaretView()
    private var observation: DocumentHandle.ObservationToken?
    private var presenceToken: UUID?
    private var reloading = false
    /// The bracket highlighted beside the caret.
    private(set) var highlightedBracket: NSRange?
    /// Shows the completion menu (replaced in tests): the names and where to put the chosen one.
    var showCompletions: @MainActor ([String], NSRange) -> Void = { _, _ in }
    /// Asks for the suffix (the sheet; replaced in tests).
    var presentSuffixSheet: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?

    init(model: FeaturesEditorModel, showGenerated: Bool, presence: (any PresenceProviding)? = nil,
         publishCaret: @escaping @MainActor (PresenceCaret?) -> Void = { _ in }) {
        self.model = model
        self.presence = presence
        self.publishCaret = publishCaret
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("typeface.features")
        window.title = "Features — \(model.document.title)"
        super.init(window: window)
        window.delegate = self
        buildContent(in: window, showGenerated: showGenerated)
        showCompletions = { [weak self] names, range in self?.popUpCompletions(names, replacing: range) }
        model.didCheck = { [weak self] in self?.refreshChecks() }
        observation = model.document.observe { [weak self] _ in self?.documentDidChange() }
        presenceToken = presence?.observe { [weak self] in self?.updateRemoteCarets() }
        reload()
        refreshChecks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("FeaturesEditorController is built in code") }

    private func buildContent(in window: NSWindow, showGenerated: Bool) {
        checkButton = NSButton(title: "Check", target: self, action: #selector(check(_:)))
        checkButton.keyEquivalent = "k"
        checkButton.keyEquivalentModifierMask = .command
        checkButton.setAccessibilityIdentifier("features.check")
        suffixButton = NSButton(title: "Insert Class from Suffix…", target: self, action: #selector(insertClassFromSuffix(_:)))
        suffixButton.setAccessibilityIdentifier("features.suffix")
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.setAccessibilityIdentifier("features.summary")
        let bar = NSStackView(views: [checkButton, suffixButton, summaryLabel])
        bar.orientation = .horizontal

        textView.delegate = self
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("features.text")
        textView.addSubview(caretOverlay)
        textView.complete = { [weak self] in self?.complete() }
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        lineNumbers = FeatureLineNumbers(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = lineNumbers
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        strip = NSStackView()
        strip.orientation = .vertical
        strip.alignment = .leading
        strip.spacing = 2
        strip.setAccessibilityIdentifier("features.errors")
        let stripScroll = NSScrollView()
        stripScroll.documentView = strip
        stripScroll.hasVerticalScroller = true
        stripScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        disclosure = NSButton(title: "Generated features", target: self, action: #selector(toggleGenerated(_:)))
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.imagePosition = .imageLeading
        disclosure.state = showGenerated ? .on : .off
        disclosure.setAccessibilityIdentifier("features.generatedToggle")
        generatedView.isEditable = false
        generatedView.isRichText = false
        generatedView.font = Self.font
        generatedView.textColor = .secondaryLabelColor
        generatedView.isVerticallyResizable = true
        generatedView.autoresizingMask = [.width]
        generatedView.setAccessibilityIdentifier("features.generated")
        generatedScroll = NSScrollView()
        generatedScroll.documentView = generatedView
        generatedScroll.hasVerticalScroller = true
        generatedScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        generatedScroll.isHidden = !showGenerated

        let stack = NSStackView(views: [bar, scroll, stripScroll, disclosure, generatedScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for view in [scroll, stripScroll, generatedScroll!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
    }

    /// Shows the window, frontmost.
    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    // MARK: Binding

    /// Replaces the storage with the feature text, restyles it and puts the selection back.
    func reload() {
        reloading = true
        defer { reloading = false }
        textView.textStorage?.setAttributedString(NSAttributedString(string: model.text.string, attributes: [.font: Self.font]))
        restyle()
        let length = textView.string.utf16.count
        let range = model.selectedRange
        textView.setSelectedRange(NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location))))
        highlightBracket()
        lineNumbers.needsDisplay = true
        updateRemoteCarets()
    }

    private func documentDidChange() {
        if model.reload() { reload() }
    }

    /// The syntax colours and the underlines over the plain text.
    func restyle() {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.textColor], range: whole)
        for (range, kind) in model.spans() where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: Self.color(kind), range: range)
        }
        for (range, tooltip) in model.underlines() where NSMaxRange(range) <= storage.length {
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.systemRed, .toolTip: tooltip], range: range)
        }
        storage.endEditing()
    }

    static func color(_ kind: FeatureSpan.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .tag: .systemPurple
        case .glyph: .textColor
        case .className: .systemTeal
        case .number: .systemBlue
        case .string: .systemRed
        case .comment: .systemGreen
        }
    }

    /// After a check: the underlines, the summary, the error strip and the generated pane.
    func refreshChecks() {
        if textView.string != model.text.string { reload() } else { restyle() }
        summaryLabel.stringValue = model.summary
        for view in strip.arrangedSubviews {
            strip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, issue) in model.report.issues.enumerated() {
            let prefix = issue.severity == .error ? "Error" : "Warning"
            let button = NSButton(title: "\(prefix), line \(issue.location.line):\(issue.location.column): \(issue.message)", target: self,
                                  action: #selector(selectIssue(_:)))
            button.isBordered = false
            button.alignment = .left
            button.tag = index
            button.contentTintColor = issue.severity == .error ? .systemRed : .systemOrange
            strip.addArrangedSubview(button)
        }
        if generatedView.string != model.context.generated { generatedView.string = model.context.generated }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !reloading, let replacementString else { return false }
        model.replace(affectedCharRange, with: replacementString, typing: replacementString.unicodeScalars.count <= 1)
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !reloading else { return }
        model.select(textView.selectedRange())
        highlightBracket()
        publishCaret(model.presenceCaret)
    }

    /// The bracket matching the one at the caret gets a tinted background.
    func highlightBracket() {
        guard let layout = textView.layoutManager else { return }
        if let previous = highlightedBracket, NSMaxRange(previous) <= textView.string.utf16.count {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
        }
        highlightedBracket = nil
        let selection = textView.selectedRange()
        guard selection.length == 0, let match = model.matchingBracket(caret: selection.location) else { return }
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), forCharacterRange: match)
        highlightedBracket = match
    }

    // MARK: Actions

    @objc func check(_ sender: Any?) {
        model.check()
    }

    @objc func toggleGenerated(_ sender: Any?) {
        generatedScroll.isHidden = disclosure.state != .on
    }

    @objc func selectIssue(_ sender: NSButton) {
        guard sender.tag < model.report.issues.count else { return }
        select(model.report.issues[sender.tag])
    }

    /// Selects the line of `issue` (a click in the error strip).
    func select(_ issue: FeatureIssue) {
        guard let range = model.lineRange(of: issue) else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        model.select(range)
        window?.makeFirstResponder(textView)
    }

    @objc func insertClassFromSuffix(_ sender: Any?) {
        presentSuffixSheet?()
    }

    /// Control-Space: one completion is inserted, several are offered.
    func complete() {
        guard let (range, names) = model.completions(caret: textView.selectedRange().location), !names.isEmpty else {
            NSSound.beep()
            return
        }
        if names.count == 1 {
            model.replace(range, with: names[0], typing: false)
        } else {
            showCompletions(names, range)
        }
    }

    /// The completion menu at the caret.
    private func popUpCompletions(_ names: [String], replacing range: NSRange) {
        let menu = NSMenu()
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(chooseCompletion(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CompletionChoice(name: name, range: range)
            menu.addItem(item)
        }
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let point = window.map { $0.convertPoint(fromScreen: rect.origin) } ?? .zero
        menu.popUp(positioning: nil, at: textView.convert(point, from: nil), in: textView)
    }

    final class CompletionChoice: NSObject {
        let name: String
        let range: NSRange

        init(name: String, range: NSRange) {
            self.name = name
            self.range = range
        }
    }

    @objc func chooseCompletion(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? CompletionChoice else { return }
        model.replace(choice.range, with: choice.name, typing: false)
    }

    /// The collaborators' carets and selections drawn over the text.
    func updateRemoteCarets() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        caretOverlay.frame = textView.bounds
        caretOverlay.marks = model.remoteMarks(presence?.participants ?? []).map { mark in
            let glyphs = layout.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            if mark.range.length == 0 {
                let line = layout.extraLineFragmentRect.height > 0 && mark.range.location >= textView.string.utf16.count
                    ? layout.extraLineFragmentRect : rect
                rect = NSRect(x: rect.minX, y: line.minY, width: 2, height: max(line.height, 12))
            }
            return RemoteCaretView.Mark(rect: rect.offsetBy(dx: origin.x, dy: origin.y), color: mark.color, name: mark.name, isCaret: mark.range.length == 0)
        }
    }

    var remoteMarks: [RemoteCaretView.Mark] { caretOverlay.marks }

    func windowWillClose(_ notification: Notification) {
        publishCaret(nil)
        if let observation { model.document.stopObserving(observation) }
        observation = nil
        if let presenceToken { presence?.stopObserving(presenceToken) }
        presenceToken = nil
        onClose?()
        onClose = nil
    }
}

// MARK: Insert Class from Suffix

/// The *Insert Class from Suffix…* sheet: a suffix, then btn:[Insert].
@MainActor
@Observable
final class ClassFromSuffixModel {
    var suffix = ".sc"
    private(set) var problem: String?
    @ObservationIgnored let insert: @MainActor (String) -> Bool

    init(insert: @escaping @MainActor (String) -> Bool) {
        self.insert = insert
    }

    /// btn:[Insert].
    func commit() -> Bool {
        guard insert(suffix) else {
            problem = "No glyph has a variant ending “\(suffix)”."
            return false
        }
        return true
    }
}

struct ClassFromSuffixSheet: View {
    @Bindable var model: ClassFromSuffixModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Class from Suffix").font(.headline)
            TextField("Suffix", text: $model.suffix).accessibilityIdentifier("classFromSuffix.suffix")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Insert", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("classFromSuffix.insert")
            }
        }
        .padding()
        .frame(width: 320)
    }
}
