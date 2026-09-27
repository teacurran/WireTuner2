import Foundation

/// One entry of a context menu layout.
indirect enum ContextMenuEntry: Equatable, Sendable {
    /// A registry command; `title` is the context menu's own wording when it differs from the
    /// menu bar's ("Object Panel", "Rulers").
    case command(CommandID, title: String? = nil)
    case submenu(String, [ContextMenuEntry])
    case separator
}

/// The canvas and tab context menus of context-menus.adoc as data, and the commands they need
/// that no feature has delivered yet.  Every command in a context menu is also in the menu bar
/// with the same shortcut (the page's rule), so each placeholder has a menu path in the Edit,
/// View, Modify, Text or Object menu; it is disabled with the placeholder reason until its epic
/// replaces it (`CommandRegistry.replace` keeps the position).
enum ContextMenuCatalog {
    enum ID {
        static let duplicate: CommandID = "edit.duplicate"
        static let clone: CommandID = "edit.clone"
        static let pasteBehind: CommandID = "edit.special.pasteBehind"
        static let editWith: CommandID = "edit.editWith"
        static let links: CommandID = "edit.links"
        static let copyLinkToObject: CommandID = "edit.copyLinkToObject"
        static let superselect: CommandID = "edit.select.superselect"
        static let subselect: CommandID = "edit.select.subselect"

        static let group: CommandID = "modify.group"
        static let ungroup: CommandID = "modify.ungroup"
        static let lock: CommandID = "modify.lock"
        static let unlock: CommandID = "modify.unlock"
        static let groupTransformsAsUnit: CommandID = "modify.groupTransformsAsUnit"
        static let enterGroup: CommandID = "modify.enterGroup"
        static let bringToFront: CommandID = "modify.arrange.bringToFront"
        static let bringForward: CommandID = "modify.arrange.bringForward"
        static let sendBackward: CommandID = "modify.arrange.sendBackward"
        static let sendToBack: CommandID = "modify.arrange.sendToBack"
        static let alignLeft: CommandID = "modify.align.left"
        static let alignCenterHorizontal: CommandID = "modify.align.centerHorizontal"
        static let alignRight: CommandID = "modify.align.right"
        static let alignTop: CommandID = "modify.align.top"
        static let alignCenterVertical: CommandID = "modify.align.centerVertical"
        static let alignBottom: CommandID = "modify.align.bottom"
        static let transformRotate: CommandID = "modify.transform.rotate"
        static let transformScale: CommandID = "modify.transform.scale"
        static let transformSkew: CommandID = "modify.transform.skew"
        static let transformReflect: CommandID = "modify.transform.reflect"
        static let transformMove: CommandID = "modify.transform.move"
        static let union: CommandID = "modify.combine.union"
        static let divide: CommandID = "modify.combine.divide"
        static let intersect: CommandID = "modify.combine.intersect"
        static let punch: CommandID = "modify.combine.punch"
        static let crop: CommandID = "modify.combine.crop"
        static let transparency: CommandID = "modify.combine.transparency"
        static let combineBlend: CommandID = "modify.combine.blend"
        static let join: CommandID = "modify.join"
        static let split: CommandID = "modify.split"
        static let closePath: CommandID = "modify.closePath"
        static let reverseDirection: CommandID = "modify.alterPath.reverseDirection"
        static let removeOverlap: CommandID = "modify.alterPath.removeOverlap"
        static let simplify: CommandID = "modify.alterPath.simplify"
        static let expandStroke: CommandID = "modify.alterPath.expandStroke"
        static let insetPath: CommandID = "modify.alterPath.insetPath"
        static let blendSteps: CommandID = "modify.blend.steps"
        static let blendRelease: CommandID = "modify.blend.release"
        static let releaseContents: CommandID = "modify.clip.releaseContents"
        static let editContents: CommandID = "modify.clip.editContents"
        static let reroute: CommandID = "modify.connector.reroute"
        static let detachEnds: CommandID = "modify.connector.detachEnds"
        static let releaseInstance: CommandID = "modify.symbol.releaseInstance"
        static let editSymbol: CommandID = "modify.symbol.editSymbol"
        static let showInLibrary: CommandID = "modify.symbol.showInLibrary"
        static let envelopeShowMap: CommandID = "envelope.showMap"
        static let envelopeCopyAsPath: CommandID = "envelope.copyAsPath"
        static let envelopeRelease: CommandID = "envelope.release"
        static let envelopeRemove: CommandID = "envelope.remove"

        static let textEditor: CommandID = "text.editor"
        static let fontOther: CommandID = "text.font.other"
        static let attachToPath: CommandID = "text.attachToPath"
        static let detachFromPath: CommandID = "text.detachFromPath"
        static let flowInsidePath: CommandID = "text.flowInsidePath"
        static let convertToPaths: CommandID = "text.convertToPaths"
        static let spelling: CommandID = "text.spelling"
        static let runAround: CommandID = "text.runAround"
        static func size(_ points: Int) -> CommandID { CommandID("text.size.\(points)") }
        static func style(_ name: String) -> CommandID { CommandID("text.style.\(name)") }
        static func align(_ name: String) -> CommandID { CommandID("text.align.\(name)") }
        static func leading(_ name: String) -> CommandID { CommandID("text.leading.\(name)") }
        static func convertCase(_ name: String) -> CommandID { CommandID("text.case.\(name)") }
        static func specialCharacter(_ name: String) -> CommandID { CommandID("text.special.\(name)") }
        static func checkSpelling(_ name: String) -> CommandID { CommandID("text.spelling.\(name)") }

        static let trace: CommandID = "object.image.trace"
        static let imageCrop: CommandID = "object.image.crop"
        static let convertToEditable: CommandID = "object.convertToEditable"
        static let chartEditData: CommandID = "object.chart.editData"
        static let chartType: CommandID = "object.chart.type"
        static let addToLibrary: CommandID = "object.addToLibrary"
        static let name: CommandID = "object.name"
        static let note: CommandID = "object.note"
        static let link: CommandID = "object.link"
        static let addPage: CommandID = "page.add"
        static let duplicatePage: CommandID = "page.duplicate"
        static let removePage: CommandID = "page.remove"
        static let goToPage: CommandID = "page.goTo"

        static let lockGuide: CommandID = "view.guides.lockGuide"
        static let releaseGuide: CommandID = "view.guides.release"
        static let deleteGuide: CommandID = "view.guides.delete"
        static let follow: CommandID = "presence.follow"
        static let goToCollaboratorPage: CommandID = "presence.goToPage"
        static let hideCursor: CommandID = "presence.hideCursor"

        static let closeTab: CommandID = "window.closeTab"
        static let closeOtherTabs: CommandID = "window.closeOtherTabs"
        static let renameDocument: CommandID = "file.renameDocument"
        static let share: CommandID = "file.share"
        static let showDocumentInLibrary: CommandID = "file.showInLibrary"

        /// The context menu's View ▸ levels beyond the menu bar's 25%–800% (6% to 25,600%).
        static func contextMagnification(_ percent: Int) -> CommandID { StandardCommands.ID.magnification(percent) }
    }

    enum Menu {
        static let modify = "Modify"
        static let text = "Text"
        static let object = "Object"
    }

    /// The object kinds' contexts plus the multiple selection.
    static let objectContexts: Set<MenuContext> = Set(ContextObjectKind.allCases.map(\.context)).union([.multiple])

    static let placeholderReason = Command.placeholderReason
    static let textSizes = [9, 10, 12, 14, 18, 24, 36, 48, 72]
    static let textStyles = [("plain", "Plain"), ("bold", "Bold"), ("italic", "Italic"), ("boldItalic", "Bold Italic")]
    static let textAlignments = [("left", "Left"), ("center", "Center"), ("right", "Right"), ("justified", "Justified")]
    static let leadings = [("solid", "Solid"), ("auto", "Auto"), ("other", "Other…")]
    static let cases = [("upper", "UPPERCASE"), ("lower", "lowercase"), ("title", "Title Case")]
    static let specialCharacters = [("emDash", "Em Dash"), ("enDash", "En Dash"), ("nonBreakingSpace", "Non-breaking Space")]
    static let spellingItems = [("check", "Check Spelling…"), ("whileTyping", "Check Spelling While Typing")]
    /// Every preset of the zoom ladder, for the pasteboard menu's View ▸.
    static let contextMagnifications = [6, 12, 25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600]

    // MARK: Placeholders

    private static func stub(_ id: CommandID, _ title: String, _ path: MenuPath?, key: KeyEquivalent? = nil) -> Command {
        .placeholder(id: id, title: title, key: key, menu: path)
    }

    /// The commands the context menus name that no task has delivered, each where the menu
    /// bar has it.  Registered only when absent, so a feature that already registered its
    /// command keeps it.
    static func placeholders() -> [Command] {
        let edit = StandardCommands.Menu.edit
        let modify = Menu.modify, text = Menu.text, object = Menu.object
        let view = StandardCommands.Menu.view
        var result: [Command] = [
            stub(ID.duplicate, "Duplicate", MenuPath(edit, section: 1), key: KeyEquivalent("d", .command)),
            stub(ID.clone, "Clone", MenuPath(edit, section: 1)),
            stub(ID.pasteBehind, "Paste Behind", MenuPath(edit, "Special", section: 1)),
            stub(ID.editWith, "Edit With", MenuPath(edit, section: 1)),
            stub(ID.links, "Links…", MenuPath(edit, section: 1)),
            stub(ID.copyLinkToObject, "Copy Link to Object", MenuPath(edit, section: 1)),
            stub(ID.superselect, "Superselect", MenuPath(edit, SelectionCommands.submenu, section: 1)),
            stub(ID.subselect, "Subselect", MenuPath(edit, SelectionCommands.submenu, section: 1)),

            stub(ID.group, "Group", MenuPath(modify, section: 0), key: KeyEquivalent("g", .command)),
            stub(ID.ungroup, "Ungroup", MenuPath(modify, section: 0), key: KeyEquivalent("g", [.command, .shift])),
            stub(ID.groupTransformsAsUnit, "Group Transforms as Unit", MenuPath(modify, section: 0)),
            stub(ID.enterGroup, "Enter Group", MenuPath(modify, section: 0)),
            stub(ID.lock, "Lock", MenuPath(modify, section: 1), key: KeyEquivalent("l", .command)),
            stub(ID.unlock, "Unlock", MenuPath(modify, section: 1), key: KeyEquivalent("l", [.command, .shift])),
            stub(ID.bringToFront, "Bring to Front", MenuPath(modify, "Arrange", section: 2)),
            stub(ID.bringForward, "Bring Forward", MenuPath(modify, "Arrange", section: 2)),
            stub(ID.sendBackward, "Send Backward", MenuPath(modify, "Arrange", section: 2)),
            stub(ID.sendToBack, "Send to Back", MenuPath(modify, "Arrange", section: 2)),
            stub(ID.alignLeft, "Left", MenuPath(modify, "Align", section: 2)),
            stub(ID.alignCenterHorizontal, "Center Horizontally", MenuPath(modify, "Align", section: 2)),
            stub(ID.alignRight, "Right", MenuPath(modify, "Align", section: 2)),
            stub(ID.alignTop, "Top", MenuPath(modify, "Align", section: 2)),
            stub(ID.alignCenterVertical, "Center Vertically", MenuPath(modify, "Align", section: 2)),
            stub(ID.alignBottom, "Bottom", MenuPath(modify, "Align", section: 2)),
            stub(ID.transformRotate, "Rotate…", MenuPath(modify, "Transform", section: 2)),
            stub(ID.transformScale, "Scale…", MenuPath(modify, "Transform", section: 2)),
            stub(ID.transformSkew, "Skew…", MenuPath(modify, "Transform", section: 2)),
            stub(ID.transformReflect, "Reflect…", MenuPath(modify, "Transform", section: 2)),
            stub(ID.transformMove, "Move…", MenuPath(modify, "Transform", section: 2)),
            stub(ID.union, "Union", MenuPath(modify, "Combine", section: 3)),
            stub(ID.divide, "Divide", MenuPath(modify, "Combine", section: 3)),
            stub(ID.intersect, "Intersect", MenuPath(modify, "Combine", section: 3)),
            stub(ID.punch, "Punch", MenuPath(modify, "Combine", section: 3)),
            stub(ID.crop, "Crop", MenuPath(modify, "Combine", section: 3)),
            stub(ID.transparency, "Transparency", MenuPath(modify, "Combine", section: 3)),
            stub(ID.combineBlend, "Blend", MenuPath(modify, "Combine", section: 3)),
            stub(ID.join, "Join", MenuPath(modify, section: 3)),
            stub(ID.split, "Split", MenuPath(modify, section: 3)),
            stub(ID.closePath, "Close Path", MenuPath(modify, section: 3)),
            stub(ID.reverseDirection, "Reverse Direction", MenuPath(modify, "Alter Path", section: 3)),
            stub(ID.removeOverlap, "Remove Overlap", MenuPath(modify, "Alter Path", section: 3)),
            stub(ID.simplify, "Simplify", MenuPath(modify, "Alter Path", section: 3)),
            stub(ID.expandStroke, "Expand Stroke…", MenuPath(modify, "Alter Path", section: 3)),
            stub(ID.insetPath, "Inset Path…", MenuPath(modify, "Alter Path", section: 3)),
            stub(ID.blendSteps, "Blend Steps…", MenuPath(modify, "Blend", section: 4)),
            stub(ID.blendRelease, "Release", MenuPath(modify, "Blend", section: 4)),
            stub(ID.releaseContents, "Release Contents", MenuPath(modify, "Clipping", section: 4)),
            stub(ID.editContents, "Edit Contents", MenuPath(modify, "Clipping", section: 4)),
            stub(ID.reroute, "Reroute", MenuPath(modify, "Connector", section: 4)),
            stub(ID.detachEnds, "Detach Ends", MenuPath(modify, "Connector", section: 4)),
            stub(ID.releaseInstance, "Release Instance", MenuPath(modify, "Symbol", section: 4)),
            stub(ID.editSymbol, "Edit Symbol", MenuPath(modify, "Symbol", section: 4)),
            stub(ID.showInLibrary, "Show in Library", MenuPath(modify, "Symbol", section: 4)),
            stub(ID.envelopeShowMap, "Show Map", MenuPath(modify, "Envelope", section: 4)),
            stub(ID.envelopeCopyAsPath, "Copy as Path", MenuPath(modify, "Envelope", section: 4)),
            stub(ID.envelopeRelease, "Release", MenuPath(modify, "Envelope", section: 4)),
            stub(ID.envelopeRemove, "Remove", MenuPath(modify, "Envelope", section: 4)),

            stub(ID.textEditor, "Editor…", MenuPath(text, section: 0)),
            stub(ID.fontOther, "Other…", MenuPath(text, "Font", section: 1)),
        ]
        result += textSizes.map { stub(ID.size($0), "\($0) pt", MenuPath(text, "Size", section: 1)) }
        result += textStyles.map { stub(ID.style($0.0), $0.1, MenuPath(text, "Style", section: 1)) }
        result += textAlignments.map { stub(ID.align($0.0), $0.1, MenuPath(text, "Align", section: 1)) }
        result += leadings.map { stub(ID.leading($0.0), $0.1, MenuPath(text, "Leading", section: 1)) }
        result += specialCharacters.map { stub(ID.specialCharacter($0.0), $0.1, MenuPath(text, "Special Characters", section: 1)) }
        result += cases.map { stub(ID.convertCase($0.0), $0.1, MenuPath(text, "Convert Case", section: 1)) }
        result += spellingItems.map { stub(ID.checkSpelling($0.0), $0.1, MenuPath(text, "Spelling", section: 3)) }
        result += [
            stub(ID.attachToPath, "Attach to Path", MenuPath(text, section: 2)),
            stub(ID.detachFromPath, "Detach from Path", MenuPath(text, section: 2)),
            stub(ID.flowInsidePath, "Flow Inside Path", MenuPath(text, section: 2)),
            stub(ID.runAround, "Run Around Selection…", MenuPath(text, section: 2)),
            stub(ID.convertToPaths, "Convert to Paths", MenuPath(text, section: 2)),
            stub(ID.spelling, "Spelling…", MenuPath(text, section: 3)),

            stub(ID.trace, "Trace…", MenuPath(object, "Image", section: 0)),
            stub(ID.imageCrop, "Crop", MenuPath(object, "Image", section: 0)),
            stub(ID.convertToEditable, "Convert to Editable", MenuPath(object, section: 0)),
            stub(ID.chartEditData, "Edit Data…", MenuPath(object, "Chart", section: 0)),
            stub(ID.chartType, "Chart Type…", MenuPath(object, "Chart", section: 0)),
            stub(ID.addToLibrary, "Add to Library…", MenuPath(object, section: 1)),
            stub(ID.name, "Name…", MenuPath(object, section: 1)),
            stub(ID.note, "Note…", MenuPath(object, section: 1)),
            stub(ID.link, "Link…", MenuPath(object, section: 1)),
            stub(ID.addPage, "Add Page", MenuPath(object, "Page", section: 2)),
            stub(ID.duplicatePage, "Duplicate Page", MenuPath(object, "Page", section: 2)),
            stub(ID.removePage, "Remove Page", MenuPath(object, "Page", section: 2)),
            stub(ID.goToPage, "Go to Page", MenuPath(object, "Page", section: 2)),

            stub(ID.lockGuide, "Lock Guide", MenuPath(view, StandardCommands.Menu.guides, section: StandardCommands.Section.viewRulers, subsection: 2)),
            stub(ID.releaseGuide, "Release Guide", MenuPath(view, StandardCommands.Menu.guides, section: StandardCommands.Section.viewRulers, subsection: 2)),
            stub(ID.deleteGuide, "Delete Guide", MenuPath(view, StandardCommands.Menu.guides, section: StandardCommands.Section.viewRulers, subsection: 2)),
            stub(ID.follow, "Follow <name>", MenuPath(view, "Collaborators", section: StandardCommands.Section.viewVisibility)),
            stub(ID.goToCollaboratorPage, "Go to <name>'s Page", MenuPath(view, "Collaborators", section: StandardCommands.Section.viewVisibility)),
            stub(ID.hideCursor, "Hide <name>'s Cursor", MenuPath(view, "Collaborators", section: StandardCommands.Section.viewVisibility)),

            stub(ID.renameDocument, "Rename Document…", MenuPath(StandardCommands.Menu.file, section: 1)),
            stub(ID.share, "Share…", MenuPath(StandardCommands.Menu.file, section: 1)),
            stub(ID.showDocumentInLibrary, "Show in Library", MenuPath(StandardCommands.Menu.file, section: 1)),
        ]
        result += contextMagnifications.filter { level in !StandardCommands.magnificationLevels.contains { $0.percent == level } }.map { level in
            Command.placeholder(id: ID.contextMagnification(level), title: "\(level)%", keywords: ["zoom", "magnification"])
        }
        return result
    }

    @MainActor
    static func register(into registry: CommandRegistry) {
        for command in placeholders() { registry.registerIfAbsent(command) }
    }

    // MARK: Layouts

    private static func commands(_ ids: CommandID...) -> [ContextMenuEntry] { ids.map { .command($0) } }

    /// The first items of a single object's menu (the page's table).
    static func kindEntries(_ kind: ContextObjectKind) -> [ContextMenuEntry] {
        switch kind {
        case .path:
            return [.submenu("Path", [.command(ID.closePath, title: "Close / Open")] + commands(ID.reverseDirection, ID.join, ID.split))]
                + commands(ID.removeOverlap, ID.simplify, ID.expandStroke, ID.insetPath, ID.attachToPath)
        case .text:
            return [.command(ID.textEditor), fontSubmenu, sizeSubmenu, styleSubmenu, .submenu("Align", alignEntries)]
                + commands(ID.attachToPath, ID.detachFromPath, ID.flowInsidePath, ID.convertToPaths, ID.spelling)
        case .bitmap:
            return [.command(ID.editWith, title: "Edit in External Editor")] + commands(ID.trace, ID.imageCrop, ID.links)
        case .importedGraphic:
            return commands(ID.links, ID.convertToEditable)
        case .group:
            return commands(ID.ungroup, ID.groupTransformsAsUnit, ID.enterGroup)
        case .blend:
            return commands(ID.blendSteps, ID.attachToPath, ID.blendRelease)
        case .clip:
            return commands(ID.releaseContents, ID.editContents)
        case .connector:
            return commands(ID.reroute, ID.detachEnds)
        case .symbolInstance:
            return commands(ID.releaseInstance, ID.editSymbol, ID.showInLibrary)
        case .chart:
            return commands(ID.chartEditData, ID.chartType)
        case .envelope:
            return commands(ID.envelopeShowMap, ID.envelopeCopyAsPath, ID.envelopeRelease, ID.envelopeRemove)
        }
    }

    static let fontSubmenu = ContextMenuEntry.submenu("Font", commands(ID.fontOther))
    static let sizeSubmenu = ContextMenuEntry.submenu("Size", textSizes.map { .command(ID.size($0)) })
    static let styleSubmenu = ContextMenuEntry.submenu("Style", textStyles.map { .command(ID.style($0.0)) })
    static let alignEntries: [ContextMenuEntry] = textAlignments.map { .command(ID.align($0.0)) }
    static let arrangeSubmenu = ContextMenuEntry.submenu("Arrange", commands(ID.bringToFront, ID.bringForward, ID.sendBackward, ID.sendToBack))
    static let alignSubmenu = ContextMenuEntry.submenu(
        "Align", commands(ID.alignLeft, ID.alignCenterHorizontal, ID.alignRight, ID.alignTop, ID.alignCenterVertical, ID.alignBottom)
    )
    static let transformSubmenu = ContextMenuEntry.submenu(
        "Transform", commands(ID.transformRotate, ID.transformScale, ID.transformSkew, ID.transformReflect, ID.transformMove)
    )
    static let combineSubmenu = ContextMenuEntry.submenu(
        "Combine", commands(ID.union, ID.divide, ID.intersect, ID.punch, ID.crop, ID.transparency, ID.combineBlend, ID.join)
    )
    static let selectSubmenu = ContextMenuEntry.submenu("Select", [
        .command(StandardCommands.ID.selectAll), .command(SelectionCommands.ID.selectNone), .command(SelectionCommands.ID.invert),
        .command(ID.superselect), .command(ID.subselect),
    ])

    /// The items on every object's menu; a multiple selection adds Combine ▸ before Align ▸.
    static func commonEntries(multiple: Bool) -> [ContextMenuEntry] {
        let ids = StandardCommands.ID.self
        return commands(ids.cut, ids.copy, ids.paste, ids.delete, ID.duplicate, ID.clone) + [.separator]
            + commands(ID.group, ID.ungroup) + [.separator]
            + commands(ID.lock, ID.unlock) + [.separator]
            + [arrangeSubmenu] + (multiple ? [combineSubmenu] : []) + [alignSubmenu, transformSubmenu] + [.separator]
            + commands(ids.hideSelection, ID.addToLibrary, ID.name, ID.note, ID.link) + [.command(ID.copyLinkToObject, title: "Copy Link"), .separator]
            + [selectSubmenu, .command(PanelCommands.ID.show("object"), title: "Object Panel")]
    }

    /// The pasteboard (and page) menu.
    static func pasteboardEntries(overPage: Bool) -> [ContextMenuEntry] {
        let ids = StandardCommands.ID.self
        let levels: [ContextMenuEntry] = contextMagnifications.map { .command(ID.contextMagnification($0)) }
        let view = ContextMenuEntry.submenu("View", levels + [.separator] + commands(ids.fitPage, ids.fitAll))
        let pages: [ContextMenuEntry] = [.command(ID.addPage)] + (overPage ? commands(ID.duplicatePage, ID.removePage, ids.pageSetup) : [])
        return [view, .separator] + commands(ids.paste, ID.pasteBehind, ids.selectAll, ids.showAllObjects) + [.separator]
            + [.submenu("Page", pages), .separator]
            + [.command(ids.pageRulers, title: "Rulers"), .command(ids.showGrid, title: "Grid"), .command(ids.showGuides, title: "Guides")]
            + [.separator, .command(PanelCommands.ID.show("document"), title: "Document Panel")]
    }

    static func guideEntries(locked: Bool) -> [ContextMenuEntry] {
        [.command(ID.lockGuide, title: locked ? "Unlock Guide" : "Lock Guide")]
            + commands(ID.releaseGuide) + [.command(StandardCommands.ID.editGuides, title: "Edit Guides…")] + commands(ID.deleteGuide)
    }

    static let presenceEntries = commands(ID.follow, ID.goToCollaboratorPage, ID.hideCursor)

    static let tabEntries = commands(
        ID.closeTab, ID.closeOtherTabs, WindowTabCommands.ID.moveTabToNewWindow, ID.renameDocument, ID.share, ID.showDocumentInLibrary
    )

    /// The text menu (context-menus.adoc, "Text context menu").
    static let textEditingEntries: [ContextMenuEntry] = {
        let ids = StandardCommands.ID.self
        return commands(ids.cut, ids.copy, ids.paste) + [.separator, fontSubmenu, sizeSubmenu, styleSubmenu]
            + [
                .submenu("Leading", leadings.map { .command(ID.leading($0.0)) }),
                .submenu("Alignment", alignEntries),
                .submenu("Special Characters", specialCharacters.map { .command(ID.specialCharacter($0.0)) }),
                .submenu("Spelling", spellingItems.map { .command(ID.checkSpelling($0.0)) }),
                .separator, .command(ID.textEditor),
                .submenu("Convert Case", cases.map { .command(ID.convertCase($0.0)) }),
            ]
            + commands(ID.attachToPath, ID.runAround, ID.convertToPaths)
    }()

    /// The layout for `target`.  Panel menus have no layout of their own: they are the owning
    /// panel's commands for the context, in registration order (`ContextMenuBuilder`).
    static func entries(for target: ContextMenuTarget) -> [ContextMenuEntry] {
        switch target {
        case let .objects(kinds):
            let distinct = Set(kinds)
            let specific = distinct.count == 1 ? kindEntries(kinds[0]) : []
            return specific + (specific.isEmpty ? [] : [.separator]) + commonEntries(multiple: kinds.count > 1)
        case let .pasteboard(overPage): return pasteboardEntries(overPage: overPage)
        case let .guide(locked): return guideEntries(locked: locked)
        case .presence: return presenceEntries
        case .panel: return []
        case .tab: return tabEntries
        case .textEditing: return textEditingEntries
        }
    }

    /// The panel menus' documented items (context-menus.adoc, "Panel menus"), in order, which
    /// the owning panels register as commands with the context.
    static let documentedPanelItems: [(context: MenuContext, titles: [String])] = [
        (.pageThumbnail, ["Add Page", "Duplicate Page", "Remove Page", "Page Setup…", "Go to Page"]),
        (.swatch, ["Edit…", "Duplicate", "Delete", "Rename", "Make Spot", "Export…", "Apply to Stroke", "Apply to Fill", "Select Objects Using This Color"]),
        (.swatchesArea, ["New Swatch…", "Import…", "Sort by Name", "Hide Names"]),
        (.colorBox, ["Add to Swatches"]),
        (.tint, ["Add to Swatches", "Apply to Stroke", "Apply to Fill"]),
        (.layer, [
            "New Layer", "Duplicate Layer", "Remove Layer", "Rename", "Move Selection to This Layer", "Lock", "Hide", "Non-printing",
            "All Layers Visible", "Merge Selected Layers",
        ]),
        (.style, ["Edit…", "Duplicate", "Remove", "Redefine", "Apply", "Select Objects Using Style", "Style Behavior…"]),
        (.symbol, ["Edit Symbol", "Duplicate", "Delete", "Rename", "Export…", "Select Instances"]),
    ]
}
