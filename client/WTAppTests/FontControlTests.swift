import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTModel
import WTProto
import WTText
@testable import WireTuner

/// menu:Text[Font], menu:Text[Size], menu:Text[Style]'s other faces, their context-menu twins and
/// the Text toolbar's font controls (type-tools.adoc; type-specifications.adoc, "Font, size and
/// style"; the font and size part of TYPE-017).
@Suite(.serialized) @MainActor struct FontControlTests {
    static let first = "Menlo"
    static let second = "Georgia"

    static func recents() -> FontRecentsStore {
        FontRecentsStore(defaults: UserDefaults(suiteName: "font-recents-\(UUID().uuidString)")!)
    }

    static func menus(_ world: TypeWorld, recents: FontRecentsStore) -> FontMenus {
        let menus = FontMenus()
        menus.window = { [weak window = world.window] in window }
        menus.recents = recents
        return menus
    }

    /// The Font menu as it opens, with the static *Other…* after the families.
    static func fontMenu(_ menus: FontMenus) -> NSMenu {
        let menu = NSMenu(title: FontCommands.fontMenu)
        menu.addItem(NSMenuItem(title: "Other…", action: nil, keyEquivalent: ""))
        menus.menuNeedsUpdate(menu)
        return menu
    }

    static func item(_ menu: NSMenu, _ family: String) -> NSMenuItem? {
        menu.items.first { $0.representedObject as? String == family }
    }

    static func families(_ world: TypeWorld, _ node: OpID) -> [String] {
        try! #require(world.state.textNode(node)).runs.map { ObjectPanelModel.family($0.values) }
    }

    static func commands(_ world: TypeWorld, sheets: FontSheets = FontSheets(recents: recents())) -> [CommandID: WireTuner.Command] {
        Dictionary(uniqueKeysWithValues: FontCommands.commands(window: { [weak window = world.window] in window }, sheets: sheets).map { ($0.id, $0) })
    }

    static func run(_ command: WireTuner.Command?) {
        if case .perform(let action)? = command?.action { action() }
    }

    // MARK: Font menu

    @Test func aFamilyFromTheFontMenuChangesABlockAndARangeAndMarksMixedText() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let recents = Self.recents()
        let menus = Self.menus(world, recents: recents)
        let node = try await world.block("Font menu")
        // A whole block: one change, "Font".
        var menu = Self.fontMenu(menus)
        let firstItem = try #require(Self.item(menu, Self.first))
        #expect(menus.validateMenuItem(firstItem))
        let before = world.document.changeCount
        menus.chooseFamily(firstItem)
        await world.settle()
        #expect(Self.families(world, node) == [Self.first] && world.document.changeCount == before + 1)
        #expect(world.document.undoTitle == "Undo Font")
        #expect(recents.families == [Self.first])
        // Reopened: the recent group on top, the check on the shared family, *Other…* last.
        menu = Self.fontMenu(menus)
        #expect(menu.items[0].title == "Recently Used" && menu.items[1].representedObject as? String == Self.first)
        #expect(menu.items.contains { $0.title == "All Fonts" } && menu.items.last?.title == "Other…")
        #expect(menu.items.filter { $0.representedObject as? String == Self.first }.allSatisfy { $0.state == .on })
        #expect(Self.item(menu, Self.first)?.image != nil, "the document's font is marked")
        #expect(menu.items.filter { $0.tag == FontMenus.dynamicTag }.count == menu.items.count - 1)
        // A range with the Text tool: one mark over the range.
        await world.edit(node, select: 0..<4)
        menus.chooseFamily(try #require(Self.item(Self.fontMenu(menus), Self.second)))
        await world.settle()
        #expect(world.state.textNode(node)?.runs.count == 2)
        #expect(Set(Self.families(world, node)) == [Self.first, Self.second])
        #expect(Self.item(Self.fontMenu(menus), Self.second)?.state == .on, "the range shares one family")
        // The whole block holds both: each marked mixed.
        world.window.objectEditing.textSession = nil
        world.window.selection.model.set(Selection([SelectionID(node)]))
        menu = Self.fontMenu(menus)
        #expect(Self.item(menu, Self.first)?.state == .mixed && Self.item(menu, Self.second)?.state == .mixed)
        #expect(recents.families == [Self.second, Self.first])
        // Nothing selected: the items are disabled and choosing writes nothing.
        world.window.selection.model.clear()
        #expect(!menus.validateMenuItem(firstItem))
        let count = world.document.changeCount
        menus.chooseFamily(firstItem)
        menus.chooseFamily(NSMenuItem())
        await world.settle()
        #expect(world.document.changeCount == count)
        // No window: nothing is added.
        let empty = FontMenus()
        let bare = NSMenu(title: FontCommands.fontMenu)
        empty.menuNeedsUpdate(bare)
        empty.menuNeedsUpdate(NSMenu(title: "Other"))
        #expect(bare.items.isEmpty)
    }

    @Test func aMissingFontShowsInBracketsWithAWarning() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Missing")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.fontFamily = "NoSuchFamilyAnywhere" })).value
        await world.settle()
        let menu = Self.fontMenu(Self.menus(world, recents: Self.recents()))
        #expect(menu.items.contains { $0.title == "Missing Fonts" })
        let missing = try #require(Self.item(menu, "NoSuchFamilyAnywhere"))
        #expect(missing.title == "[NoSuchFamilyAnywhere]" && missing.image != nil && missing.state == .on)
        #expect(missing.toolTip?.contains("Missing") == true)
    }

    @Test func theStyleMenuAddsTheFamilysOtherFaces() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let menus = Self.menus(world, recents: Self.recents())
        let node = try await world.block("Faces")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.fontFamily = "Helvetica" })).value
        await world.settle()
        let menu = NSMenu(title: FontCommands.styleMenu)
        menu.addItem(NSMenuItem(title: "Plain", action: nil, keyEquivalent: ""))
        menus.menuNeedsUpdate(menu)
        let light = try #require(menu.items.first { $0.representedObject as? String == "Light" })
        #expect(!menu.items.contains { $0.representedObject as? String == "Bold" }, "the four commands stand for those")
        menus.menuNeedsUpdate(menu)
        #expect(menu.items.filter { $0.representedObject as? String == "Light" }.count == 1, "filled again, not twice")
        menus.chooseFace(light)
        await world.settle()
        #expect(TextFixtureReading.style(world, node) == "Light" && world.document.undoTitle == "Undo Font Style")
        menus.menuNeedsUpdate(menu)
        #expect(menu.items.first { $0.representedObject as? String == "Light" }?.state == .on)
        menus.chooseFace(NSMenuItem())
        #expect(FontCommands.apply(style: "", window: world.window) == nil)
        // A family with only the standard faces adds nothing.
        world.window.selection.model.clear()
        let plain = NSMenu(title: FontCommands.styleMenu)
        menus.menuNeedsUpdate(plain)
        #expect(plain.items.isEmpty)
    }

    @Test func theMenusAreFilledThroughTheBuilderInTheMenuBarAndTheContextMenus() {
        #expect(FontMenus.delegate(for: ["Text", "Font"]) === FontMenus.shared)
        #expect(FontMenus.delegate(for: ["Context", "Style"]) === FontMenus.shared)
        #expect(FontMenus.delegate(for: ["Font"]) == nil && FontMenus.delegate(for: ["Text", "Size"]) == nil)
        #expect(FontMenus.delegate(for: ["Modify", "Font"]) == nil)
        var target: AnyObject?
        var action: Selector?
        let key = try! #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(!FontMenus.shared.menuHasKeyEquivalent(NSMenu(), for: key, target: &target, action: &action))
        let registry = CommandRegistry()
        ContextMenuCatalog.register(into: registry)
        for command in FontCommands.commands(window: { nil }) { registry.replace(command) }
        let previous = MainMenuBuilder.dynamicMenus
        MainMenuBuilder.dynamicMenus = { FontMenus.delegate(for: $0) }
        defer { MainMenuBuilder.dynamicMenus = previous }
        let menuTarget = CommandMenuTarget(registry: registry)
        let bar = MainMenuBuilder.menuBar(registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: registry.commands), target: menuTarget)
        let text = try! #require(bar.items.first { $0.title == "Text" }?.submenu)
        let font = try! #require(text.items.first { $0.title == "Font" }?.submenu)
        let size = try! #require(text.items.first { $0.title == "Size" }?.submenu)
        #expect(font.delegate === FontMenus.shared && size.delegate == nil)
        #expect(size.items.compactMap { CommandMenuTarget.commandID(of: $0) } == TypeSizes.presets.map { FontCommands.ID.size(Int($0)) }
            + [FontCommands.ID.smaller, FontCommands.ID.larger, FontCommands.ID.sizeOther])
        #expect(size.items.contains { $0.isSeparatorItem })
        let larger = try! #require(size.items.first { CommandMenuTarget.commandID(of: $0) == FontCommands.ID.larger })
        #expect(larger.keyEquivalent == "." && larger.keyEquivalentModifierMask == [.command, .shift])
        // The text context menus.
        let context = MainMenuBuilder.contextMenu(for: .textEditing, registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: registry.commands), menuTarget: menuTarget)
        let contextFont = try! #require(context.items.first { $0.title == "Font" }?.submenu)
        let contextSize = try! #require(context.items.first { $0.title == "Size" }?.submenu)
        #expect(contextFont.delegate === FontMenus.shared)
        #expect(contextSize.items.compactMap { CommandMenuTarget.commandID(of: $0) }.suffix(3) == [FontCommands.ID.smaller, FontCommands.ID.larger, FontCommands.ID.sizeOther])
        let block = ContextMenuBuilder.nodes(for: .objects([.text]), registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: registry.commands))
        #expect(block.contains { $0.title == "Font" } && block.contains { $0.title == "Size" })
    }

    // MARK: Size menu

    @Test func aSizePresetChangesABlockAndARange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let commands = Self.commands(world)
        let node = try await world.block("Presets")
        let preset = try #require(commands[FontCommands.ID.size(24)])
        #expect(preset.title == "24 pt" && preset.menuPath == MenuPath("Text", "Size", section: 1) && preset.contexts == Set<MenuContext>([.text, .textEditing]))
        #expect(preset.validation() == .checked(false))
        Self.run(preset)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [24] && world.document.undoTitle == "Undo Size")
        #expect(preset.validation() == .checked(true))
        await world.edit(node, select: 0..<3)
        Self.run(commands[FontCommands.ID.size(9)])
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [9, 24])
        world.window.objectEditing.textSession = nil
        world.window.selection.model.set(Selection([SelectionID(node)]))
        #expect(preset.validation() == .checked(false), "mixed: no preset is checked")
        world.window.selection.model.clear()
        #expect(!preset.validation().isEnabled && preset.validation().reason == FontCommands.noText)
        #expect(FontCommands.apply(size: 0.5, window: world.window) == nil)
    }

    @Test func smallerAndLargerStepEveryRunOnBlocksAndAddUpWhileEditing() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let commands = Self.commands(world)
        let smaller = try #require(commands[FontCommands.ID.smaller])
        let larger = try #require(commands[FontCommands.ID.larger])
        #expect(smaller.defaultKey == KeyEquivalent(",", [.command, .shift]) && larger.defaultKey == KeyEquivalent(".", [.command, .shift]))
        #expect(smaller.menuPath?.subsection == 1)
        let node = try await world.block("Step sizes")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: TextFixtureReading.anchor(world, node, 4), value: .with { $0.size = 24 })).value
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [12, 24])
        let before = world.document.changeCount
        Self.run(larger)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [13, 25] && world.document.changeCount == before + 1, "each run, one change")
        #expect(world.document.undoTitle == "Undo Size")
        Self.run(smaller)
        await world.settle()
        Self.run(smaller)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [11, 23])
        // The ends of the range.
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.size = 1 })).value
        await world.settle()
        #expect(!smaller.validation().isEnabled && larger.validation().isEnabled)
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.size = 10_000 })).value
        await world.settle()
        #expect(smaller.validation().isEnabled && !larger.validation().isEnabled)
        Self.run(larger)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [10_000])
        // While editing a range: the nudger adds the steps up and writes them once.
        await world.edit(node, select: 0..<4)
        let editing = world.document.changeCount
        Self.run(smaller)
        Self.run(smaller)
        _ = await TypeNudger.nudger(for: world.window.objectEditing).flush()?.value
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [9_998, 10_000] && world.document.changeCount == editing + 1)
        #expect(FontCommands.step(1, window: world.window) == nil, "the nudger writes later")
        _ = await TypeNudger.nudger(for: world.window.objectEditing).flush()?.value
        // Nothing selected.
        world.window.objectEditing.textSession = nil
        world.window.selection.model.clear()
        #expect(!smaller.validation().isEnabled && !larger.validation().isEnabled)
        #expect(FontCommands.step(1, window: world.window) == nil && FontCommands.step(1, window: nil) == nil)
    }

    // MARK: Other… sheets

    @Test func theSizeSheetTakesOneToTenThousandPoints() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let sheets = FontSheets(recents: Self.recents())
        let commands = Self.commands(world, sheets: sheets)
        let node = try await world.block("Other size")
        let other = try #require(commands[FontCommands.ID.sizeOther])
        #expect(other.validation() == .checked(false) || other.validation().isEnabled)
        let model = SizeSheetModel(size: 12)
        #expect(model.text == "12" && model.size == 12)
        model.text = "13.5 pt"
        #expect(model.size == 13.5)
        var closed = 0
        let sheet = sheets.sizeSheet(model, window: world.window) { closed += 1 }
        PanelRendering.host(sheet)
        SizeSheet.committing(model, sheet.commit)()
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [13.5] && closed == 1 && world.document.undoTitle == "Undo Size")
        #expect(other.validation().title == "Other (13.5 pt)…" && other.validation().isChecked)
        model.text = "20000"
        #expect(model.size == nil)
        PanelRendering.host(SizeSheet(model: model, commit: { _ in }, cancel: {}))
        SizeSheet.committing(model) { _ in Issue.record("an invalid size is not committed") }()
        #expect(SizeSheetModel(size: nil).text.isEmpty)
        // The command presents the sheet.
        Self.run(other)
        let presented = try #require(world.window.window?.attachedSheet)
        #expect(presented.identifier?.rawValue == SizeSheetModel.sheet)
        world.window.window?.endSheet(presented)
        Self.run(commands[FontCommands.ID.fontSize])
        if let again = world.window.window?.attachedSheet { world.window.window?.endSheet(again) }
        world.window.selection.model.clear()
        #expect(!other.validation().isEnabled)
    }

    @Test func theFontSheetFiltersAndWritesFamilyAndFaceAsOneChange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let recents = Self.recents()
        let sheets = FontSheets(recents: recents)
        let node = try await world.block("Other font")
        let model = sheets.fontModel(for: world.window)
        #expect(model.family == ObjectPanelModel.defaultFamily && model.style == ObjectPanelModel.defaultStyle)
        model.query = "menl"
        #expect(model.choices.first?.family == Self.first)
        model.query = ""
        #expect(model.choices.count == model.list.flattened.count)
        model.choose("Helvetica")
        #expect(model.style == "Regular" && model.faces.contains("Light"))
        model.style = "Light"
        model.choose("Helvetica")
        #expect(model.style == "Light", "a face the family has stays")
        FontSheet.style(model).wrappedValue = "Bold"
        FontSheet.selection(model).wrappedValue = Self.first
        FontSheet.selection(model).wrappedValue = nil
        #expect(model.family == Self.first && model.style == "Bold")
        #expect(FontSheet.style(model).wrappedValue == "Bold" && FontSheet.selection(model).wrappedValue == Self.first)
        model.style = "Nonesuch"
        #expect(model.faces.first == "Nonesuch")
        model.style = "Bold"
        var closed = 0
        let sheet = sheets.fontSheet(model, window: world.window) { closed += 1 }
        PanelRendering.host(sheet)
        let before = world.document.changeCount
        FontSheet.committing(model, sheet.commit)()
        await world.settle()
        #expect(Self.families(world, node) == [Self.first] && TextFixtureReading.style(world, node) == "Bold")
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Font" && closed == 1)
        #expect(recents.families == [Self.first])
        // Without a face the family alone; nothing chosen, nothing written.
        _ = await world.window.flatMapModel { $0.setFont(family: Self.second, style: nil) }?.value
        await world.settle()
        #expect(Self.families(world, node) == [Self.second])
        #expect(FontCommands.model(world.window)?.setFont(family: "", style: nil) == nil)
        let blank = FontSheetModel(list: model.list, family: nil, style: nil) { _ in [] }
        #expect(!blank.canCommit && blank.faces.isEmpty)
        FontSheet.committing(blank) { _, _ in Issue.record("nothing chosen") }()
        blank.choose("Empty")
        #expect(blank.style == nil)
        // The commands present the sheet.
        let commands = Self.commands(world, sheets: sheets)
        for id in [FontCommands.ID.fontOther, FontCommands.ID.family, FontCommands.ID.style] {
            #expect(commands[id]?.validation().isEnabled == true)
            Self.run(commands[id])
            let presented = try #require(world.window.window?.attachedSheet)
            #expect(presented.identifier?.rawValue == FontSheetModel.sheet)
            world.window.window?.endSheet(presented)
        }
        world.window.selection.model.clear()
        #expect(commands[FontCommands.ID.fontOther]?.validation().reason == FontCommands.noText)
    }

    // MARK: Text toolbar

    @Test func theToolbarsFamilyStyleAndSizeControlsApplyAndShowMixed() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let recents = Self.recents()
        let window: FontCommands.Window = { [weak window = world.window] in window }
        let makers = FontToolbarControls.makers(window: window, recents: recents)
        let family = try #require(makers[FontCommands.ID.family]?() as? FontFamilyPicker)
        let style = try #require(makers[FontCommands.ID.style]?() as? StylePopUp)
        let size = try #require(makers[FontCommands.ID.fontSize]?() as? SizeComboBox)
        // Nothing selected: disabled.
        family.refresh()
        style.refresh()
        size.refresh()
        #expect(!family.isEnabled && !style.isEnabled && !size.isEnabled)
        #expect(family.openList(nil) == nil)
        let node = try await world.block("Toolbar")
        family.refresh()
        style.refresh()
        size.refresh()
        #expect(family.isEnabled && family.title == ObjectPanelModel.defaultFamily && size.stringValue == "12")
        #expect(style.titleOfSelectedItem == ObjectPanelModel.defaultStyle)
        // The family list filters as you type; Return chooses.
        let list = try #require(family.openList(nil))
        list.filter("menlo")
        #expect(list.model.selectedFamily == Self.first)
        list.handle(#selector(NSResponder.insertNewline(_:)))
        await world.settle()
        #expect(Self.families(world, node) == [Self.first] && recents.families == [Self.first])
        #expect(family.title == Self.first)
        #expect(family.makeModel()?.choices.first?.family == Self.first, "recent first")
        // The face pop-up.
        style.refresh()
        style.selectItem(withTitle: "Bold")
        style.choose(nil)
        await world.settle()
        #expect(TextFixtureReading.style(world, node) == "Bold")
        // The size box: a preset or any size; nonsense is ignored.
        size.stringValue = "18"
        size.commit(nil)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [18])
        size.stringValue = "big"
        size.commit(nil)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [18])
        // A range with the Text tool.
        await world.edit(node, select: 0..<3)
        size.stringValue = "30"
        size.commit(nil)
        family.choose(Self.second)
        await world.settle()
        #expect(TextFixtureReading.sizes(world, node) == [18, 30] && Set(Self.families(world, node)) == [Self.first, Self.second])
        // Mixed over the whole block.
        world.window.objectEditing.textSession = nil
        world.window.selection.model.set(Selection([SelectionID(node)]))
        family.refresh()
        size.refresh()
        style.refresh()
        #expect(family.title == TextSectionView.mixed && family.family == nil)
        #expect(size.stringValue.isEmpty && size.placeholderString == TextSectionView.mixed)
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: TextFixtureReading.anchor(world, node, 2), value: .with { $0.fontStyle = "Italic" })).value
        await world.settle()
        style.refresh()
        #expect(style.titleOfSelectedItem == TextSectionView.mixed)
        style.choose(nil)
        #expect(StylePopUp.titles(family: nil, style: nil) { _ in [] } == [TextSectionView.mixed])
        #expect(StylePopUp.titles(family: "F", style: "Odd") { _ in ["Regular"] } == ["Odd", "Regular"])
    }

    @Test func theToolbarViewDrawsACommandsOwnControl() async throws {
        let fixture = ToolbarFixture()
        let controller = fixture.controller
        let view = ToolbarView(controller: controller, toolbar: .text)
        #expect(zip(view.arranged, view.buttons).allSatisfy { $0 === $1 })
        var refreshed = 0
        final class Probe: NSView, ToolbarControl {
            var onRefresh: () -> Void = {}
            func refresh() { onRefresh() }
        }
        let probe = Probe(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        probe.onRefresh = { refreshed += 1 }
        controller.controls = [FontCommands.ID.family: { probe }]
        #expect(view.arranged.first === probe && view.buttons.first?.command == FontCommands.ID.family)
        #expect(refreshed > 0)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 30)
        view.layout()
        view.layoutSubtreeIfNeeded()
        #expect(view.insertionIndex(at: NSPoint(x: 0, y: 10)) == 0)
        controller.controls = [:]
        #expect(view.arranged.first === view.buttons.first)
    }
}

extension DocumentWindowController {
    /// Runs `body` on the font controls' model of this window's selection.
    @MainActor
    func flatMapModel<T>(_ body: (ObjectPanelModel) -> T?) -> T? {
        FontCommands.model(self).flatMap(body)
    }
}
