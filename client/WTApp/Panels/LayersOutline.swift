import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// The Layers panel's list (layers.adoc, "The Layers panel" and "Objects in the Layers panel";
/// D-092): an `NSOutlineView` with a row per layer -- the separator between the printing and the
/// background layers -- and, under each layer's disclosure triangle, its objects frontmost first,
/// nested as they are grouped.  The outline asks for rows as they scroll into view and a
/// container's members only when it is opened, so a document of many thousands of objects costs
/// what the open rows show; model changes update only the containers and rows they touched.
struct LayersOutline: NSViewRepresentable {
    let model: LayersPanelModel
    /// The search field's text.
    let filter: String
    /// The frame-number marks of each layer (WEB-017), read here so playback updates the rows.
    let marks: [OpID: LayerFrameMarks]

    func makeCoordinator() -> LayersOutlineController { LayersOutlineController() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(model, filter: filter, marks: marks)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: LayersOutlineController) {
        coordinator.detach()
    }
}

/// What a layer row shows of the Animation panel (`LayerFrames.marks`).
struct LayerFrameMarks: Equatable {
    var number: Int?
    var playing: Bool
}

/// One row of the outline.  NSOutlineView tells rows apart by object identity, so each layer and
/// object has one item for as long as the controller lives.
@MainActor
final class LayersTreeItem: NSObject {
    enum Kind: Hashable {
        case layer(OpID)
        case separator
        case object(OpID)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    var node: OpID? {
        switch kind {
        case .layer(let id), .object(let id): id
        case .separator: nil
        }
    }

    var key: String {
        switch kind {
        case .layer(let id): "layer:\(id)"
        case .separator: LayersPanelModel.Row.separatorID
        case .object(let id): "object:\(id)"
        }
    }
}

/// The outline view: its drag image stays the system's; it adds the context menu per clicked row
/// and hands keys to the controller first (LIB-031): what the controller does not take --
/// kbd:[Up], kbd:[Down] and typing a name -- the outline does, and a selection the keys changed
/// is reported so the canvas selection follows.
final class LayersOutlineView: NSOutlineView {
    var contextMenu: ((Int) -> NSMenu?)?
    /// A key, before the outline's own handling; true when it was taken.
    var keyHandler: ((NSEvent) -> Bool)?
    /// The rows' selection changed by a key.
    var selectedByKeys: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? contextMenu?(row) : super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let before = selectedRowIndexes
        if keyHandler?(event) != true { super.keyDown(with: event) }
        if selectedRowIndexes != before { selectedByKeys?() }
    }
}

/// Draws the playing frame's tint behind a layer row (WEB-017).
final class LayersRowView: NSTableRowView {
    var playing = false {
        didSet { if playing != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard playing else { return }
        NSColor.systemOrange.withAlphaComponent(0.3).setFill()
        bounds.fill()
    }
}

/// The outline's data source and delegate.
@MainActor
final class LayersOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    static let rowType = NSPasteboard.PasteboardType("com.villagecompute.wiretuner.layers-row")
    static let layerCell = NSUserInterfaceItemIdentifier("layers.layerCell")
    static let objectCell = NSUserInterfaceItemIdentifier("layers.objectCell")
    static let separatorCell = NSUserInterfaceItemIdentifier("layers.separatorCell")

    let outline = LayersOutlineView()
    let scrollView = NSScrollView()
    private(set) var model: LayersPanelModel?
    private(set) var filter = ""
    private var marks: [OpID: LayerFrameMarks] = [:]

    private weak var document: DocumentHandle?
    private weak var selection: SelectionModel?
    private var documentToken: DocumentHandle.ObservationToken?
    private var selectionToken: SelectionModel.ObservationToken?

    private var items: [OpID: LayersTreeItem] = [:]
    private let separator = LayersTreeItem(.separator)
    private var root: [LayersTreeItem] = []
    /// The children the outline was given, per container it asked about.
    private var loaded: [OpID: [OpID]] = [:]
    /// The rows a search shows; nil without a search.
    private(set) var shown: Set<OpID>?
    private var cachedTree: ObjectTree?
    /// Each container's rows as last listed from `cachedTree` (dropped with it): the outline asks
    /// whether a layer expands once per row it lays out, and listing a layer reads all its objects.
    private var childCache: [OpID: [OpID]] = [:]
    /// The rows being dragged.
    private var dragged: [LayersTreeItem] = []
    /// Set while the outline's selection is being made to match the model's.
    private var syncing = false
    /// Set while the keys' row selection is being written to the canvas.
    private var driving = false
    /// The rows the keys selected and the canvas selection that made: kept selected -- an object
    /// the canvas cannot select among them -- for as long as the canvas selection is that one.
    private var keyed: (rows: [OpID], canvas: [OpID])?
    /// The object rows' pictures (LIB-031).
    let thumbnails = LayersThumbnails()
    /// The modifier keys held while a colour is dragged over the rows.
    var dropModifiers: () -> KeyModifiers = { KeyEquivalentResolver.modifiers(NSEvent.modifierFlags) }

    /// How many times rows were reloaded or containers re-listed after a model change (tests:
    /// an edit touches only what it changed).
    private(set) var rowReloads = 0
    private(set) var containerUpdates = 0
    private(set) var fullReloads = 0

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layers.column"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = LayersPanelBody.rowHeight
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([Self.rowType, ColorDrag.type, .color])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.contextMenu = { [weak self] row in self?.menu(forRow: row) }
        outline.keyHandler = { [weak self] event in self?.key(event) ?? false }
        outline.selectedByKeys = { [weak self] in self?.selectFromRows() }
        thumbnails.source = { [weak self] node in
            guard let object = self?.model?.document.object(for: SelectionID(node)), let bounds = object.bounds else { return nil }
            return (object.item, bounds)
        }
        thumbnails.ready = { [weak self] node in self?.refreshThumbnail(node) }
        outline.setAccessibilityIdentifier("layers.list")
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    // MARK: Binding

    /// The panel's model for the front window: a different document reloads everything; the same
    /// one refreshes the layer rows (the pen icon, the panel's layer selection, frame marks) and
    /// applies a new search.
    func update(_ model: LayersPanelModel, filter: String, marks: [OpID: LayerFrameMarks]) {
        self.model = model
        let marksChanged = marks != self.marks
        self.marks = marks
        defer { answerLocate(model.state) }
        if document !== model.document || selection !== model.editing.selection.model {
            attach(model)
            return
        }
        if filter != self.filter {
            self.filter = filter
            applyFilter()
            return
        }
        refreshLayerRows(marksChanged: marksChanged)
    }

    private func attach(_ model: LayersPanelModel) {
        detach()
        document = model.document
        selection = model.editing.selection.model
        documentToken = model.document.observe { [weak self] change in self?.documentDidChange(change) }
        selectionToken = model.editing.selection.model.observe { [weak self] _ in self?.selectionDidChange() }
        items = [:]
        keyed = nil
        thumbnails.reset()
        filter = model.state.filter
        reloadAll()
    }

    /// Stops observing (the panel went away).
    func detach() {
        if let documentToken { document?.stopObserving(documentToken) }
        if let selectionToken { selection?.stopObserving(selectionToken) }
        documentToken = nil
        selectionToken = nil
    }

    var tree: ObjectTree {
        if let cachedTree { return cachedTree }
        childCache = [:]
        let tree = ObjectTree(model?.document.state ?? EngineState())
        cachedTree = tree
        return tree
    }

    func item(_ kind: LayersTreeItem.Kind) -> LayersTreeItem {
        guard let node = LayersTreeItem(kind).node else { return separator }
        if let existing = items[node], existing.kind == kind { return existing }
        let item = LayersTreeItem(kind)
        items[node] = item
        return item
    }

    /// The item standing for `node` in the outline, when it has one.
    func existingItem(_ node: OpID) -> LayersTreeItem? { items[node] }

    // MARK: Reading

    /// The root rows: the layers frontmost first, the separator between the printing and the
    /// background ones.
    private func rootItems() -> [LayersTreeItem] {
        guard let model else { return [] }
        return model.rows.map { row in
            if let layer = row.layer { return item(.layer(layer.id)) }
            return separator
        }
    }

    /// The rows under `node` as shown: every one, or a search's matches and the rows above them.
    func childIDs(of node: OpID) -> [OpID] {
        let tree = tree
        let children: [OpID]
        if let cached = childCache[node] {
            children = cached
        } else {
            children = tree.children(of: node)
            childCache[node] = children
        }
        guard let shown else { return children }
        return children.filter(shown.contains)
    }

    private func objectItem(_ node: OpID) -> LayersTreeItem {
        tree.order.layer(node) != nil ? item(.layer(node)) : item(.object(node))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? LayersTreeItem else { return root.count }
        guard let node = item.node else { return 0 }
        let children = childIDs(of: node)
        loaded[node] = children
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? LayersTreeItem, let node = item.node else { return root[index] }
        let children = loaded[node] ?? childIDs(of: node)
        return objectItem(children[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? LayersTreeItem, let node = item.node else { return false }
        if shown != nil || tree.order.layer(node) != nil { return !childIDs(of: node).isEmpty }
        return tree.hasChildren(node)
    }

    // MARK: Updating

    private func reloadAll() {
        cachedTree = nil
        loaded = [:]
        shown = filter.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tree.matching(filter)
        root = rootItems()
        fullReloads += 1
        outline.reloadData()
        if shown != nil { outline.expandItem(nil, expandChildren: true) }
        syncSelection(reveal: true)
    }

    /// The containers that were open when the search began, restored when it is cleared.
    private var expandedBeforeSearch: Set<OpID>?

    private func applyFilter() {
        if shown == nil { expandedBeforeSearch = expandedNodes() }
        reloadAll()
        if shown == nil, let expanded = expandedBeforeSearch {
            // The outline keeps the search's open rows across a reload (the items are the same
            // objects): close them, then reopen what was open before.
            expandedBeforeSearch = nil
            outline.collapseItem(nil, collapseChildren: true)
            restore(expanded)
            syncSelection(reveal: true)
        }
    }

    /// The containers open now.
    private func expandedNodes() -> Set<OpID> {
        Set((0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? LayersTreeItem).flatMap { outline.isItemExpanded($0) ? $0.node : nil }
        })
    }

    private func restore(_ expanded: Set<OpID>) {
        var row = 0
        while row < outline.numberOfRows {
            if let item = outline.item(atRow: row) as? LayersTreeItem, let node = item.node, expanded.contains(node) {
                outline.expandItem(item)
            }
            row += 1
        }
    }

    /// The nodes a change wrote -- what the change summary lists and what its ops name (a name or
    /// a lock changes nothing drawn, so the ops are read too) -- and of those, the ones it
    /// created, moved or deleted, whose containers' rows change.
    static func touched(_ change: ContentChange) -> (all: Set<OpID>, placed: Set<OpID>) {
        var nodes = Set(change.summary.touchedNodes.map(OpID.init))
        var placed: Set<OpID> = []
        guard let ops = change.change else { return (nodes, placed) }
        for (op, id) in zip(ops.ops, ops.opIDs) {
            switch op.op {
            case .create?: placed.insert(id)
            case .set(let set)?: nodes.insert(OpID(set.node))
            case .move(let move)?: placed.insert(OpID(move.node))
            case .setDeleted(let deleted)?: placed.insert(OpID(deleted.node))
            case .textInsert(let insert)?: nodes.insert(OpID(insert.node))
            case .textDelete(let delete)?: nodes.insert(OpID(delete.node))
            default: break
            }
        }
        return (nodes.union(placed), placed)
    }

    /// More nodes than this in a change that is not one of the document's (a reload of the whole
    /// state) reload the whole outline.
    static let reloadThreshold = 500

    /// A model change: the containers whose members changed are re-listed (rows inserted and
    /// removed, never the whole outline), and the rows whose objects changed redraw.  A reload of
    /// the whole state reloads everything.
    func documentDidChange(_ change: ContentChange) {
        guard let model else { return }
        let (nodes, placed) = Self.touched(change)
        if change.change == nil, change.summary.isStructural, nodes.isEmpty || nodes.count > Self.reloadThreshold {
            let expanded = expandedNodes()
            reloadAll()
            restore(expanded)
            return
        }
        guard !nodes.isEmpty else { return }
        let previousParents = Dictionary(placed.compactMap { node in
            items[node].map { (node, (outline.parent(forItem: $0) as? LayersTreeItem)?.node) }
        }, uniquingKeysWith: { first, _ in first })
        cachedTree = nil
        let state = model.document.state
        let layerChanged = nodes.contains { state.nodeKind($0) == .layer }
        var dirty: Set<OpID?> = []
        if layerChanged {
            // A layer added, removed, reordered or merged: the root rows, and the layers' objects
            // (a removed layer's objects show on another).
            dirty.insert(nil)
            dirty.formUnion(root.compactMap(\.node).filter { loaded[$0] != nil }.map(Optional.some))
        }
        if shown != nil {
            shown = tree.matching(filter)
            dirty.formUnion(loaded.keys.map(Optional.some))
        }
        for node in placed {
            if let parent = tree.parent(of: node) { dirty.insert(parent) }
            if let previous = previousParents[node] { dirty.insert(previous) }
        }
        outline.beginUpdates()
        // The root first, then containers top down, so a container is in the outline when its
        // members are listed.
        if dirty.contains(nil) { relist(nil) }
        for container in dirty.compactMap({ $0 }).sorted(by: { depth($0) < depth($1) }) { relist(container) }
        outline.endUpdates()
        for node in nodes {
            guard let item = items[node], outline.row(forItem: item) >= 0, model.state.renamingObject != node, model.state.renaming != node else { continue }
            rowReloads += 1
            outline.reloadItem(item, reloadChildren: false)
        }
        if layerChanged { refreshLayerRows(marksChanged: true) }
        syncSelection(reveal: false)
        refreshVisibleThumbnails()
    }

    // MARK: Thumbnails

    /// The object rows laid out now.
    var visibleObjectRows: [(row: Int, node: OpID)] {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<range.location + range.length).compactMap { row in
            guard let item = outline.item(atRow: row) as? LayersTreeItem, case .object(let node) = item.kind else { return nil }
            return (row, node)
        }
    }

    /// After a change, each row on screen checks its picture against its object's drawing: only
    /// the rows whose objects now draw differently -- a group whose member changed included --
    /// are drawn again.
    func refreshVisibleThumbnails() {
        for (row, node) in visibleObjectRows {
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ObjectRowCell)?.showThumbnail(thumbnails.image(for: node))
        }
    }

    /// A picture arrived for `node`: its row shows it, if the row is on screen.
    func refreshThumbnail(_ node: OpID) {
        guard let item = items[node], case .object = item.kind else { return }
        let row = outline.row(forItem: item)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ObjectRowCell, cell.node == node else { return }
        cell.showThumbnail(thumbnails.image(for: node))
    }

    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {
        // A row scrolled away before its picture's turn gives the turn up.
        if let cell = rowView.view(atColumn: 0) as? ObjectRowCell, let node = cell.node { thumbnails.forget(node) }
    }

    private func depth(_ node: OpID) -> Int {
        tree.ancestors(of: node)?.count ?? 0
    }

    /// Brings one container's rows (nil: the root) up to date by inserting and removing the rows
    /// that changed.  A container not open in the outline forgets its rows and redraws its
    /// triangle.
    private func relist(_ container: OpID?) {
        let parentItem: LayersTreeItem?
        if let container {
            guard let item = items[container], outline.row(forItem: item) >= 0 else {
                loaded[container] = nil
                return
            }
            guard outline.isItemExpanded(item) else {
                loaded[container] = nil
                rowReloads += 1
                outline.reloadItem(item, reloadChildren: false)
                return
            }
            parentItem = item
        } else {
            parentItem = nil
        }
        let before: [LayersTreeItem]
        let after: [LayersTreeItem]
        if let container {
            before = (loaded[container] ?? []).map(objectItem)
            let ids = childIDs(of: container)
            loaded[container] = ids
            after = ids.map(objectItem)
        } else {
            before = root
            root = rootItems()
            after = root
        }
        guard before != after else { return }
        containerUpdates += 1
        let difference = after.difference(from: before)
        var reopen: [LayersTreeItem] = []
        let removals = difference.removals.compactMap { change -> (Int, LayersTreeItem)? in
            if case .remove(let offset, let element, _) = change { return (offset, element) }
            return nil
        }
        let insertions = difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        }
        for (offset, element) in removals.sorted(by: { $0.0 > $1.0 }) {
            if outline.isItemExpanded(element) { reopen.append(element) }
            outline.removeItems(at: IndexSet(integer: offset), inParent: parentItem, withAnimation: [])
        }
        for offset in insertions.sorted() {
            outline.insertItems(at: IndexSet(integer: offset), inParent: parentItem, withAnimation: [])
        }
        for item in reopen where outline.row(forItem: item) >= 0 { outline.expandItem(item) }
    }

    /// Redraws the layer rows (few) in place.
    private func refreshLayerRows(marksChanged: Bool) {
        for item in root where item.node != nil {
            let row = outline.row(forItem: item)
            guard row >= 0 else { continue }
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerRowCell, let model, let id = item.node,
               let layer = model.order.layer(id), model.state.renaming != id {
                cell.configure(model: model, layer: layer, index: model.layers.firstIndex { $0.id == id } ?? 0, marks: marks[id], controller: self)
            }
            if marksChanged, let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? LayersRowView {
                rowView.playing = item.node.flatMap { marks[$0]?.playing } ?? false
            }
        }
        syncSelection(reveal: false)
    }

    // MARK: Selection

    /// The canvas selection changed: its rows are revealed and selected.
    func selectionDidChange() {
        guard !driving else { return }
        syncSelection(reveal: true)
    }

    /// The most selected objects the panel opens containers to show.
    static let revealLimit = 200
    /// Above this many selected rows the selection is found by one pass over the rows.
    static let rowLookupLimit = 64

    /// Selects the rows of the selected objects and of the layers selected in the panel; with
    /// `reveal`, opens the containers above the selected objects first and scrolls to the first.
    func syncSelection(reveal: Bool) {
        guard let model else { return }
        let selected = model.editing.selectedNodes
        if reveal, selected.count <= Self.revealLimit {
            for node in selected { self.reveal(node) }
        }
        var rows = IndexSet()
        var wanted = selected + model.state.selected
        if let keyed {
            if keyed.canvas == selected { wanted = keyed.rows + model.state.selected } else { self.keyed = nil }
        }
        if wanted.count > Self.rowLookupLimit {
            // Many rows: one pass over the rows instead of a lookup per selected object.
            let set = Set(wanted)
            for row in 0..<outline.numberOfRows {
                if let node = (outline.item(atRow: row) as? LayersTreeItem)?.node, set.contains(node) { rows.insert(row) }
            }
        } else {
            for node in wanted {
                if let item = items[node] { let row = outline.row(forItem: item); if row >= 0 { rows.insert(row) } }
            }
        }
        syncing = true
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        syncing = false
        if reveal, let first = rows.first { outline.scrollRowToVisible(first) }
    }

    /// Opens every container above `node`.
    func reveal(_ node: OpID) {
        guard let ancestors = tree.ancestors(of: node) else { return }
        for ancestor in ancestors {
            if shown != nil, !(shown?.contains(ancestor) ?? false), tree.order.layer(ancestor) == nil { return }
            let item = objectItem(ancestor)
            guard outline.row(forItem: item) >= 0 else { return }
            if !outline.isItemExpanded(item) { outline.expandItem(item) }
        }
    }

    // MARK: Clicks

    var currentModifiers: () -> KeyModifiers = { KeyEquivalentResolver.modifiers(NSApp.currentEvent?.modifierFlags ?? []) }

    @objc func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown,
           outline.frameOfOutlineCell(atRow: row).contains(outline.convert(event.locationInWindow, from: nil)) {
            return
        }
        click(row: row, modifiers: currentModifiers())
    }

    /// A click on the row `row`: a layer row as the panel always did; an object row selects the
    /// object (kbd:[Cmd] adds or removes it, kbd:[Shift] adds the rows from the last one clicked).
    func click(row: Int, modifiers: KeyModifiers) {
        keyed = nil
        guard let model, let item = outline.item(atRow: row) as? LayersTreeItem else { return }
        switch item.kind {
        case .layer(let layer):
            model.click(layer, modifiers: modifiers)
            refreshLayerRows(marksChanged: false)
        case .object(let node):
            var range: [OpID] = []
            if modifiers.contains(.shift), let anchor = model.state.objectAnchor, let from = items[anchor].map(outline.row(forItem:)), from >= 0 {
                range = (min(from, row)...max(from, row)).compactMap { (outline.item(atRow: $0) as? LayersTreeItem).flatMap { item in
                    if case .object(let id) = item.kind { return id }
                    return nil
                } }
            }
            model.clickObject(node, modifiers: modifiers, range: range)
            syncSelection(reveal: false)
        case .separator:
            syncSelection(reveal: false)
        }
    }

    @objc func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        beginRename(row: row)
    }

    /// Double-click: rename the layer or object in its row.
    func beginRename(row: Int) {
        guard let model, let item = outline.item(atRow: row) as? LayersTreeItem else { return }
        switch item.kind {
        case .layer(let layer):
            model.beginRename(layer)
            guard model.state.renaming == layer, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerRowCell else { return }
            cell.beginEditing(self)
        case .object(let node):
            model.beginObjectRename(node)
            guard model.state.renamingObject == node, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ObjectRowCell else { return }
            cell.beginEditing(self)
        case .separator:
            break
        }
    }

    // MARK: Keys (LIB-031)

    enum Key {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    /// The keys the panel gives meaning to; the rest are the outline's.  kbd:[Return] (or
    /// kbd:[Enter]) renames the one selected row; kbd:[Right] opens the selected containers --
    /// an open one moves to its first row -- and kbd:[Left] closes them -- a closed row or a
    /// leaf moves to the row above it in the tree; with kbd:[Option] they open or close
    /// everything under the rows.  kbd:[Up] and kbd:[Down] (with kbd:[Shift] to extend) and
    /// typing the start of a name are the outline's own.
    func key(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
        switch event.keyCode {
        case Key.returnKey, Key.enter:
            guard modifiers.isEmpty, outline.selectedRowIndexes.count == 1, let row = outline.selectedRowIndexes.first else { return false }
            beginRename(row: row)
            return true
        case Key.right:
            guard modifiers.subtracting(.option).isEmpty else { return false }
            openSelected(all: modifiers.contains(.option))
            return true
        case Key.left:
            guard modifiers.subtracting(.option).isEmpty else { return false }
            closeSelected(all: modifiers.contains(.option))
            return true
        default:
            return false
        }
    }

    private var selectedItems: [LayersTreeItem] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? LayersTreeItem }
    }

    /// kbd:[Right].
    private func openSelected(all: Bool) {
        let selected = selectedItems
        let closed = selected.filter { outline.isExpandable($0) && (!outline.isItemExpanded($0) || all) }
        if !closed.isEmpty {
            for item in closed { outline.expandItem(item, expandChildren: all) }
            return
        }
        guard selected.count == 1, let item = selected.first, outline.isItemExpanded(item) else { return }
        let row = outline.row(forItem: item) + 1
        guard row < outline.numberOfRows, outline.parent(forItem: outline.item(atRow: row)) as? LayersTreeItem === item else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// kbd:[Left].
    private func closeSelected(all: Bool) {
        let selected = selectedItems
        let open = selected.filter { outline.isItemExpanded($0) }
        if !open.isEmpty {
            for item in open { outline.collapseItem(item, collapseChildren: all) }
            return
        }
        guard selected.count == 1, let item = selected.first, let parent = outline.parent(forItem: item) else { return }
        let row = outline.row(forItem: parent)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// The keys moved the row selection: the selected object rows become the canvas selection
    /// (those the panel may select, `canSelect`), the selected layer rows the panel's layer
    /// selection.  Nothing moves and no layer becomes active, as a click would do.
    func selectFromRows() {
        guard let model, !syncing else { return }
        var objects: [OpID] = []
        var layers: [OpID] = []
        for item in selectedItems {
            switch item.kind {
            case .object(let node): objects.append(node)
            case .layer(let layer): layers.append(layer)
            case .separator: break
            }
        }
        if model.state.selected != layers { model.state.selected = layers }
        if let layer = layers.last { model.state.anchor = layer }
        if let node = objects.last { model.state.objectAnchor = node }
        let canvas = objects.filter(model.canSelect)
        keyed = (objects, canvas)
        driving = true
        model.editing.selection.model.set(Selection(canvas.map(SelectionID.init)))
        driving = false
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let item = item as? LayersTreeItem, let model else { return nil }
        switch item.kind {
        case .layer(let id): return model.order.layer(id).map { $0.name.isEmpty ? "Layer" : $0.name }
        case .object(let node): return tree.label(of: node)
        case .separator: return nil
        }
    }

    // MARK: Locate Object (LIB-031)

    /// Answers a *Locate Object* request once.
    private func answerLocate(_ state: LayersPanelState) {
        guard state.locateRequest != state.locateAnswered else { return }
        state.locateAnswered = state.locateRequest
        locate()
    }

    /// Shows the first selected object's row: the search is cleared when it hides the row, the
    /// layer and groups above it are opened, and the row is selected and scrolled to the middle.
    /// Whether a row was found.
    @discardableResult
    func locate() -> Bool {
        guard let model, let node = model.editing.selectedNodes.first, tree.ancestors(of: node) != nil else { return false }
        if let shown, !shown.contains(node) {
            model.state.filter = ""
            filter = ""
            applyFilter()
        }
        reveal(node)
        guard let item = items[node] else { return false }
        let row = outline.row(forItem: item)
        guard row >= 0 else { return false }
        syncSelection(reveal: false)
        let rect = outline.rect(ofRow: row)
        let visible = outline.visibleRect
        outline.scroll(NSPoint(x: visible.minX, y: max(rect.midY - visible.height / 2, 0)))
        return true
    }

    // MARK: Colour drops (LIB-031)

    /// The object a colour dropped on `item` paints, and which paint: an object row that is not
    /// locked, on a layer that is visible and unlocked; kbd:[Cmd] paints the stroke, as on the
    /// canvas, anything else the fill.  Nil: refused (a layer row, the separator, between rows).
    func colorTarget(item: LayersTreeItem?, index: Int, modifiers: KeyModifiers) -> (node: OpID, target: ColorTarget)? {
        guard index == NSOutlineViewDropOnItemIndex, let item, case .object(let node) = item.kind, let model else { return nil }
        let state = model.document.state
        guard let layer = model.order.layer(of: node, in: state), let info = model.order.layer(layer), info.visible, !info.locked,
              !Objects.isEffectivelyLocked(node, in: state, layers: model.order) else { return nil }
        return (node, modifiers.contains(.command) && !modifiers.contains(.shift) ? .stroke : .fill)
    }

    static func carriesColor(_ pasteboard: NSPasteboard) -> Bool {
        !(pasteboard.types ?? []).contains(rowType) && ColorDrag.read(from: pasteboard, defaultSpace: .sRGB) != nil
    }

    /// The colour on `pasteboard` dropped on `item`: one change (`ApplyColor`), a swatch from
    /// another document created first (`ColorDrop`).
    @discardableResult
    func dropColor(_ pasteboard: NSPasteboard, on item: LayersTreeItem?, index: Int, modifiers: KeyModifiers) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let model, let target = colorTarget(item: item, index: index, modifiers: modifiers),
              let payload = ColorDrag.read(from: pasteboard, defaultSpace: model.state.defaultColorSpace()) else { return nil }
        let document = model.document
        let editing = model.editing
        return Task { @MainActor in
            let ref = await ColorDrop.reference(for: payload, in: document)
            return await editing.perform(ApplyColor([target.node], target: target.target, color: ref, name: payload.name)).value
        }
    }

    // MARK: Name editing

    /// The row cell `view` is in.
    static func cell<Cell: NSTableCellView>(of view: NSView) -> Cell? {
        var current = view.superview
        while let candidate = current {
            if let cell = candidate as? Cell { return cell }
            current = candidate.superview
        }
        return nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let model else { return false }
        if let cell: LayerRowCell = Self.cell(of: control), let layer = cell.layerInfo {
            model.cancelRename()
            cell.endEditing(name: layer.name.isEmpty ? "Layer" : layer.name)
        } else if let cell: ObjectRowCell = Self.cell(of: control), let node = cell.node {
            model.cancelObjectRename()
            cell.endEditing(name: tree.label(of: node))
        }
        control.window?.makeFirstResponder(outline)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let model else { return }
        if let cell: LayerRowCell = Self.cell(of: field), let layer = cell.layerInfo, model.state.renaming == layer.id {
            model.commitRename(layer.id, to: field.stringValue)
            cell.endEditing(name: nil)
        } else if let cell: ObjectRowCell = Self.cell(of: field), let node = cell.node, model.state.renamingObject == node {
            model.commitObjectRename(node, to: field.stringValue)
            cell.endEditing(name: nil)
        } else {
            return
        }
        // A name ended with Return leaves the keys with the rows, to go on to the next one.
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
            outline.window?.makeFirstResponder(outline)
        }
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let view = LayersRowView()
        if let item = item as? LayersTreeItem, case .layer(let id) = item.kind { view.playing = marks[id]?.playing ?? false }
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? LayersTreeItem, let model else { return nil }
        switch item.kind {
        case .separator:
            let view = outlineView.makeView(withIdentifier: Self.separatorCell, owner: nil) as? SeparatorCell ?? SeparatorCell()
            view.identifier = Self.separatorCell
            return view
        case .layer(let id):
            let cell = outlineView.makeView(withIdentifier: Self.layerCell, owner: nil) as? LayerRowCell ?? LayerRowCell()
            cell.identifier = Self.layerCell
            if let layer = model.order.layer(id) {
                cell.configure(model: model, layer: layer, index: model.layers.firstIndex { $0.id == id } ?? 0, marks: marks[id], controller: self)
            }
            return cell
        case .object(let node):
            let cell = outlineView.makeView(withIdentifier: Self.objectCell, owner: nil) as? ObjectRowCell ?? ObjectRowCell()
            cell.identifier = Self.objectCell
            cell.configure(model: model, tree: tree, node: node, controller: self)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? LayersTreeItem else { return false }
        return item.kind != .separator
    }

    func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool { false }

    /// The flag column a layer row's drag ended over: the layer row under `point` (in the
    /// outline), else the nearest layer row above it; its index among the layers.
    func layerIndex(at point: NSPoint) -> Int? {
        guard let model else { return nil }
        var row = outline.row(at: point)
        if row < 0 { row = point.y < 0 ? 0 : outline.numberOfRows - 1 }
        while row >= 0 {
            if let item = outline.item(atRow: row) as? LayersTreeItem, case .layer(let id) = item.kind {
                return model.layers.firstIndex { $0.id == id }
            }
            row -= 1
        }
        return nil
    }

    // MARK: Dragging

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? LayersTreeItem else { return nil }
        if case .object(let node) = item.kind, shown != nil || !tree.isMovable(node) { return nil }
        let writer = NSPasteboardItem()
        writer.setString(item.key, forType: Self.rowType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        dragged = draggedItems.compactMap { $0 as? LayersTreeItem }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragged = []
    }

    /// Where a drop of the dragged rows on `item` at `index` lands: the container and the index
    /// among its rows (nil: refused).  Layer and separator rows move among the root rows; object
    /// rows go into a layer or a group -- dropped on an object, beside it in its container.
    func dropTarget(item: LayersTreeItem?, index: Int) -> (container: LayersTreeItem?, index: Int)? {
        guard !dragged.isEmpty else { return nil }
        let objects = dragged.compactMap { item -> OpID? in
            if case .object(let id) = item.kind { return id }
            return nil
        }
        if objects.isEmpty {
            guard dragged.count == 1, item == nil, index >= 0 else { return nil }
            return (nil, index)
        }
        guard objects.count == dragged.count, let item, let node = item.node else { return nil }
        var container = item
        var at = index
        if index < 0 {
            if tree.accepts(node) {
                at = 0
            } else {
                guard let parentItem = outline.parent(forItem: item) as? LayersTreeItem, let parent = parentItem.node else { return nil }
                container = parentItem
                at = max(outline.childIndex(forItem: item), 0)
                _ = parent
            }
        }
        guard let target = container.node, tree.accepts(target) else { return nil }
        if objects.contains(where: { tree.isWithin(target, $0) }) { return nil }
        if let layer = tree.order.layer(target), layer.locked { return nil }
        if tree.order.layer(target) == nil, Objects.isEffectivelyLocked(target, in: tree.state, layers: tree.order) { return nil }
        return (container, at)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        if Self.carriesColor(info.draggingPasteboard) {
            return colorTarget(item: item as? LayersTreeItem, index: index, modifiers: dropModifiers()) == nil ? [] : .copy
        }
        guard let target = dropTarget(item: item as? LayersTreeItem, index: index) else { return [] }
        if target.container !== (item as? LayersTreeItem) || target.index != index {
            outlineView.setDropItem(target.container, dropChildIndex: target.index)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        defer { dragged = [] }
        if Self.carriesColor(info.draggingPasteboard) {
            return dropColor(info.draggingPasteboard, on: item as? LayersTreeItem, index: index, modifiers: dropModifiers()) != nil
        }
        return drop(item: item as? LayersTreeItem, index: index)
    }

    /// Performs the drop of the dragged rows; one change.
    @discardableResult
    func drop(item: LayersTreeItem?, index: Int) -> Bool {
        guard let model, let target = dropTarget(item: item, index: index) else { return false }
        if let container = target.container?.node {
            let nodes = dragged.compactMap(\.node)
            return model.dropObjects(nodes, into: container, at: target.index) != nil
        }
        guard let moved = dragged.first, let from = root.firstIndex(of: moved) else { return false }
        return model.perform(model.move(fromOffsets: IndexSet(integer: from), toOffset: target.index)) != nil
    }

    /// Starts a drag of `items` (tests stand in for the mouse).
    func beginDrag(_ items: [LayersTreeItem]) { dragged = items }

    // MARK: Menus

    private func menu(forRow row: Int) -> NSMenu? {
        guard let model, let item = outline.item(atRow: row) as? LayersTreeItem else { return nil }
        let entries: [LayerMenuItem]
        switch item.kind {
        case .layer(let id):
            guard let layer = model.order.layer(id) else { return nil }
            entries = model.contextItems(layer)
        case .object(let node):
            entries = model.objectContextItems(node, rename: { [weak self] in
                guard let self, let item = self.items[node] else { return }
                let row = self.outline.row(forItem: item)
                if row >= 0 { self.beginRename(row: row) }
            })
        case .separator:
            return nil
        }
        let menu = NSMenu()
        for entry in entries {
            let menuItem = NSMenuItem(title: entry.title, action: #selector(LayerMenuAction.run(_:)), keyEquivalent: "")
            let action = LayerMenuAction(entry.run)
            menuItem.target = action
            menuItem.representedObject = action
            menu.addItem(menuItem)
        }
        return menu
    }
}

/// A context-menu item's closure, kept by the item.
@MainActor
final class LayerMenuAction: NSObject {
    let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @objc func run(_ sender: Any?) { body() }
}

// MARK: - Cells

/// The separator between printing and background layers: draggable, not selectable.
final class SeparatorCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Layers below this line are background layers: they never print and draw dimmed"
        setAccessibilityIdentifier("layers.separator")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2).fill()
    }
}

/// A flag column of a layer row: a click toggles; a drag through the column applies the first
/// row's new value to every layer row crossed (layers.adoc, "Showing and hiding layers").
final class FlagControl: NSImageView {
    /// Called when the mouse goes up, with where it is in the window.
    var end: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            last = next.locationInWindow
            if next.type == .leftMouseUp { break }
        }
        end?(last)
    }

    override func accessibilityPerformPress() -> Bool {
        end?(convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
        return true
    }
}

/// A layer row: check mark, Preview/Keyline circle, padlock, highlight swatch, name, frame
/// number and the pen icon on the active layer.
final class LayerRowCell: NSTableCellView {
    let visible = FlagControl()
    let keyline = FlagControl()
    let lock = FlagControl()
    let swatch = NSColorWell(style: .minimal)
    let name = NSTextField(labelWithString: "")
    let frameNumber = NSTextField(labelWithString: "")
    let pen = NSImageView()
    private(set) var layerInfo: LayerInfo?
    private var model: LayersPanelModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = name
        name.lineBreakMode = .byTruncatingTail
        name.delegate = nil
        frameNumber.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        frameNumber.textColor = .secondaryLabelColor
        pen.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Active layer")
        pen.setAccessibilityIdentifier("layers.active")
        swatch.target = self
        swatch.action = #selector(colorChanged(_:))
        let stack = NSStackView(views: [visible, keyline, lock, swatch, name, frameNumber, pen])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for flag in [visible, keyline, lock] {
            flag.widthAnchor.constraint(equalToConstant: 16).isActive = true
            flag.heightAnchor.constraint(equalToConstant: 16).isActive = true
            flag.setAccessibilityRole(.button)
        }
        visible.setAccessibilityIdentifier("layers.visible")
        keyline.setAccessibilityIdentifier("layers.keyline")
        lock.setAccessibilityIdentifier("layers.locked")
        swatch.widthAnchor.constraint(equalToConstant: 20).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    func configure(model: LayersPanelModel, layer: LayerInfo, index: Int, marks: LayerFrameMarks?, controller: LayersOutlineController) {
        self.model = model
        self.layerInfo = layer
        visible.image = Self.symbol("checkmark", "Visible")
        visible.alphaValue = layer.visible ? 1 : 0.15
        keyline.image = Self.symbol(layer.keyline ? "circle" : "circle.fill", layer.keyline ? "Keyline" : "Preview")
        lock.image = Self.symbol(layer.locked ? "lock.fill" : "lock.open", layer.locked ? "Locked" : "Unlocked")
        for (control, flag) in [(visible, SetLayerFlag.Flag.visible), (keyline, .keyline), (lock, .locked)] {
            control.end = { [weak controller] point in
                guard let controller else { return }
                let local = controller.outline.convert(point, from: nil)
                let through = controller.layerIndex(at: local) ?? index
                LayerRow.column(model, flag, layer, index)(CGFloat(through - index) * LayersPanelBody.rowHeight)
            }
        }
        swatch.color = LayersPanelModel.swatch(layer)
        swatch.setAccessibilityIdentifier("layers.swatch.\(layer.id)")
        if model.state.renaming != layer.id {
            name.stringValue = layer.name.isEmpty ? "Layer" : layer.name
            name.isEditable = false
        }
        name.font = model.selectionLayers.contains(layer.id) ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        name.textColor = layer.printing ? .labelColor : .secondaryLabelColor
        name.delegate = controller
        frameNumber.stringValue = marks?.number.map(String.init) ?? ""
        frameNumber.isHidden = marks?.number == nil
        if let number = marks?.number { frameNumber.setAccessibilityIdentifier("layers.frame.\(number)") }
        pen.isHidden = model.activeLayer != layer.id
        toolTip = LayersPanelModel.tooltip(layer)
        setAccessibilityIdentifier("layers.row.\(layer.id)")
    }

    @objc func colorChanged(_ sender: NSColorWell) {
        guard let model, let layer = layerInfo else { return }
        let color = sender.color
        // The colour panel streams changes while its colour is dragged: previewed, written once it
        // settles (D-076).
        ContinuousInput.settle { model.setHighlight(layer.id, color: color) }
    }

    func beginEditing(_ controller: LayersOutlineController) {
        name.isEditable = true
        name.delegate = controller
        name.stringValue = layerInfo?.name ?? ""
        name.setAccessibilityIdentifier("layers.rename")
        window?.makeFirstResponder(name)
    }

    func endEditing(name text: String?) {
        name.isEditable = false
        if let text { name.stringValue = text }
        name.setAccessibilityIdentifier(nil)
    }
}

/// An object row: its kind's icon, a small picture of the object (LIB-031), its name (or its
/// default label, dimmed), and its eye and padlock.
final class ObjectRowCell: NSTableCellView {
    let icon = NSImageView()
    let thumbnail = NSImageView()
    let name = NSTextField(labelWithString: "")
    let eye = NSButton()
    let lock = NSButton()
    private(set) var node: OpID?
    private var model: LayersPanelModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        textField = name
        imageView = icon
        name.lineBreakMode = .byTruncatingTail
        for button in [eye, lock] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.imagePosition = .imageOnly
            button.target = self
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
        }
        eye.action = #selector(toggleHidden(_:))
        lock.action = #selector(toggleLocked(_:))
        eye.setAccessibilityIdentifier("layers.object.visible")
        lock.setAccessibilityIdentifier("layers.object.locked")
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        thumbnail.imageScaling = .scaleProportionallyDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.borderWidth = 0.5
        thumbnail.layer?.borderColor = NSColor.separatorColor.cgColor
        thumbnail.widthAnchor.constraint(equalToConstant: LayersThumbnails.side).isActive = true
        thumbnail.heightAnchor.constraint(equalToConstant: LayersThumbnails.side).isActive = true
        thumbnail.setAccessibilityElement(false)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, thumbnail, name, eye, lock])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(model: LayersPanelModel, tree: ObjectTree, node: OpID, controller: LayersOutlineController) {
        self.model = model
        if let previous = self.node, previous != node { controller.thumbnails.forget(previous) }
        self.node = node
        showThumbnail(controller.thumbnails.image(for: node))
        let row = LayersPanelModel.ObjectRow(node, tree: tree, hidden: model.document.locallyHidden)
        icon.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.kindTitle)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: row.kindTitle)
        if model.state.renamingObject != node {
            name.stringValue = row.label
            name.isEditable = false
        }
        name.textColor = row.isNamed ? (row.hidden ? .secondaryLabelColor : .labelColor) : .secondaryLabelColor
        name.font = row.isNamed ? .systemFont(ofSize: NSFont.systemFontSize) : NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
        name.delegate = controller
        eye.image = NSImage(systemSymbolName: row.hidden ? "eye.slash" : "eye", accessibilityDescription: row.hidden ? "Hidden on this Mac" : "Visible")
        eye.alphaValue = row.hidden ? 1 : 0.35
        eye.toolTip = row.hidden ? "Show (hidden on this Mac only)" : "Hide on this Mac (View > Hide Selection)"
        lock.image = NSImage(systemSymbolName: row.locked ? "lock.fill" : "lock.open", accessibilityDescription: row.locked ? "Locked" : "Unlocked")
        lock.alphaValue = row.locked ? 1 : 0.35
        toolTip = row.tooltip
        setAccessibilityIdentifier("layers.object.\(node)")
    }

    /// The object's picture; blank while it is first drawn.
    func showThumbnail(_ image: CGImage?) {
        thumbnail.image = LayersThumbnails.picture(image)
    }

    @objc func toggleHidden(_ sender: Any?) {
        guard let model, let node else { return }
        model.toggleHidden(node)
    }

    @objc func toggleLocked(_ sender: Any?) {
        guard let model, let node else { return }
        model.perform(model.toggleLocked(node))
    }

    func beginEditing(_ controller: LayersOutlineController) {
        guard let model, let node else { return }
        name.isEditable = true
        name.delegate = controller
        name.stringValue = model.tree.name(of: node) ?? ""
        name.placeholderString = model.tree.defaultLabel(of: node)
        name.setAccessibilityIdentifier("layers.object.rename")
        window?.makeFirstResponder(name)
    }

    func endEditing(name text: String?) {
        name.isEditable = false
        if let text { name.stringValue = text }
        name.setAccessibilityIdentifier(nil)
    }
}
