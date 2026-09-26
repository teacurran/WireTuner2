import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// kbd:[Control]-click suggestions on the canvas (editing-text.adoc, "Checking spelling"; the rest
/// of TYPE-014): with *Check spelling while typing* on, a secondary click on an underlined word of
/// the Text tool's block opens a menu with the word's guesses -- choosing one is one "Correct
/// spelling" change (`ReplaceText`) -- then *Ignore Spelling* and *Learn Spelling* (which write
/// nothing), then the text menu.  A click anywhere else gets the window's menu as before.
@MainActor
enum SpellingContextMenu {
    /// Runs a closure from a menu item.
    @MainActor final class Action: NSObject {
        let run: @MainActor () -> Void

        init(_ run: @escaping @MainActor () -> Void) {
            self.run = run
        }

        @objc func invoke(_ sender: Any?) { run() }
    }

    /// The issue under `viewPoint` in `window`'s Text tool block.
    static func issue(at viewPoint: Point, in window: DocumentWindowController) -> SpellingIssue? {
        guard window.canvas.toolManager?.textInput != nil, let session = window.objectEditing.textSession, session.isLive,
              let spelling = TypeWindowParts.parts(of: window)?.spelling else { return nil }
        let point = window.viewport.toPasteboard(viewPoint)
        guard session.contains(point, tolerance: 2) else { return nil }
        let offset = session.offset(at: point)
        return spelling.issues().first { $0.range.contains(offset) || ($0.range.upperBound == offset && offset > $0.range.lowerBound) }
    }

    /// The suggestions menu for a click at `viewPoint`, nil when it is not on an issue.
    static func menu(at viewPoint: Point, in window: DocumentWindowController, service: any SpellingService = SpellingFeatures.shared.model.service) -> NSMenu? {
        guard let issue = issue(at: viewPoint, in: window) else { return nil }
        let menu = NSMenu(title: "Spelling")
        let guesses: [String] = if let suggestion = issue.suggestion { [suggestion] } else { service.guesses(for: issue.word, language: issue.language) }
        for guess in guesses.prefix(8) {
            menu.addItem(item(guess.isEmpty ? "Delete Repeated Word" : guess, identifier: "spelling.guess") { correct(issue, with: guess, in: window) })
        }
        if guesses.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(item("Ignore Spelling", identifier: "spelling.ignore") {
            (service as? SystemSpellingService)?.ignore(issue.word)
            window.canvas.setNeedsOverlayDisplay()
        })
        menu.addItem(item("Learn Spelling", identifier: "spelling.learn") {
            service.learn(SpellingFeatures.shared.model.checker.learnedForm(issue.word))
            window.canvas.setNeedsOverlayDisplay()
        })
        menu.addItem(.separator())
        let rest = window.contextMenu(for: .textEditing)
        for entry in rest.items {
            rest.removeItem(entry)
            menu.addItem(entry)
        }
        return menu
    }

    static func item(_ title: String, identifier: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.invoke(_:)), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    /// The correction: one "Correct spelling" change over the word.
    @discardableResult
    static func correct(_ issue: SpellingIssue, with correction: String, in window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let text = window.documentHandle.state.textNode(issue.node), issue.range.upperBound <= text.length, !issue.range.isEmpty else { return nil }
        let match = TextMatch(node: issue.node, range: issue.range, first: text.chars[issue.range.lowerBound], last: text.chars[issue.range.upperBound - 1])
        return window.objectEditing.perform(ReplaceText([match], with: correction, label: ReplaceText.correctSpelling))
    }
}
