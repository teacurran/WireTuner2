import AppKit
import SwiftUI
import WTModel
import WTProto

/// The Text menu's effect items (text-effects.adoc, "Text effects"; TYPE-037): menu:Text[Effect]
/// with *None* and the six effects, and menu:Text[Type Style > Underline] and *Strikethrough*, the
/// shortcuts for those two effects with their defaults, then *Superscript* and *Subscript*, the
/// size and baseline shift presets (TYPE-060).  An effect's item applies it with its
/// defaults, or -- when the selected text already has that effect -- opens its option sheet.
@MainActor
enum TextFeatures {
    typealias Window = @MainActor () -> DocumentWindowController?

    enum ID {
        static func effect(_ kind: TextEffectKind) -> CommandID { CommandID("text.effect.\(kind.rawValue)") }
        static let underline: CommandID = "text.typeStyle.underline"
        static let strikethrough: CommandID = "text.typeStyle.strikethrough"
        static func script(_ script: TextScript) -> CommandID { CommandID("text.typeStyle.\(script.rawValue)") }
    }

    static let noText = "Select text"
    static let effectMenu = "Effect"
    static let typeStyleMenu = "Type Style"

    /// The Object panel model of `window`'s selection (the Text tool's session included).
    static func model(_ window: DocumentWindowController?) -> ObjectPanelModel? {
        guard let window else { return nil }
        return ObjectPanelModel(document: window.documentHandle, selection: window.selection.selection, textSession: window.objectEditing.textSession)
    }

    /// What an effect item does: opens the sheet (the text has the effect already), or applies it.
    enum Outcome: Equatable {
        case applied
        case sheet(TextEffectSheetModel)
    }

    /// Performs `kind`'s item on `model`; nil when no text is selected.
    @discardableResult
    static func choose(_ kind: TextEffectKind, model: ObjectPanelModel?, applyDefaults: Bool = false) -> Outcome? {
        guard let model, let section = model.textEffect else { return nil }
        if !applyDefaults, kind != .none, section.kind == kind {
            return .sheet(TextEffectSheetModel(kind: kind, current: section.effect))
        }
        model.setTextEffect(kind)
        return .applied
    }

    /// Opens `sheet` on `window`; btn:[OK] writes the effect whole.
    @discardableResult
    static func present(_ sheet: TextEffectSheetModel, on window: DocumentWindowController) -> NSWindow? {
        window.presentSheet("text-effect.\(sheet.kind.rawValue)") { close in
            TextEffectSheetView(model: sheet, commit: finish(on: window, close: close), cancel: close)
        }
    }

    /// The sheet's btn:[OK] on `window`: the effect, whole, then the sheet closes.
    static func finish(on window: DocumentWindowController, close: @escaping @MainActor () -> Void) -> (TextEffectSheetModel) -> Void {
        { edited in
            model(window)?.setTextEffect(edited.effect)
            close()
        }
    }

    /// menu:Text[Type Style > Superscript] / *Subscript* (TYPE-060): with the Text tool, the
    /// selection (or the pending format at an insertion point); otherwise every selected text
    /// block whole.  One change.
    @discardableResult
    static func apply(_ script: TextScript, on window: DocumentWindowController) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let editing = window.objectEditing
        if let session = editing.textSession {
            return session.script(script)
        }
        let state = window.documentHandle.state
        let commands: [any WTModel.Command] = editing.selectedNodes.compactMap { node in
            state.textNode(node).flatMap { script.command(node, range: 0..<$0.length, in: state) }
        }
        guard !commands.isEmpty else { return nil }
        return editing.perform(commands.count == 1 ? commands[0] : CommandBatch(script.title, commands))
    }

    static func commands(window: @escaping Window) -> [Command] {
        let text = ContextMenuCatalog.Menu.text
        let validation: @MainActor @Sendable () -> CommandValidation = {
            model(window())?.textEffect == nil ? .disabled(noText) : .enabled
        }
        func item(_ kind: TextEffectKind, applyDefaults: Bool = false) -> CommandAction {
            .perform {
                let front = window()
                if case .sheet(let sheet)? = choose(kind, model: model(front), applyDefaults: applyDefaults), let front {
                    present(sheet, on: front)
                }
            }
        }
        var commands = TextEffectKind.allCases.map { kind in
            Command(id: ID.effect(kind), title: kind.title, menu: MenuPath(text, effectMenu, section: 1, subsection: kind == .none ? 0 : 1),
                    keywords: ["text effect", "effect"], validation: validation, action: item(kind))
        }
        commands.append(Command(id: ID.underline, title: "Underline", menu: MenuPath(text, typeStyleMenu, section: 1), keywords: ["text effect", "underline"],
                                validation: validation, action: item(.underline, applyDefaults: true)))
        commands.append(Command(id: ID.strikethrough, title: "Strikethrough", menu: MenuPath(text, typeStyleMenu, section: 1),
                                keywords: ["text effect", "strike"], validation: validation, action: item(.strikethrough, applyDefaults: true)))
        for script in TextScript.allCases {
            commands.append(Command(id: ID.script(script), title: script.title, menu: MenuPath(text, typeStyleMenu, section: 1),
                                    keywords: ["baseline shift", "footnote", script.rawValue], validation: validation,
                                    action: .perform { if let front = window() { apply(script, on: front) } }))
        }
        return commands
    }

    static func install(into registry: CommandRegistry, window: @escaping Window) {
        for command in commands(window: window) { registry.replace(command) }
    }
}
