import AppKit
import Observation
import WTCRDT
import WTModel
import WTProto

/// The Find and Replace Text window's model (editing-text.adoc, "Finding and replacing text";
/// TYPE-013): the fields and options, the search over the front window's text (`TextFinder`),
/// the current match shown as the Text tool's selection on the canvas, and the replacements --
/// each one change of `ReplaceText`.
@MainActor
@Observable
final class FindTextModel {
    enum Scope: String, CaseIterable, Identifiable {
        case selection, document
        var id: String { rawValue }
        var title: String { self == .selection ? "Selection" : "Document" }
    }

    /// The *Special* pop-up: the characters a field can insert.
    static let specials: [(title: String, character: String)] = [
        ("Tab", "\t"), ("Paragraph end", "\n"), ("End of line", "\u{2028}"), ("End of column", "\u{0C}"),
        ("Non-breaking space", "\u{00A0}"), ("Em space", "\u{2003}"), ("En space", "\u{2002}"), ("Thin space", "\u{2009}"),
        ("Em dash", "\u{2014}"), ("En dash", "\u{2013}"), ("Discretionary hyphen", "\u{00AD}"),
    ]

    var find = "" {
        didSet { if find.unicodeScalars.count > TextSearch.limit { find = String(String.UnicodeScalarView(find.unicodeScalars.prefix(TextSearch.limit))) } }
    }
    var replacement = "" {
        didSet {
            if replacement.unicodeScalars.count > TextSearch.limit {
                replacement = String(String.UnicodeScalarView(replacement.unicodeScalars.prefix(TextSearch.limit)))
            }
        }
    }
    var wholeWord = false
    var matchCase = false
    var scope = Scope.document
    /// The match shown now.
    private(set) var current: TextMatch?
    /// What the window reports ("3 replaced", "Not found").
    private(set) var message: String?

    init() {}

    var search: TextSearch { TextSearch(find, wholeWord: wholeWord, matchCase: matchCase) }

    /// Inserts a special character into *Find* or *Replace with*.
    func insertSpecial(_ character: String, intoReplacement: Bool) {
        if intoReplacement { replacement += character } else { find += character }
    }

    /// Where the search runs in `window`: the nodes and, for a Text tool range, the range.
    func region(in window: DocumentWindowController) -> (nodes: [OpID], range: (node: OpID, range: Range<Int>)?) {
        let state = window.documentHandle.state
        guard scope == .selection else { return (TextFinder.nodes(in: state), nil) }
        if let session = window.objectEditing.textSession, let node = session.node, !session.selectedRange.isEmpty,
           current.map({ $0.node == node && $0.range == session.selectedRange }) != true {
            return ([node], (node, session.selectedRange))
        }
        let selected = window.selection.selection.ids.map(\.opID)
        return (selected.isEmpty ? [] : TextFinder.nodes(in: state, within: selected), nil)
    }

    /// Every match of the region, in document order.
    func matches(in window: DocumentWindowController) -> [TextMatch] {
        let state = window.documentHandle.state
        let (nodes, range) = region(in: window)
        return nodes.compactMap { state.textNode($0) }.flatMap { text in
            TextFinder.matches(search, in: text, within: range?.node == text.id ? range?.range : nil)
        }
    }

    /// btn:[Find Next]: the first match after the current one (or after the Text tool's caret),
    /// wrapping to the start; shown on the canvas.
    @discardableResult
    func findNext(in window: DocumentWindowController) -> TextMatch? {
        let all = matches(in: window)
        guard !all.isEmpty else {
            current = nil
            message = find.isEmpty ? nil : "Not found"
            return nil
        }
        let order = TextFinder.nodes(in: window.documentHandle.state)
        let position = currentPosition(in: window)
        let next = all.first { match in
            guard let position else { return true }
            return (SpellingModel.rank(match.node, in: order), match.range.lowerBound) >= (position.index, position.offset)
        } ?? all[0]
        show(next, in: window)
        return next
    }

    /// Where Find Next starts: after the current match, else the Text tool's caret.
    private func currentPosition(in window: DocumentWindowController) -> (index: Int, offset: Int)? {
        let order = TextFinder.nodes(in: window.documentHandle.state)
        if let current, let text = window.documentHandle.state.textNode(current.node), let range = ReplaceTextRange.resolve(current, in: text) {
            return (SpellingModel.rank(current.node, in: order), range.upperBound)
        }
        if let session = window.objectEditing.textSession, let node = session.node, let index = order.firstIndex(of: node) {
            return (index, session.selectedRange.upperBound)
        }
        return nil
    }

    /// Selects `match` with the Text tool, highlighting it on the canvas.
    func show(_ match: TextMatch, in window: DocumentWindowController) {
        current = match
        message = nil
        window.editText(match.node, at: .zero)
        window.objectEditing.textSession?.select(anchor: match.range.lowerBound, focus: match.range.upperBound)
    }

    /// btn:[Replace]: replaces the current match and finds the next.
    @discardableResult
    func replace(in window: DocumentWindowController) -> Task<Void, Never>? {
        guard let match = current ?? findNext(in: window) else { return nil }
        let command = ReplaceText([match], with: replacement, label: "Replace '\(find)' with '\(replacement)'")
        let task = window.objectEditing.perform(command)
        return Task { @MainActor in
            _ = await task.value
            self.current = nil
            self.findNext(in: window)
        }
    }

    /// btn:[Replace & Find]: the same as btn:[Replace] (replace, then show the next match).
    @discardableResult
    func replaceAndFind(in window: DocumentWindowController) -> Task<Void, Never>? {
        replace(in: window)
    }

    /// btn:[Replace All]: every match of the region, one change.
    @discardableResult
    func replaceAll(in window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let all = matches(in: window)
        guard !all.isEmpty else {
            message = "Not found"
            return nil
        }
        current = nil
        message = all.count == 1 ? "1 replaced" : "\(all.count) replaced"
        return window.objectEditing.perform(ReplaceText(all, with: replacement, label: ReplaceText.replaceAllLabel(find, replacement, count: all.count)))
    }
}

/// Resolving a match against the text as it is now (the same rule the command uses).
enum ReplaceTextRange {
    static func resolve(_ match: TextMatch, in text: TextNode) -> Range<Int>? {
        let sequence = text.sequence
        guard let lower = sequence.offset(of: match.first), let last = sequence.offset(of: match.last) else { return nil }
        let upper = sequence.isDeleted(match.last) ? last : last + 1
        return lower < upper ? lower..<upper : nil
    }
}
