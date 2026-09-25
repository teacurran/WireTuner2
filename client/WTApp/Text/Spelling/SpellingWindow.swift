import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Spelling window's model (editing-text.adoc, "Checking spelling"; TYPE-014): the issue shown
/// now -- highlighted on the canvas as the Text tool's selection -- its guesses and the correction
/// typed, and the buttons.  btn:[Change] is one change ("Correct spelling", `ReplaceText`);
/// btn:[Ignore], btn:[Learn] and btn:[Unlearn] never write to the document.
@MainActor
@Observable
final class SpellingModel {
    @ObservationIgnored let service: any SpellingService
    @ObservationIgnored var options: @MainActor () -> SpellingOptions
    private(set) var current: SpellingIssue?
    private(set) var guesses: [String] = []
    var correction = ""
    private(set) var message: String?
    /// Words ignored for the document (per checking session).
    @ObservationIgnored private var ignored: Set<String> = []

    init(service: any SpellingService, options: @escaping @MainActor () -> SpellingOptions = { SpellingOptions() }) {
        self.service = service
        self.options = options
    }

    var checker: SpellingChecker { SpellingChecker(service: service, options: options()) }

    /// Where the check runs: the Text tool's range, the selected blocks, or the whole document.
    func region(in window: DocumentWindowController) -> [(node: OpID, range: Range<Int>?)] {
        let state = window.documentHandle.state
        if let session = window.objectEditing.textSession, let node = session.node, !session.selectedRange.isEmpty,
           current.map({ $0.node == node && $0.range == session.selectedRange }) != true {
            return [(node, session.selectedRange)]
        }
        let selected = window.selection.selection.ids.map(\.opID)
        let nodes = selected.isEmpty ? TextFinder.nodes(in: state) : TextFinder.nodes(in: state, within: selected)
        return nodes.map { ($0, nil) }
    }

    /// Every issue of the region, in document order, ignored words left out.
    func issues(in window: DocumentWindowController) -> [SpellingIssue] {
        let state = window.documentHandle.state
        let checker = checker
        let texts = region(in: window).compactMap { entry in state.textNode(entry.node).map { ($0, entry.range) } }
        return texts.flatMap { text, range in checker.issues(in: text, within: range).filter { !ignored.contains($0.word) } }
    }

    /// btn:[Find Next] (and opening the window): the next issue after the current one.
    @discardableResult
    func findNext(in window: DocumentWindowController) -> SpellingIssue? {
        let all = issues(in: window)
        let order = TextFinder.nodes(in: window.documentHandle.state)
        let position = current.map { (Self.rank($0.node, in: order), $0.range.upperBound) }
        var next = all.first { issue in
            guard let position else { return true }
            return (Self.rank(issue.node, in: order), issue.range.lowerBound) >= position
        }
        // Past the last issue, the check wraps to the first.
        if next == nil { next = all.first }
        current = next
        guard let next else {
            guesses = []
            correction = ""
            message = "No spelling problems found"
            return nil
        }
        message = next.message
        guesses = next.suggestion.map { [$0] } ?? service.guesses(for: next.word, language: next.language)
        correction = guesses.first ?? next.word
        window.editText(next.node, at: .zero)
        window.objectEditing.textSession?.select(anchor: next.range.lowerBound, focus: next.range.upperBound)
        return next
    }

    /// Where `node` stands in the document's order (unknown nodes last).
    static func rank(_ node: OpID, in order: [OpID]) -> Int {
        order.firstIndex(of: node) ?? order.count
    }

    /// btn:[Change]: the current word becomes the correction, one change, then the next issue.
    @discardableResult
    func change(in window: DocumentWindowController) -> Task<Void, Never>? {
        guard let issue = current, let text = window.documentHandle.state.textNode(issue.node), issue.range.upperBound <= text.length else { return nil }
        let match = TextMatch(node: issue.node, range: issue.range, first: text.chars[issue.range.lowerBound], last: text.chars[issue.range.upperBound - 1])
        let task = window.objectEditing.perform(ReplaceText([match], with: correction, label: ReplaceText.correctSpelling))
        return Task { @MainActor in
            _ = await task.value
            self.current = nil
            self.findNext(in: window)
        }
    }

    /// btn:[Ignore]: the word is skipped for this document.
    func ignore(in window: DocumentWindowController) {
        guard let issue = current else { return }
        ignored.insert(issue.word)
        (service as? SystemSpellingService)?.ignore(issue.word)
        findNext(in: window)
    }

    /// btn:[Learn]: into the user dictionary (as typed, or in lowercase).
    func learn(in window: DocumentWindowController) {
        guard let issue = current else { return }
        service.learn(checker.learnedForm(issue.word))
        findNext(in: window)
    }

    /// btn:[Unlearn]: out of the user dictionary.
    func unlearn() {
        guard let issue = current else { return }
        service.unlearn(checker.learnedForm(issue.word))
    }
}

/// The Spelling window's body.
struct SpellingView: View {
    @Bindable var model: SpellingModel
    let window: @MainActor () -> DocumentWindowController?

    static func change(_ model: SpellingModel, _ window: DocumentWindowController) { model.change(in: window) }
    static func ignore(_ model: SpellingModel, _ window: DocumentWindowController) { model.ignore(in: window) }
    static func learn(_ model: SpellingModel, _ window: DocumentWindowController) { model.learn(in: window) }
    static func findNext(_ model: SpellingModel, _ window: DocumentWindowController) { model.findNext(in: window) }

    /// The guesses list's selection: the correction.
    static func selection(_ model: SpellingModel) -> Binding<String?> {
        Binding(get: { Optional(model.correction) }, set: { if let chosen = $0 { model.correction = chosen } })
    }

    static func acting(_ action: @escaping @MainActor (SpellingModel, DocumentWindowController) -> Void, _ model: SpellingModel,
                       _ window: @escaping @MainActor () -> DocumentWindowController?) -> () -> Void {
        { if let front = window() { action(model, front) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.message ?? "").font(.callout).accessibilityIdentifier("spelling.message")
            TextField("Change to", text: $model.correction).accessibilityIdentifier("spelling.correction")
            List(model.guesses, id: \.self, selection: Self.selection(model)) {
                Text($0)
            }
            .frame(height: 100)
            .accessibilityIdentifier("spelling.guesses")
            HStack {
                Button("Change", action: Self.acting(Self.change, model, window)).accessibilityIdentifier("spelling.change")
                Button("Ignore", action: Self.acting(Self.ignore, model, window)).accessibilityIdentifier("spelling.ignore")
                Button("Learn", action: Self.acting(Self.learn, model, window)).accessibilityIdentifier("spelling.learn")
                Button("Unlearn", action: model.unlearn).accessibilityIdentifier("spelling.unlearn")
                Spacer()
                Button("Find Next", action: Self.acting(Self.findNext, model, window)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("spelling.findNext")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// menu:Text[Spelling…] (kbd:[Cmd+;]) and menu:Text[Spelling > Check Spelling While Typing].
@MainActor
final class SpellingFeatures {
    static let shared = SpellingFeatures()

    let model: SpellingModel
    private(set) var panel: NSPanel?

    init(service: any SpellingService = SystemSpellingService()) {
        model = SpellingModel(service: service)
    }

    @discardableResult
    func show(window: @escaping @MainActor () -> DocumentWindowController?, ordersFront: Bool = true) -> NSPanel {
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260), styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: true)
            panel.title = "Spelling"
            panel.identifier = NSUserInterfaceItemIdentifier("spelling")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.contentViewController = NSHostingController(rootView: SpellingView(model: model, window: window))
            return panel
        }()
        self.panel = panel
        if ordersFront { panel.makeKeyAndOrderFront(nil) }
        if let front = window() { model.findNext(in: front) }
        return panel
    }

    func commands(window: @escaping @MainActor () -> DocumentWindowController?, preferences: PreferenceStore) -> [Command] {
        model.options = { SpellingOptions(preferences: preferences) }
        let noDocument: @MainActor @Sendable () -> CommandValidation = { window() == nil ? .disabled(BlendMenu.noDocument) : .enabled }
        let text = ContextMenuCatalog.Menu.text
        let show: CommandAction = .perform { [weak self] in self?.show(window: window) }
        return [
            Command(id: ContextMenuCatalog.ID.spelling, title: "Spelling…", key: KeyEquivalent(";", .command), menu: MenuPath(text, section: 3),
                    contexts: [.text], keywords: ["spell", "check"], validation: noDocument, action: show),
            Command(id: ContextMenuCatalog.ID.checkSpelling("check"), title: "Check Spelling…", menu: MenuPath(text, "Spelling", section: 3),
                    keywords: ["spell"], validation: noDocument, action: show),
            Command(id: ContextMenuCatalog.ID.checkSpelling("whileTyping"), title: "Check Spelling While Typing", menu: MenuPath(text, "Spelling", section: 3),
                    keywords: ["spell"], validation: { .checked(preferences[PreferenceCatalog.Spelling.checkWhileTyping]) },
                    action: .perform { _ = preferences.set(!preferences[PreferenceCatalog.Spelling.checkWhileTyping], for: PreferenceCatalog.Spelling.checkWhileTyping) }),
        ]
    }
}
