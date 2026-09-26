import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto

/// menu:Edit[Special > Copy Attributes] and *Paste Attributes* for text (copying-type.adoc;
/// TYPE-031), in front of the object commands (OBJ-014), and the Eyedropper on text.  A range
/// with the Text tool, or a text block with the Pointer, is a text source: the first character's
/// attributes, the first paragraph's settings and -- from a block -- its block appearance.  A text
/// target takes the characters' attributes over its range (a block: all its text) and the
/// paragraph settings on every paragraph it touches; a path takes the block appearance only.  The
/// attribute clipboard is the window's pasteboard under the attribute type, as for objects.
@MainActor
enum TextAttributeClipboard {
    /// The set the window's selection gives: the Text tool's range, else the first selected block.
    static func capture(_ window: DocumentWindowController) -> TextAttributeSet? {
        let state = window.documentHandle.state
        if let session = window.objectEditing.textSession, session.isLive, let text = session.text {
            return TextAttributeSet.capture(from: text, range: session.selectedRange, in: state)
        }
        guard let node = window.objectEditing.selectedNodes.first, let text = state.textNode(node) else { return nil }
        return TextAttributeSet.capture(from: text, block: true, in: state)
    }

    /// Copy Attributes from a text source; false when the source is not text (the object copy
    /// runs instead).
    @discardableResult
    static func copy(_ window: DocumentWindowController) -> Bool {
        guard let set = capture(window) else { return false }
        let pasteboard = EditFeatures.pasteboard(of: window)
        pasteboard.clearContents()
        pasteboard.setData(Data(set.clipboard(sourceDocument: window.documentHandle.id).encoded()), forType: EditFeatures.attributesType)
        return true
    }

    /// The text set on the window's attribute clipboard, if the copy was of text.
    static func copied(_ window: DocumentWindowController) -> TextAttributeSet? {
        EditFeatures.pasteboard(of: window).data(forType: EditFeatures.attributesType)
            .flatMap { ClipboardPayload(decoding: Array($0)) }.flatMap(TextAttributeSet.init)
    }

    /// The targets: the Text tool's range, else each selected text block whole.
    static func textTargets(_ window: DocumentWindowController) -> [TextAttributeTarget] {
        let state = window.documentHandle.state
        if let session = window.objectEditing.textSession, session.isLive, let node = session.node, let text = session.text {
            let range = session.selectedRange
            return [TextAttributeTarget(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound))]
        }
        return window.objectEditing.selectedNodes.filter { state.textNode($0) != nil }.map { TextAttributeTarget(node: $0) }
    }

    /// The change pasting `set` makes: text targets take the text attributes, other selected
    /// objects the block appearance.  Nil when nothing takes anything.
    static func command(_ set: TextAttributeSet, window: DocumentWindowController) -> (any WTModel.Command)? {
        let state = window.documentHandle.state
        var commands: [any WTModel.Command] = []
        let texts = textTargets(window)
        if !texts.isEmpty { commands.append(PasteTextAttributes(set, to: texts)) }
        let others = window.objectEditing.textSession?.isLive == true ? [] : window.objectEditing.selectedNodes.filter { state.textNode($0) == nil }
        if let stack = set.stackPayload, !others.isEmpty { commands.append(PasteAttributes(stack, to: others, in: state)) }
        return commands.isEmpty ? nil : CommandBatch("Paste attributes", commands)
    }

    /// Paste Attributes with a text copy on the clipboard; nil when the copy is not text.
    @discardableResult
    static func paste(_ window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let set = copied(window), let command = command(set, window: window) else { return nil }
        return window.objectEditing.perform(command)
    }

    /// The two commands, text first, the object versions otherwise.
    static func commands(edit: EditFeatures, window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        let menu = MenuPath(StandardCommands.Menu.edit, "Special", section: 1)
        return [
            Command(id: EditFeatures.ID.copyAttributes, title: "Copy Attributes", key: KeyEquivalent("c", [.command, .option]), menu: menu,
                    keywords: ["style", "eyedropper", "look", "type"],
                    validation: {
                        guard let window = window() else { return .disabled(EditFeatures.noDocument) }
                        return window.objectEditing.hasSelection || window.objectEditing.textSession?.isLive == true ? .enabled : .disabled(ObjectMenuCommands.noSelection)
                    },
                    action: .perform { if let window = window(), !copy(window) { edit.copyAttributes() } }),
            Command(id: EditFeatures.ID.pasteAttributes, title: "Paste Attributes", menu: menu, keywords: ["style", "look", "type"],
                    validation: {
                        guard let window = window() else { return .disabled(EditFeatures.noDocument) }
                        let text = copied(window) != nil && (window.objectEditing.hasSelection || window.objectEditing.textSession?.isLive == true)
                        return text || (window.objectEditing.hasSelection && edit.copiedAttributes(window) != nil) ? .enabled : .disabled("Copy attributes and select objects first")
                    },
                    action: .perform { if let window = window(), paste(window) == nil { edit.pasteAttributes() } }),
        ]
    }
}

/// The Eyedropper on text (copying-type, "The Eyedropper on text"): a click on text picks up its
/// attributes at the character under the pointer (the colour pick goes on as before); an
/// kbd:[Option]-click on other text applies them -- with kbd:[Shift] only the character
/// attributes, with kbd:[Cmd] only the paragraph ones -- one change.
@MainActor
enum TextEyedropper {
    /// What the tool last picked up from text.
    static var sampled: TextAttributeSet?

    /// The text block under `point` (pasteboard) and the character offset there.
    static func hit(_ point: Point, context: ToolContext) -> (node: OpID, offset: Int)? {
        let document = context.document
        let state = document.state
        let candidates = document.scene.objects.values.filter { $0.kind == .text && !$0.isEffectivelyLocked }
            .sorted { $0.itemPath.lexicographicallyPrecedes($1.itemPath) }.reversed()
        for object in candidates {
            guard let layout = document.textLayout(for: object.id), let text = state.textNode(object.id),
                  let local = Objects.pasteboardTransform(of: object.id, in: state).inverted()?.apply(point),
                  TextFrames.frame(of: layout).contains(local) else { continue }
            let offset = min(layout.offset(at: local, inContainer: 0) ?? 0, max(text.length - 1, 0))
            return (object.id, offset)
        }
        return nil
    }

    /// The press: answers whether it was taken (an kbd:[Option]-click applying a pick).
    static func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let (node, offset) = hit(e.pasteboardPoint, context: context), let text = context.document.state.textNode(node) else { return false }
        if e.modifiers.contains(.option) {
            guard let set = sampled else { return false }
            let filtered = set.filtered(character: !e.modifiers.contains(.command), paragraph: !e.modifiers.contains(.shift))
            context.commandSink.perform(PasteTextAttributes(filtered, to: [TextAttributeTarget(node: node)]))
            return true
        }
        sampled = TextAttributeSet.capture(from: text, range: offset..<offset, in: context.document.state)
        return false
    }
}
