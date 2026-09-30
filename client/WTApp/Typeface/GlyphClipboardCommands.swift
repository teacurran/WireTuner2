import AppKit
import WTCRDT
import WTModel
import WTProto

// The grid's clipboard, placeholders and reordering (glyph-grid.adoc, "Acting on several glyphs", "Adding
// glyphs", "Ordering and encodings"; glyph-editing.adoc, "Components"; FONT-008, FONT-010, FONT-012 rests):
// menu:Edit[Copy] with the grid focused copies the selected glyphs (and their artwork, for a paste onto a
// canvas); menu:Edit[Paste] there replaces a selection of the same count (confirmed) or adds new glyphs;
// menu:Edit[Paste as Component] adds the copied glyphs to the targeted glyphs; menu:View[Encoding] shows the
// empty slots of character sets as placeholders, and double-clicking one makes the glyph and opens it.

extension TypefaceFeatures {
    enum ClipboardID {
        static let pasteAsComponent: CommandID = "edit.pasteAsComponent"
        static let encodingNone: CommandID = "view.encoding.none"

        static func encoding(_ encoding: GlyphEncoding) -> CommandID { CommandID("view.encoding.\(encoding.rawValue)") }
    }

    static let glyphsType = NSPasteboard.PasteboardType(GlyphClipboardPayload.pasteboardType)
    static let noCopiedGlyphs = "Copy glyphs in the grid first"
    static let menuEncoding = "Encoding"

    func glyphClipboardCommands() -> [Command] {
        let window = self.window
        let view = StandardCommands.Menu.view
        var commands = [
            Command(id: ClipboardID.pasteAsComponent, title: "Paste as Component", menu: MenuPath(StandardCommands.Menu.edit, section: 1),
                    keywords: ["component", "glyph", "reference"], validation: { [unowned self] in
                        guard let controller = window() else { return .disabled(Self.noDocument) }
                        guard DocumentKind(controller.documentHandle.state) == .typeface else { return .disabled(Self.notTypeface) }
                        guard glyphClipboard() != nil else { return .disabled(Self.noCopiedGlyphs) }
                        return targetGlyphs(in: controller).isEmpty ? .disabled(Self.noGlyph) : .enabled
                    }, action: .perform { [unowned self] in pasteAsComponents() }),
            Command(id: ClipboardID.encodingNone, title: "None", menu: MenuPath(view, Self.menuEncoding, section: StandardCommands.Section.viewZoom),
                    keywords: ["placeholder", "encoding", "missing"], validation: { [unowned self] in .checked(encodings.isEmpty) },
                    action: .perform { [unowned self] in encodings = [] }),
        ]
        for encoding in GlyphEncoding.allCases {
            let subsection = GlyphEncoding.codePages.contains(encoding) ? 1 : 2
            commands.append(Command(id: ClipboardID.encoding(encoding), title: encoding.title,
                                    menu: MenuPath(view, Self.menuEncoding, section: StandardCommands.Section.viewZoom, subsection: subsection),
                                    keywords: ["placeholder", "encoding", "missing"], validation: { [unowned self] in .checked(encodings.contains(encoding)) },
                                    action: .perform { [unowned self] in toggleEncoding(encoding) }))
        }
        return commands
    }

    /// Shows or hides `encoding`'s placeholders.
    func toggleEncoding(_ encoding: GlyphEncoding) {
        if encodings.contains(encoding) { encodings.remove(encoding) } else { encodings.insert(encoding) }
    }

    /// Every grid shows the chosen encodings' placeholders.
    func applyEncodings() {
        for mode in modes.values { mode.grid?.model.encodings = encodings }
    }

    // MARK: Clipboard

    /// The copied glyphs on the pasteboard, if any.
    func glyphClipboard() -> GlyphClipboardPayload? {
        glyphPasteboard.data(forType: Self.glyphsType).flatMap { GlyphClipboardPayload(decoding: Array($0)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// menu:Edit[Copy] in the grid: the selected glyphs, and their artwork as objects (so a paste on a page or a
    /// glyph canvas pastes the drawings).
    @discardableResult
    func copyGlyphs() -> GlyphClipboardPayload? {
        guard let controller = window() else { return nil }
        let document = gridDocument(of: controller)
        let payload = GlyphClipboardPayload(copying: targetGlyphs(in: controller), from: document.state, document: document.id)
        guard !payload.isEmpty else { return nil }
        glyphPasteboard.clearContents()
        glyphPasteboard.setData(Data(payload.encoded()), forType: Self.glyphsType)
        let artwork = payload.artwork
        if !artwork.isEmpty { glyphPasteboard.setData(Data(artwork.encoded()), forType: SystemObjectPasteboard.type) }
        return payload
    }

    /// menu:Edit[Paste] in the grid: into a selection of the same count (after confirmation), else as new glyphs
    /// after the selection; the pasted glyphs are selected.
    @discardableResult
    func pasteGlyphs() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let controller = window(), let payload = glyphClipboard() else { return nil }
        let document = gridDocument(of: controller)
        let selection = targetGlyphs(in: controller)
        let command: PasteGlyphs
        if selection.count == payload.glyphs.count {
            let what = selection.count == 1 ? "this glyph" : "these \(selection.count) glyphs"
            guard controller.confirm("Replace the artwork and metrics of \(what)?", "Their names and characters are kept.  You can undo this.") else { return nil }
            command = PasteGlyphs(payload, .replace(selection), into: document.id)
        } else {
            command = PasteGlyphs(payload, .add(after: selection.last), into: document.id)
        }
        let task = document.perform(command)
        let grid = mode(of: controller)?.grid
        return Task {
            let change = await task.value
            if let change, let grid {
                let index = GlyphIndex(document.state)
                let pasted = change.createdRoots.filter { index[$0] != nil }
                grid.reload()
                grid.model.select(pasted.isEmpty ? selection : pasted)
            }
            return change
        }
    }

    /// menu:Edit[Paste as Component]: every copied glyph as a component of every targeted glyph, one change.
    @discardableResult
    func pasteAsComponents() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let controller = window(), let payload = glyphClipboard() else { return nil }
        let document = gridDocument(of: controller)
        let glyphs = targetGlyphs(in: controller)
        guard !glyphs.isEmpty else { return nil }
        return document.perform(PasteAsComponents(payload, into: glyphs, document: document.id))
    }

    // MARK: Placeholders

    /// A double-click on the placeholder of `codepoint` in `mode`'s grid: the glyph, after the selection, opened;
    /// the task answers the glyph made.
    @discardableResult
    func createPlaceholderGlyph(_ codepoint: UInt32, in mode: TypefaceWindowMode) -> Task<OpID?, Never> {
        let document = mode.controller.documentHandle
        let task = document.perform(AddGlyphs([NewGlyph(scalar: codepoint)], after: mode.grid?.model.selection.last))
        return Task { [weak self, weak mode] in
            _ = await task.value
            guard let self, let mode, let glyph = GlyphIndex(document.state).glyph(for: codepoint) else { return nil }
            mode.grid?.reload()
            mode.grid?.model.select([glyph.id])
            openGlyph(glyph.id, from: mode.controller)
            return glyph.id
        }
    }
}
