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
    let node: OpID
    @ObservationIgnored let session: TextEditingSession
    var twelvePointBlack = true
    var showInvisibles = false
    var wrapToWindow = true

    init(document: DocumentHandle, node: OpID, sink: any CommandSink) {
        self.document = document
        self.node = node
        session = TextEditingSession(document: document, sink: sink, target: .node(node))
        session.select(anchor: 0, focus: 0)
    }

    /// The node as merged now.
    var text: TextNode? { document.state.textNode(node) }

    /// Whether the node still exists (a remote delete closes the window).
    var isLive: Bool { document.state.isLive(node) && text != nil }

    /// The window's title.
    var title: String {
        let name = document.state.displayName(of: node)
        return "Text Editor — \(name)"
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
            guard let caret = participant.caret, caret.node.opID == node, let offset = PresenceOverlay.offset(caret.position, in: text) else { return nil }
            let other = caret.rangeEnd.flatMap { PresenceOverlay.offset($0, in: text) } ?? offset
            let lower = TextNavigation.utf16Offset(min(offset, other), in: all)
            let upper = TextNavigation.utf16Offset(max(offset, other), in: all)
            return RemoteMark(range: NSRange(location: lower, length: upper - lower), color: NSColor(cgColor: participant.color.cgColor) ?? .systemBlue,
                              name: participant.name)
        }
    }
}
