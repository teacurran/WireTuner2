import AppKit
import Testing
import WTModel
import WTText
@testable import WireTuner

/// The Text toolbar's font family picker (D-077 revised): a button showing the family, and a list
/// sized to the longest name, each family in its own face, filtered as you type.
@Suite(.serialized) @MainActor struct FontFamilyPickerTests {
    static func picker(_ world: TypeWorld, recents: FontRecentsStore = FontControlTests.recents()) -> FontFamilyPicker {
        FontFamilyPicker(window: { [weak window = world.window] in window }, recents: recents)
    }

    static func list(recent: [String] = [], installed: [String], document: Set<String> = [], missing: Set<String> = []) -> FontFamilyList {
        FontFamilyList(installed: installed, recents: recent, documentFamilies: document, isAvailable: { !missing.contains($0) })
    }

    // MARK: The button

    @Test func theButtonShowsTheFamilyAtRegularSizeAndMixed() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let picker = Self.picker(world)
        picker.refresh()
        #expect(!picker.isEnabled && picker.title.isEmpty && picker.toolTip == nil)
        #expect(picker.controlSize == .regular && picker.font?.pointSize == 13)
        #expect(picker.takesFullRow && picker.minimumToolbarWidth == FontFamilyPicker.minimumWidth && picker.toolbarSize.width == FontFamilyPicker.naturalWidth)
        #expect((picker.cell as? NSButtonCell)?.lineBreakMode == .byTruncatingTail)
        let node = try await world.block("Mixed text")
        picker.refresh()
        #expect(picker.isEnabled && picker.title == ObjectPanelModel.defaultFamily && picker.toolTip == "Font Family: \(ObjectPanelModel.defaultFamily)")
        // Two families: Mixed, and the list opens on its first family.
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: TextFixtureReading.anchor(world, node, 3), value: .with { $0.fontFamily = "Menlo" })).value
        await world.settle()
        picker.refresh()
        #expect(picker.title == FontToolbarControls.mixed && picker.family == nil && picker.toolTip == "Font Family: Mixed")
        let model = try #require(picker.makeModel())
        #expect(model.current == nil && model.selection == model.entries.firstIndex { $0.choice != nil })
        // The style pop-up and size box are regular size too.
        let style = StylePopUp(window: { [weak window = world.window] in window })
        let size = SizeComboBox(window: { [weak window = world.window] in window })
        #expect(style.controlSize == .regular && style.font?.pointSize == 13 && size.controlSize == .regular && size.font?.pointSize == 13)
        #expect(style.minimumToolbarWidth < style.toolbarSize.width && size.minimumToolbarWidth < size.toolbarSize.width)
    }

    @Test func choosingFromTheListAppliesTheFamilyAsOneChange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let recents = FontControlTests.recents()
        let picker = Self.picker(world, recents: recents)
        let node = try await world.block("Choose")
        picker.refresh()
        let list = try #require(picker.openList(nil))
        #expect(picker.list === list && list.model.selectedFamily == ObjectPanelModel.defaultFamily, "opens on the current family")
        let before = world.document.changeCount
        list.filter("Georgia")
        list.choose()
        await world.settle()
        #expect(FontControlTests.families(world, node) == ["Georgia"])
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Font")
        #expect(picker.title == "Georgia" && picker.list == nil && recents.families == ["Georgia"])
        picker.refresh()
        #expect(picker.title == "Georgia")
        // The same family again changes nothing; a click on a family chooses it.
        picker.choose("Georgia")
        await world.settle()
        #expect(world.document.changeCount == before + 1)
        let again = try #require(picker.openList(nil))
        #expect(again.model.choices.first?.family == "Georgia", "recent first")
        again.table.reloadData()
        again.clicked(nil)
        #expect(picker.list === again, "a click off the rows does nothing")
        // Without text the choice is dropped.
        world.window.selection.model.clear()
        picker.choose("Menlo")
        #expect(picker.title == "Georgia")
    }

    @Test func theListIsSizedToTheLongestNamesAndShowsThemWhole() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let picker = Self.picker(world)
        _ = try await world.block("Long names")
        picker.refresh()
        let list = try #require(picker.openList(nil))
        let installed = world.document.textEngine.fonts.families()
        let longest = installed.sorted { $0.count > $1.count }.prefix(20)
        #expect(longest.count == min(20, installed.count))
        #expect(list.listWidth > FontFamilyPicker.naturalWidth, "the list is not the button's width")
        #expect(list.contentSize.width > list.listWidth)
        for family in longest {
            let choice = FontFamilyChoice(family: family, inDocument: false, isMissing: false)
            #expect(FontFamilyFaces.rowWidth(choice) <= list.listWidth, "\(family) fits")
            let row = FontFamilyRowView(choice: choice, width: list.listWidth)
            row.layoutRow()
            #expect(row.showsWholeNames, "\(family) is not truncated")
            #expect(row.name.stringValue == family)
        }
        // Each family in its own face.
        let georgia = FontFamilyRowView(choice: FontFamilyChoice(family: "Georgia", inDocument: true, isMissing: false), width: list.listWidth)
        #expect((georgia.name.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName == "Georgia")
        #expect(georgia.mark.image != nil && georgia.toolTip == "Used in this document")
        georgia.frame.size.height = 40
        georgia.layout()
        #expect(georgia.name.frame.minY > 0)
        #expect(FontFamilyFaces.listWidth([], screenWidth: 1_000) == FontFamilyFaces.minimumListWidth)
        let huge = FontFamilyChoice(family: String(repeating: "W", count: 400), inDocument: false, isMissing: true)
        #expect(FontFamilyFaces.listWidth([huge], screenWidth: 1_000) == 900, "within the screen")
    }

    @Test func symbolFontsAndMissingFontsAreMarked() async throws {
        let menlo = try #require(NSFont(name: "Menlo-Regular", size: 15))
        #expect(FontFamilyFaces.isReadable("Menlo", in: menlo))
        #expect(!FontFamilyFaces.isReadable("漢字", in: menlo), "a face without the letters")
        let missing = FontFamilyChoice(family: "No Such Family", inDocument: true, isMissing: true)
        #expect(FontFamilyFaces.title(missing).string == "[No Such Family]" && !FontFamilyFaces.showsPlainName(missing))
        let row = FontFamilyRowView(choice: missing, width: 400)
        #expect(row.mark.image != nil && row.toolTip == "Missing on this Mac: drawn in a substitute" && row.plain.superview == nil)
        #expect(FontFamilyFaces.face("No Such Family").font == nil)
        // A symbol font shows its plain name beside its own face.
        let symbolic = NSFontManager.shared.availableFontFamilies.first { FontFamilyFaces.showsPlainName(FontFamilyChoice(family: $0, inDocument: false, isMissing: false)) }
        if let symbolic {
            let choice = FontFamilyChoice(family: symbolic, inDocument: false, isMissing: false)
            let symbolRow = FontFamilyRowView(choice: choice, width: FontFamilyFaces.rowWidth(choice))
            #expect(symbolRow.plain.superview != nil && symbolRow.plain.stringValue == symbolic && symbolRow.showsWholeNames)
            #expect((symbolRow.plain.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == FontFamilyFaces.plainSize)
        }
        // The document's missing fonts come after the recent ones, marked.
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Missing")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.fontFamily = "No Such Family" })).value
        await world.settle()
        let picker = Self.picker(world)
        picker.refresh()
        let model = try #require(picker.makeModel())
        #expect(model.entries.first == .header(FontFamilyPickerModel.missingHeader))
        #expect(model.entries[1].choice?.isMissing == true && model.selectedFamily == "No Such Family")
    }

    // MARK: Search and keys

    @Test func theSearchFieldFiltersAsYouType() {
        let model = FontFamilyPickerModel(list: Self.list(recent: ["Menlo"], installed: ["Georgia", "Helvetica", "Menlo", "Gill Sans"]), current: "Helvetica")
        #expect(model.entries == [
            .header(FontFamilyPickerModel.recentHeader), .family(FontFamilyChoice(family: "Menlo", inDocument: false, isMissing: false)),
            .header(FontFamilyPickerModel.allHeader),
            .family(FontFamilyChoice(family: "Georgia", inDocument: false, isMissing: false)),
            .family(FontFamilyChoice(family: "Helvetica", inDocument: false, isMissing: false)),
            .family(FontFamilyChoice(family: "Menlo", inDocument: false, isMissing: false)),
            .family(FontFamilyChoice(family: "Gill Sans", inDocument: false, isMissing: false)),
        ])
        #expect(model.selectedFamily == "Helvetica")
        model.setQuery("g")
        #expect(model.choices.map(\.family) == ["Georgia", "Gill Sans"], "starting with it first, each family once")
        #expect(model.selectedFamily == "Georgia")
        model.setQuery("g")
        model.setQuery("s")
        #expect(model.choices.map(\.family) == ["Gill Sans", "Helvetica"] || model.choices.map(\.family) == ["Gill Sans"])
        model.setQuery("zzz")
        #expect(model.entries.isEmpty && model.selection == nil && model.selectedFamily == nil)
        model.move(by: 1)
        #expect(model.selection == nil)
        model.setQuery("")
        #expect(model.entries.count == 7)
    }

    @Test func theListFiltersAndTakesTheArrowsReturnAndEscape() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let picker = Self.picker(world)
        let node = try await world.block("Keys")
        picker.refresh()
        let list = try #require(picker.openList(nil))
        // Typing in the search field filters.
        list.search.stringValue = "Menl"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(list.model.choices.first?.family == "Menlo" && list.table.numberOfRows == list.model.entries.count)
        #expect(list.table.selectedRow == list.model.selection)
        list.filter("")
        // Arrows move the selection over families, skipping the headings, and stop at the ends.
        let start = try #require(list.model.selection)
        #expect(list.control(list.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(try #require(list.model.selection) > start && list.model.isSelectable(list.model.selection!))
        list.handle(#selector(NSResponder.moveUp(_:)))
        #expect(list.model.selection == start)
        for _ in 0..<5_000 { list.model.move(by: -1) }
        #expect(list.model.selection == list.model.entries.firstIndex { $0.choice != nil })
        list.model.move(by: 100_000)
        #expect(list.model.selection == list.model.entries.lastIndex { $0.choice != nil })
        #expect(!list.handle(#selector(NSResponder.insertTab(_:))))
        // Type-ahead jumps to a family (in All Fonts); a heading has no type-select string.
        list.typeAhead("geor")
        #expect(list.model.selectedFamily == "Georgia" && list.table.selectedRow == list.model.selection)
        #expect(list.model.typeAhead("   ") == nil && list.model.typeAhead("zzzzzz") == nil)
        let heading = try #require(list.model.entries.firstIndex { $0.choice == nil })
        #expect(list.tableView(list.table, typeSelectStringFor: nil, row: heading) == nil)
        #expect(list.tableView(list.table, typeSelectStringFor: nil, row: list.model.selection!) == "Georgia")
        #expect(list.tableView(list.table, isGroupRow: heading) && !list.tableView(list.table, shouldSelectRow: heading))
        #expect(list.cell(forRow: heading) is NSTextField && list.tableView(list.table, viewFor: nil, row: heading + 1) is FontFamilyRowView)
        list.model.select(heading)
        #expect(list.model.selectedFamily == "Georgia", "a heading is not selected")
        // Escape closes; Return in the table chooses.
        list.handle(#selector(NSResponder.cancelOperation(_:)))
        #expect(picker.list == nil)
        let reopened = try #require(picker.openList(nil))
        reopened.typeAhead("Menlo")
        let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        reopened.table.keyDown(with: returnKey)
        await world.settle()
        #expect(FontControlTests.families(world, node) == ["Menlo"] && picker.list == nil)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        let third = try #require(picker.openList(nil))
        third.table.keyDown(with: escape)
        #expect(picker.list == nil)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        third.table.keyDown(with: down)
        // With nothing selected, Return chooses nothing.
        third.filter("zzzzzz")
        third.choose()
        #expect(FontControlTests.families(world, node) == ["Menlo"])
    }

    @Test func theListOpensInAPopoverFromAWindow() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let picker = Self.picker(world)
        _ = try await world.block("Popover")
        let content = try #require(world.window.window?.contentView)
        picker.frame = NSRect(x: 20, y: 20, width: 200, height: 24)
        content.addSubview(picker)
        defer { picker.removeFromSuperview() }
        #expect(picker.hostedDocumentWindow === world.window)
        let list = try #require(picker.openList(nil))
        #expect(picker.popover?.contentViewController === list)
        #expect(picker.popover?.contentSize.width == list.contentSize.width)
        list.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        picker.closeList()
        #expect(picker.popover == nil)
    }
}
