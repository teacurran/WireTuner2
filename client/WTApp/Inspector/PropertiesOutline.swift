import AppKit
import SwiftUI
import WTCRDT
import WTModel

/// A row of the properties list: the selection's root, one stack element, or a group's *Contents*.
enum PropertiesKey: Hashable {
    case root
    case row(AppearanceRow)
    case contents
}

/// What the properties list shows (object-panel.adoc, "Layout"; attribute-stack.adoc, "The
/// Attributes list"): the root row naming the selection, the stack rows top first, and for one
/// group a *Contents* row whose double-click subselects every member.  A value built from the
/// Attributes list model and the document on every render, so it never caches document state.
struct PropertiesTree: Equatable {
    struct Row: Equatable {
        let key: PropertiesKey
        let title: String
        let icon: String
        /// The stack row, for stack rows.
        let item: AttributeRowItem?
    }

    let root: Row
    let children: [Row]
    /// The group's members *Contents* subselects (empty: no *Contents* row).
    let members: [OpID]

    @MainActor
    init(list: AttributesListModel, members: [OpID] = []) {
        root = Row(key: .root, title: list.rootTitle, icon: "cube", item: nil)
        let effects = list.targets.first.map { EffectReading.entries($0, in: list.document.state) } ?? []
        var children = list.displayRows.map { Row(key: .row($0.id), title: Self.title($0, effects: effects), icon: $0.icon, item: $0) }
        if !members.isEmpty { children.append(Row(key: .contents, title: "Contents", icon: "folder", item: nil)) }
        self.children = children
        self.members = members
    }

    /// A row's title: its description; an effect is named by its kind ("Unsupported effect
    /// (update WireTuner)" for one this build does not know) and indented under the fill or stroke
    /// it is attached to (live-effects.adoc, "Effects in the Object panel").
    static func title(_ item: AttributeRowItem, effects: [EffectEntry]) -> String {
        guard item.list == .effects, let entry = effects.first(where: { $0.row == item.id }) else { return item.summary }
        return entry.attachment == .object ? entry.title : "↳ \(entry.title)"
    }

    /// The stack rows (display order), without *Contents*.
    var rowCount: Int { children.count { $0.item != nil } }

    /// The kinds whose members *Contents* lists: groups, and the key objects of a blend or the
    /// shape inside an extrusion.
    static let containers: Set<NodeKind> = [.group, .blend, .extrude]

    /// The members *Contents* subselects: the children of the one selected group that are objects.
    @MainActor
    static func members(_ list: AttributesListModel) -> [OpID] {
        guard list.targets.count == 1, let target = list.targets.first,
              let kind = list.document.object(for: SelectionID(target))?.kind, containers.contains(kind) else { return [] }
        return list.document.state.store.children(target).filter { list.document.object(for: SelectionID($0)) != nil }
    }
}

/// An outline item: stable per key, so the outline keeps its selection across reloads.
final class PropertiesItem: NSObject {
    let key: PropertiesKey

    init(_ key: PropertiesKey) {
        self.key = key
    }
}

/// The properties list's outline view (attribute-stack.adoc, "Object panel": an `NSOutlineView`
/// subclass): kbd:[Delete] removes the selected row; everything else is the outline's own keyboard
/// navigation.
class PropertiesOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    /// Backspace and forward delete.
    static let deleteKeys: Set<UInt16> = [51, 117]

    override func keyDown(with event: NSEvent) {
        if Self.deleteKeys.contains(event.keyCode) {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The properties list's data source and delegate: rows from a `PropertiesTree`, the visibility
/// checkboxes, drag reordering (a copy with kbd:[Option]), colour drops on fill and stroke rows,
/// and the double-click on *Contents*.  Every action goes out through `Actions`, so the controller
/// holds no document state and the tests drive it directly.
@MainActor
final class PropertiesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    struct Actions {
        var select: @MainActor (AttributesListView.ListSelection) -> Void = { _ in }
        var setVisible: @MainActor (AttributeRowItem, Bool) -> Void = { _, _ in }
        /// A row dragged from display position `from` to the insertion point `to`; `duplicate`
        /// with kbd:[Option].
        var move: @MainActor (_ from: Int, _ to: Int, _ duplicate: Bool) -> Void = { _, _, _ in }
        var dropColor: @MainActor (NSPasteboard, AttributeRowItem) -> Bool = { _, _ in false }
        /// An effect row (display position) dropped on a fill or stroke row, or on the root row
        /// (nil): the effect is attached there.
        var attach: @MainActor (_ from: Int, _ onto: AttributeRowItem?) -> Void = { _, _ in }
        var remove: @MainActor () -> Void = {}
        var openContents: @MainActor () -> Void = {}
    }

    /// A stack row being dragged: its display position.
    static let rowType = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.attribute-row")
    static let colorTypes = ColorDrag.dropTypes.map { NSPasteboard.PasteboardType($0.identifier) }

    private(set) var tree: PropertiesTree?
    var actions = Actions()
    /// Whether kbd:[Option] is down (a drag duplicates).
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }
    private var items: [PropertiesKey: PropertiesItem] = [:]
    /// Set while the controller changes the outline, so its selection callback is not an edit.
    private var applying = false

    func item(_ key: PropertiesKey) -> PropertiesItem {
        if let item = items[key] { return item }
        let item = PropertiesItem(key)
        items[key] = item
        return item
    }

    func row(_ key: PropertiesKey) -> PropertiesTree.Row? {
        guard let tree else { return nil }
        return key == .root ? tree.root : tree.children.first { $0.key == key }
    }

    /// Shows `tree` with `selected` selected; reloads only when the rows changed.
    func update(_ tree: PropertiesTree, selected: PropertiesKey, in outline: NSOutlineView) {
        applying = true
        defer { applying = false }
        if tree != self.tree {
            self.tree = tree
            let live = Set([PropertiesKey.root] + tree.children.map(\.key))
            items = items.filter { live.contains($0.key) }
            outline.reloadData()
            outline.expandItem(item(.root))
        }
        let index = outline.row(forItem: item(selected))
        if index >= 0, outline.selectedRow != index {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree else { return 0 }
        guard let item = item as? PropertiesItem else { return 1 }
        return item.key == .root ? tree.children.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard item != nil, let tree else { return self.item(.root) }
        return self.item(tree.children[index].key)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PropertiesItem)?.key == .root && !(tree?.children.isEmpty ?? true)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let key = (item as? PropertiesItem)?.key, let row = row(key) else { return nil }
        let cell = outlineView.makeView(withIdentifier: PropertiesRowCell.identifier, owner: self) as? PropertiesRowCell ?? PropertiesRowCell()
        cell.configure(row, target: self, action: #selector(toggleVisibility(_:)))
        return cell
    }

    /// *Contents* is not a row to edit; double-click it instead.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? PropertiesItem)?.key != .contents
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying, let outline = notification.object as? NSOutlineView else { return }
        switch (outline.item(atRow: outline.selectedRow) as? PropertiesItem)?.key {
        case .row(let row)?: actions.select(.row(row))
        default: actions.select(.root)
        }
    }

    /// The double-click: *Contents* subselects the group's members.
    @objc func doubleClicked(_ sender: NSOutlineView) {
        guard (sender.item(atRow: sender.clickedRow) as? PropertiesItem)?.key == .contents else { return }
        actions.openContents()
    }

    /// A row's visibility checkbox: checked is visible (a mixed box turns on).
    @objc func toggleVisibility(_ sender: NSButton) {
        guard let item = (sender as? PropertiesVisibilityButton)?.item else { return }
        actions.setVisible(item, sender.state != .off)
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let key = (item as? PropertiesItem)?.key, let index = tree?.children.firstIndex(where: { $0.key == key }),
              tree?.children[index].item != nil else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(String(index), forType: Self.rowType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let tree else { return [] }
        let key = (item as? PropertiesItem)?.key
        if let from = info.draggingPasteboard.string(forType: Self.rowType).flatMap(Int.init) {
            if index == NSOutlineViewDropOnItemIndex, let key, attachTarget(from: from, onto: key) { return .move }
            guard key == .root, index >= 0 else { return [] }
            if index > tree.rowCount { outlineView.setDropItem(self.item(.root), dropChildIndex: tree.rowCount) }
            return optionHeld() ? .copy : .move
        }
        guard let key, index == NSOutlineViewDropOnItemIndex, colorTarget(key) != nil,
              info.draggingPasteboard.availableType(from: Self.colorTypes) != nil else { return [] }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let key = (item as? PropertiesItem)?.key
        if let from = info.draggingPasteboard.string(forType: Self.rowType).flatMap(Int.init) {
            if index == NSOutlineViewDropOnItemIndex, let key, attachTarget(from: from, onto: key) {
                actions.attach(from, key == .root ? nil : row(key)?.item)
                return true
            }
            guard key == .root, let tree else { return false }
            actions.move(from, min(max(index, 0), tree.rowCount), optionHeld())
            return true
        }
        guard let key, let target = colorTarget(key) else { return false }
        return actions.dropColor(info.draggingPasteboard, target)
    }

    /// Whether the row at display position `from` is an effect that a drop on `key` attaches:
    /// onto a fill or stroke row, or back to the object's own row.
    func attachTarget(from: Int, onto key: PropertiesKey) -> Bool {
        guard let tree, tree.children.indices.contains(from), tree.children[from].item?.list == .effects else { return false }
        return key == .root || colorTarget(key) != nil
    }

    /// The stack row a colour dropped on `key` colours: fills and strokes, not effects.
    func colorTarget(_ key: PropertiesKey) -> AttributeRowItem? {
        guard let item = row(key)?.item, item.list != .effects else { return nil }
        return item
    }

    /// Builds the outline in its scroll view, wired to this controller.
    func makeOutline() -> (scroll: NSScrollView, outline: PropertiesOutlineView) {
        let outline = PropertiesOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("property"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.style = .plain
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([Self.rowType] + Self.colorTypes)
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setAccessibilityIdentifier("attributes.list")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return (scroll, outline)
    }
}

/// A row's visibility checkbox, carrying its row.
final class PropertiesVisibilityButton: NSButton {
    var item: AttributeRowItem?
}

/// One row: kind icon, description and, on stack rows, the visibility checkbox; hidden rows are
/// dimmed.
final class PropertiesRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PropertiesRowCell")
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let visible = PropertiesVisibilityButton(checkboxWithTitle: "", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title
        visible.allowsMixedState = true
        title.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, title, NSView(), visible])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ row: PropertiesTree.Row, target: AnyObject?, action: Selector) {
        icon.image = NSImage(systemSymbolName: row.icon, accessibilityDescription: nil)
        title.stringValue = row.title
        title.font = row.key == .root ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        visible.item = row.item
        visible.isHidden = row.item == nil
        visible.target = target
        visible.action = action
        alphaValue = row.item?.hidden == .on ? 0.5 : 1
        switch row.item?.hidden {
        case .on?: visible.state = .off
        case .mixed?: visible.state = .mixed
        default: visible.state = .on
        }
        if let item = row.item {
            setAccessibilityIdentifier("attributes.row.\(item.index)")
            visible.setAccessibilityIdentifier("attributes.visible.\(item.index)")
        } else {
            setAccessibilityIdentifier(row.key == .root ? "attributes.root" : "attributes.contents")
        }
        visible.setAccessibilityLabel("Visible")
    }
}

/// The properties list in SwiftUI: the outline, fed a new tree and selection on every render.
struct PropertiesOutline: NSViewRepresentable {
    let tree: PropertiesTree
    let selected: PropertiesKey
    let actions: PropertiesOutlineController.Actions
    var optionHeld: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.option) }

    func makeCoordinator() -> PropertiesOutlineController {
        PropertiesOutlineController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.make(context.coordinator)
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        update(view, controller: context.coordinator)
    }

    static func make(_ controller: PropertiesOutlineController) -> NSScrollView {
        controller.makeOutline().scroll
    }

    /// Hands the controller the current actions and shows the tree.
    func update(_ view: NSScrollView, controller: PropertiesOutlineController) {
        controller.actions = actions
        controller.optionHeld = optionHeld
        guard let outline = view.documentView as? PropertiesOutlineView else { return }
        outline.onDelete = actions.remove
        controller.update(tree, selected: selected, in: outline)
    }
}
