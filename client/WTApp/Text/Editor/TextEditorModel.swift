import AppKit
import Observation
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Text Editor window's model (editing-text.adoc, "The Text Editor window"; TYPE-011): one
/// text node shown as plain text.  Edits go through a `TextEditingSession` on the node, so they are
/// ordinary text commands (typing coalesces as it does on the canvas) and the selection is held as
/// anchors: a remote edit before the caret leaves it on its character.  *12 point black*,
/// *Show invisibles* and *Wrap to window* change only the window.  A chain's head owns the flow's
/// text, so a linked chain is one story here; text on a path is an ordinary text node.
@MainActor
@Observable
final class TextEditorModel {
    /// The font the editor shows under *12 point black*.
    static let plainFont = NSFont.systemFont(ofSize: 12)

    @ObservationIgnored let document: DocumentHandle
    /// The block, or for a text block inside an instance the instance.
    let node: OpID
    /// What the window edits: a block, or a text block inside an instance -- its text override
    /// (LIB-027).
    let target: TextEditingSession.Target
    @ObservationIgnored let session: TextEditingSession
    var twelvePointBlack = true
    var showInvisibles = false
    var wrapToWindow = true

    convenience init(document: DocumentHandle, node: OpID, sink: any CommandSink) {
        self.init(document: document, target: .node(node), sink: sink)
    }

    init(document: DocumentHandle, target: TextEditingSession.Target, sink: any CommandSink) {
        self.document = document
        // A member of a linked flow opens the flow's story, held by the chain's head (TYPE-007).
        let target = TextEditingSession.story(target, in: document.state)
        self.target = target
        if case .override(let instance, _) = target { node = instance } else if case .node(let id) = target { node = id } else { node = .zero }
        session = TextEditingSession(document: document, sink: sink, target: target)
        session.select(anchor: 0, focus: 0)
    }

    /// The text as merged now (inside an instance, as the instance shows it).
    var text: TextNode? { session.text }

    /// Whether the text still exists (a remote delete closes the window; inside an instance, a
    /// release, swap or hide of the block does).
    var isLive: Bool { session.override == nil ? document.state.isLive(node) && text != nil : session.isLive && text != nil }

    /// The window's title (inside an instance: the instance's name and the block's).
    var title: String {
        let state = document.state
        if let override = session.override {
            return "Text Editor — \(state.displayName(of: override.instance)) › \(Symbols.partTitle(override.master, in: state))"
        }
        return "Text Editor — \(state.displayName(of: node))"
    }

    /// Whether a collaborator's caret is in this text: the block's own, or the same override.
    func isHere(_ caret: RemoteCaret) -> Bool {
        guard caret.node.opID == node else { return false }
        guard let override = session.override else { return caret.text == TextFields.text }
        return Symbols.overrideMaster(ofTextField: caret.text, in: override.instance, state: document.state) == override.master
    }

    /// The characters with the window's rendering attributes: 12 pt black, or each run's own
    /// family, size and colour; U+FFFC (an inline graphic) drawn as a small box.
    func attributedString() -> NSAttributedString {
        guard let text else { return NSAttributedString() }
        let scalars = Array(text.string.unicodeScalars)
        let result = NSMutableAttributedString()
        let runs: [(range: Range<Int>, values: [Wiretuner_Doc_V1_TextMarkValue])] = text.runs.isEmpty
            ? [(0..<scalars.count, [])] : text.runs.map { ($0.range, $0.values) }
        for run in runs {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[run.range.clamped(to: 0..<scalars.count)])
            result.append(NSAttributedString(string: String(view), attributes: attributes(run.values)))
        }
        let string = result.string as NSString
        var location = 0
        while location < string.length {
            let found = string.range(of: "\u{FFFC}", range: NSRange(location: location, length: string.length - location))
            guard found.location != NSNotFound else { break }
            result.addAttribute(.attachment, value: Self.placeholder(), range: found)
            location = found.location + found.length
        }
        return result
    }

    /// The attributes of one run.
    func attributes(_ values: [Wiretuner_Doc_V1_TextMarkValue]) -> [NSAttributedString.Key: Any] {
        guard !twelvePointBlack else { return [.font: Self.plainFont, .foregroundColor: NSColor.black] }
        let resolved = TextLayoutReading.attributes(values)
        let size = max(resolved.size, 1)
        let font = resolved.fontFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        let fill = NSColor(cgColor: resolved.fill.cgColor) ?? .black
        return [.font: font, .foregroundColor: fill]
    }

    /// The inline graphic's placeholder: an 8 pt hollow box.
    static func placeholder() -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.secondaryLabelColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
        return attachment
    }

    // MARK: Selection and editing

    var scalars: [Unicode.Scalar] { session.scalars }

    /// The session's selection in UTF-16 (the view's units).
    var selectedRange: NSRange { session.selectedUTF16Range }

    /// The view's selection changed.
    func select(_ range: NSRange) {
        let scalarRange = TextNavigation.scalarRange(range, in: scalars)
        guard scalarRange != session.selectedRange else { return }
        session.select(anchor: scalarRange.lowerBound, focus: scalarRange.upperBound)
    }

    /// The view wants to replace `range` (UTF-16) with `replacement`: a keystroke, a deletion or
    /// a paste, performed as the Text tool's session would.
    func replace(_ range: NSRange, with replacement: String) {
        let scalarRange = TextNavigation.scalarRange(range, in: scalars)
        session.select(anchor: scalarRange.lowerBound, focus: scalarRange.upperBound)
        if replacement.isEmpty {
            if !scalarRange.isEmpty { session.delete(.deleteSelection) }
        } else {
            let normalized = replacement.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            session.insert(normalized, typing: normalized.unicodeScalars.count == 1)
        }
    }

    // MARK: Collaborators (TYPE-016)

    /// A collaborator's caret or selection in this text: UTF-16 range (empty for a caret), their
    /// colour and name.
    struct RemoteMark: Equatable {
        let range: NSRange
        let color: NSColor
        let name: String
    }

    /// The collaborators' carets and selections in this node, resolved through anchors (a deleted
    /// character reads where it was; a caret in a deleted node is not shown).
    func remoteMarks(_ participants: [RemoteParticipant]) -> [RemoteMark] {
        guard let text, isLive else { return [] }
        let all = Array(text.string.unicodeScalars)
        return participants.compactMap { participant in
            guard let caret = participant.caret, isHere(caret), let offset = PresenceOverlay.offset(caret.position, in: text) else { return nil }
            let other = caret.rangeEnd.flatMap { PresenceOverlay.offset($0, in: text) } ?? offset
            let lower = TextNavigation.utf16Offset(min(offset, other), in: all)
            let upper = TextNavigation.utf16Offset(max(offset, other), in: all)
            return RemoteMark(range: NSRange(location: lower, length: upper - lower), color: NSColor(cgColor: participant.color.cgColor) ?? .systemBlue,
                              name: participant.name)
        }
    }
}
