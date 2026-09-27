import AppKit
import WTModel
import WTText

/// The families of menu:Text[Font] and the faces of menu:Text[Style], read each time the menu
/// opens (and the same submenus of the text context menus): the recently used families on top,
/// the document's fonts missing on this Mac in brackets with a warning, then every family that
/// can be laid out, the document's own marked; the static *Other…* follows.  The Style menu adds
/// the family's other faces after Plain, Bold, Italic and Bold Italic.  A check marks the value
/// the text shares; when it differs, each value it holds is marked mixed.
@MainActor
final class FontMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = FontMenus()
    /// The tag of the items this delegate adds (it removes them before adding again).
    static let dynamicTag = 0x464F_4E54

    var window: FontCommands.Window = { nil }
    var recents: FontRecentsStore = .shared

    /// The faces the Style menu's four commands already stand for.
    static let standardFaces: Set<String> = Set(FontStyleCommands.styles.map(\.2))

    /// The delegate of the menu at `path` (`MainMenuBuilder.dynamicMenus`): the Font and Style
    /// submenus of the Text menu and of the context menus.
    static func delegate(for path: [String]) -> (any NSMenuDelegate)? {
        guard path.count == 2, path[0] == ContextMenuCatalog.Menu.text || path[0] == "Context" else { return nil }
        return path[1] == FontCommands.fontMenu || path[1] == FontCommands.styleMenu ? shared : nil
    }

    /// The family list for `document`.
    static func familyList(document: DocumentHandle, recents: [String]) -> FontFamilyList {
        let fonts = document.textEngine.fonts
        let families = Set(DocumentFontIndex.namedFaces(in: document.state).map(\.family))
        return FontFamilyList(installed: fonts.families(), recents: recents, documentFamilies: families, isAvailable: { fonts.isAvailable($0) })
    }

    // MARK: Filling

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.dynamicTag { menu.removeItem(item) }
        switch menu.title {
        case FontCommands.fontMenu: fillFonts(menu)
        case FontCommands.styleMenu: fillFaces(menu)
        default: break
        }
    }

    /// The menu has no key equivalents of its own, so AppKit need not fill it to look for one.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    func fillFonts(_ menu: NSMenu) {
        guard let front = window() else { return }
        let list = Self.familyList(document: front.documentHandle, recents: recents.families)
        let held = FontCommands.model(front)?.fontFamilies ?? []
        var items: [NSMenuItem] = []
        func group(_ title: String, _ choices: [FontFamilyChoice]) {
            guard !choices.isEmpty else { return }
            if !items.isEmpty { items.append(Self.tagged(.separator())) }
            items.append(Self.tagged(.sectionHeader(title: title)))
            items += choices.map { familyItem($0, held: held) }
        }
        group("Recently Used", list.recent)
        group("Missing Fonts", list.missing)
        group("All Fonts", list.all)
        if !items.isEmpty, !menu.items.isEmpty { items.append(Self.tagged(.separator())) }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    func fillFaces(_ menu: NSMenu) {
        guard let front = window(), let model = FontCommands.model(front), let family = model.text?.family else { return }
        let faces = front.documentHandle.textEngine.fonts.styles(of: family).filter { !Self.standardFaces.contains($0) }
        guard !faces.isEmpty else { return }
        let held = model.fontStyles
        menu.addItem(Self.tagged(.separator()))
        for face in faces {
            let item = Self.tagged(NSMenuItem(title: face, action: #selector(chooseFace(_:)), keyEquivalent: ""))
            item.target = self
            item.representedObject = face
            item.state = Self.state(face, held: held)
            item.identifier = NSUserInterfaceItemIdentifier("menu.text.style.face.\(face)")
            menu.addItem(item)
        }
    }

    func familyItem(_ choice: FontFamilyChoice, held: Set<String>) -> NSMenuItem {
        let item = Self.tagged(NSMenuItem(title: choice.title, action: #selector(chooseFamily(_:)), keyEquivalent: ""))
        item.target = self
        item.representedObject = choice.family
        item.state = Self.state(choice.family, held: held)
        item.identifier = NSUserInterfaceItemIdentifier("menu.text.font.family.\(choice.family)")
        if choice.isMissing {
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Missing on this Mac")
            item.toolTip = "Missing on this Mac: drawn in a substitute"
        } else if choice.inDocument {
            item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Used in this document")
            item.toolTip = "Used in this document"
        }
        return item
    }

    static func tagged(_ item: NSMenuItem) -> NSMenuItem {
        item.tag = dynamicTag
        return item
    }

    /// On when the text shares `value`, mixed when it holds it among others.
    static func state(_ value: String, held: Set<String>) -> NSControl.StateValue {
        guard held.contains(value) else { return .off }
        return held.count == 1 ? .on : .mixed
    }

    // MARK: Choosing

    @objc func chooseFamily(_ sender: NSMenuItem) {
        guard let family = sender.representedObject as? String else { return }
        FontCommands.apply(family: family, window: window(), recents: recents)
    }

    @objc func chooseFace(_ sender: NSMenuItem) {
        guard let face = sender.representedObject as? String else { return }
        FontCommands.apply(style: face, window: window())
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        FontCommands.model(window()) != nil
    }
}
