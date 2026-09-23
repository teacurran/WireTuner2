import AppKit

/// BASIC-026, BASIC-027 and BASIC-033 wiring: the shortcut sets drive the menu bar and tool
/// keys, menu:Edit[Keyboard Shortcuts…] opens the editor, menu:Help[Command Palette…] the
/// palette.
extension AppDelegate {
    func installShortcutsAndPalette() {
        let registry = commands
        shortcutSets.commands = { registry.commands }
        shortcutSets.onChange = { [weak self] in self?.rebuildMainMenu() }
        KeyboardShortcutsCommands.install(into: commands) { [weak self] in self?.showKeyboardShortcuts() }
        let documents = documents!
        let layout = layout
        CommandPaletteCommands.install(
            into: commands, panels: panels, controller: palette,
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutSet.builtInDefault(commands: []) },
            perform: { [weak self] id in _ = self?.menuTarget?.perform(id) },
            showPanel: { layout.showPanel($0) },
            document: { documents.activeWindowController?.documentHandle },
            goToPage: { documents.activeWindowController?.goToPage($0) },
            keyWindow: { documents.activeWindowController?.window ?? NSApp.keyWindow }
        )
    }

    /// menu:Edit[Keyboard Shortcuts…].
    func showKeyboardShortcuts() {
        let controller = keyboardShortcutsWindowController
            ?? KeyboardShortcutsWindowController(model: KeyboardShortcutsModel(store: shortcutSets, registry: commands))
        keyboardShortcutsWindowController = controller
        controller.show()
    }
}
