import AppKit

/// The toolbars, extensions and named layouts (BASIC-011, 029, 030, 031, 032), wired in two
/// calls from `AppDelegate`: `installToolbars()` at launch (before the panel layout loads) and
/// `toolbarsDocumentsDidChange()` when the key window changes.
extension AppDelegate {
    func installToolbars() {
        let toolbars = toolbars
        toolbars.parentWindow = { [weak self] in self?.activeDocumentWindow?.window }
        toolbars.onMenuChange = { [weak self] in self?.rebuildMainMenu() }
        toolbars.install(commands: commands, panels: panels, palette: toolPalette, preferences: preferences) { [weak self] id in
            self?.menuTarget?.perform(id) ?? false
        }
        let select = toolPalette.select
        toolPalette.select = { id in
            toolbars.extensions.noteToolUsed()
            select(id)
        }
        namedLayouts.onMenuChange = { [weak self] in self?.rebuildMainMenu() }
        namedLayouts.refresh()
    }

    /// The Info toolbar follows the key window's tool; buttons revalidate.
    func toolbarsDocumentsDidChange() {
        toolbars.controller.attach(infoSource: activeDocumentWindow?.toolManager)
        toolbars.controller.notify()
    }
}
