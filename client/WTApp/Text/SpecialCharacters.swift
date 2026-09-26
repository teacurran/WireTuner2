import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender
import WTText

/// Special characters, smart quotes and invisibles (editing-text.adoc, "Special characters" and
/// "Smart quotes"; TYPE-012).  menu:Text[Special Characters] inserts each of the nine characters at
/// the Text tool's insertion point, or in the Text Editor when it is the key window; the documented
/// shortcuts work while the Text tool edits a block -- the canvas hands its keys here before the
/// tool and before the menus (kbd:[Cmd+-] and kbd:[Cmd+Shift+T] belong to Zoom Out and Transform
/// Again elsewhere).  A typed `'` or `"` becomes the chosen set's curly form with *Smart quotes* on;
/// with kbd:[Control] it stays straight.
@MainActor
enum SpecialCharacterFeatures {
    static func id(_ character: SpecialCharacter) -> CommandID { ContextMenuCatalog.ID.specialCharacter(character.rawValue) }

    /// The documented key of each character: (key, modifiers).
    static let keys: [SpecialCharacter: (key: String, modifiers: NSEvent.ModifierFlags)] = [
        .endOfColumn: ("\r", .command), .endOfLine: ("\r", .shift), .nonBreakingSpace: (" ", .option),
        .emSpace: ("m", [.command, .shift]), .enSpace: ("n", [.command, .shift]), .thinSpace: ("t", [.command, .shift]),
        .emDash: ("-", [.shift, .option]), .enDash: ("-", .option), .discretionaryHyphen: ("-", .command),
    ]

    /// The keys' codes, so layouts that put another character on them still match.
    static let keyCodes: [String: UInt16] = ["\r": 36, " ": 49, "-": 27, "m": 46, "n": 45, "t": 17]

    /// The character `event` types as a special character, or nil.
    static func special(for event: NSEvent) -> SpecialCharacter? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        return keys.first { $0.value.modifiers == flags && keyCodes[$0.value.key] == event.keyCode }?.key
    }

    /// The menu's commands (the nine replace the catalog's stubs, in the documented order).
    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        SpecialCharacter.allCases.map { character in
            Command(id: id(character), title: character.title,
                    menu: MenuPath(ContextMenuCatalog.Menu.text, "Special Characters", section: 1), contexts: [.text],
                    keywords: ["special", "character", "insert"],
                    validation: { canInsert(window()) ? .enabled : .disabled("Click in text with the Text tool") },
                    action: .perform { insert(character, window: window()) })
        }
    }

    /// The key window's Text Editor, if its text view has the keys.
    static var editorTextView: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    static func canInsert(_ window: DocumentWindowController?) -> Bool {
        editorTextView != nil || window?.objectEditing.textSession?.isLive == true
    }

    /// Inserts `character` where text is being typed; answers whether anything took it.
    @discardableResult
    static func insert(_ character: SpecialCharacter, window: DocumentWindowController?) -> Bool {
        if let view = editorTextView {
            view.insertText(String(character.character), replacementRange: view.selectedRange())
            return true
        }
        guard let session = window?.objectEditing.textSession, session.isLive else { return false }
        session.insert(String(character.character), typing: false)
        return true
    }

    // MARK: Keys

    /// The last character typed into a session, while its changes are still landing (a quote
    /// typed right after a space must see the space before the document does).
    private(set) static var lastTyped: (session: ObjectIdentifier, character: Character)?

    static func typed(_ string: String, in session: TextEditingSession) {
        lastTyped = string.last.map { (ObjectIdentifier(session), $0) } ?? lastTyped
    }

    /// The canvas's key hook: special characters and smart quotes while the Text tool edits.
    static func handle(_ event: NSEvent, window: DocumentWindowController) -> Bool {
        guard event.type == .keyDown, window.canvas.toolManager?.textInput != nil, let session = window.objectEditing.textSession,
              session.isLive, session.marked == nil else { return false }
        if let character = special(for: event) {
            session.insert(String(character.character), typing: false)
            typed(String(character.character), in: session)
            return true
        }
        let preferences = window.environment.preferences
        guard let typed = quote(event, smart: preferences[PreferenceCatalog.Text.smartQuotes],
                                style: preferences[PreferenceCatalog.Text.smartQuotesStyle], previous: previous(in: session)) else {
            // Other typing goes on to the tool; remember it for the next quote.
            if event.modifierFlags.isDisjoint(with: [.command, .control]), let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                Self.typed(characters, in: session)
            }
            return false
        }
        session.insert(typed)
        Self.typed(typed, in: session)
        return true
    }

    /// What a quote key types: the straight quote with kbd:[Control], the set's curly form with
    /// smart quotes on; nil when `event` is not a quote key or smart quotes are off.
    static func quote(_ event: NSEvent, smart: Bool, style: String, previous: Character?) -> String? {
        let flags = event.modifierFlags.intersection([.control, .option, .command])
        guard let typed = event.charactersIgnoringModifiers, typed == "'" || typed == "\"", flags.isSubset(of: .control) else { return nil }
        if flags.contains(.control) { return typed }
        guard smart else { return nil }
        return SmartQuotes.set(style).replacement(for: typed, after: previous)
    }

    /// The character before the insertion point (or the selection): the last one typed while
    /// the session's changes are still landing, else the document's.
    static func previous(in session: TextEditingSession) -> Character? {
        if session.inflight > 0, let lastTyped, lastTyped.session == ObjectIdentifier(session) { return lastTyped.character }
        let scalars = session.scalars
        let index = session.selectedRange.lowerBound - 1
        guard scalars.indices.contains(index) else { return nil }
        return Character(scalars[index])
    }
}

/// Invisibles on the canvas: the marks for spaces, tabs, paragraph ends, ends of line and column
/// and discretionary hyphens, drawn over each block open in a Text Editor window with *Show
/// invisibles* on (the editor shows them too, through its layout manager).
@MainActor
enum InvisibleMarks {
    /// The mark and its baseline point (container space) for each invisible character laid out.
    static func marks(in text: TextNode, layout: TextLayout) -> [(mark: String, at: Point)] {
        let scalars = Array(text.string.unicodeScalars)
        return scalars.indices.prefix(layout.laidOutEnd).compactMap { index in
            guard let mark = SpecialCharacter.invisibleMark(for: scalars[index]), let caret = layout.caret(atOffset: index) else { return nil }
            return (mark, caret.baseline)
        }
    }

    /// The blocks of `document` whose Text Editor shows invisibles.
    static func blocks(of document: DocumentHandle, editors: TextEditorFeatures = .shared) -> [OpID] {
        editors.controllers.values.filter { $0.model.document === document && $0.model.showInvisibles && $0.model.isLive }.map(\.model.node)
    }

    static func draw(in ctx: CGContext, viewport: Viewport, window: DocumentWindowController) {
        let document = window.documentHandle
        let state = document.state
        for node in blocks(of: document) {
            guard let text = state.textNode(node), let layout = document.textLayout(for: node) else { continue }
            let toView = Objects.pasteboardTransform(of: node, in: state).concatenating(viewport.pasteboardToView)
            for (mark, point) in marks(in: text, layout: layout) {
                draw(mark, at: toView.apply(point), in: ctx)
            }
        }
    }

    static func draw(_ mark: String, at point: Point, in ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: mark, attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = point.cgPoint
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
