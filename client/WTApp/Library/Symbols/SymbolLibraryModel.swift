import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Library panel's symbols (library.adoc, "The Library panel"; the symbol half of LIB-011 over
/// LIB-009's commands): the list of folders and symbols with their instance counts, sortable by
/// name or count, a selection made with click, kbd:[Shift]-click (range) and kbd:[Cmd]-click
/// (toggle), the preview of the selected symbol, and every command of the bottom buttons and the
/// options menu -- each one change: *New Graphic* (Convert to Symbol), *Copy to Symbol*,
/// *New Folder*, *Duplicate*, *Remove* (with the sheet that asks what to do with instances),
/// *Swap*, *Place*, *Replace Artwork*, *Move to Folder* and *Move to Top Level*, and rename.
@MainActor
@Observable
final class SymbolLibraryModel {
    /// One row of the flattened outline.
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case symbol, folder, master }
        let id: OpID
        let kind: Kind
        let name: String
        /// Live instances in the document (symbols); the folder's symbols (folders).
        let count: Int
        let depth: Int
        /// The folder the row is listed in; nil at the top level.
        let folder: OpID?
        /// *Kind* (LIB-011; `SymbolLibraryKind`).
        var usage: SymbolLibraryKind = .graphic
        /// *Date*: the newest change to the symbol this Mac has seen.
        var changed: SymbolChangeLog.Entry?
    }

    enum Sort: String, CaseIterable { case name, count, kind, date }

    static let removeSheet = "library.remove-sheet"
    static let noDocument = "No document is open"
    static let noSymbol = "Select a symbol in the Library"
    static let noObjects = "Select objects on the canvas"

    let selection: ActiveSelection
    /// The library selection.
    private(set) var selected: Set<OpID> = []
    @ObservationIgnored private var anchor: OpID?
    var sort = Sort.name
    var ascending = true
    /// *Preview* in the options menu.
    var showsPreview = true
    /// The *Show* submenu: the kinds listed.
    var shown = Set(SymbolLibraryKind.allCases)
    /// The symbols the Remove sheet is asking about.
    private(set) var pendingRemoval: [OpID] = []
    var renaming: OpID?
    var renameText = ""
    /// Presents and dismisses the Remove sheet; replaceable in tests.
    @ObservationIgnored var present: @MainActor (SymbolLibraryModel) -> Void = { _ in }
    @ObservationIgnored var dismiss: @MainActor () -> Void = {}
    /// Opens a symbol's editing window (LIB-012, `SymbolEditingWindows`); nothing in tests.
    @ObservationIgnored var edit: @MainActor (OpID) -> Void = { _ in }
    /// Opens a master page in its tab (a master row's double-click; DOC-012's rest).
    @ObservationIgnored var editMaster: @MainActor (OpID) -> Void = { _ in }

    init(selection: ActiveSelection) {
        self.selection = selection
    }

    /// The Library panel's model once installed (LIB-016's team library menu reads its selection).
    static weak var installed: SymbolLibraryModel?

    var document: DocumentHandle? { selection.document }
    var editing: ObjectEditing? { selection.editing }
    private var state: EngineState { document?.state ?? EngineState() }

    /// Selected canvas objects (not guides or layers).
    var canvasObjects: [OpID] {
        let state = state
        return (selection.model?.selection.ids.map(\.opID) ?? []).filter { Objects.isObject($0, in: state) }
    }

    // MARK: The list

    /// The rows in outline order, each level sorted by the chosen column.
    var rows: [Row] {
        let state = state
        let counts = Symbols.instanceIndex(in: state).mapValues(\.count)
        var result: [Row] = []
        func visit(_ entries: [SymbolLibraryEntry], depth: Int, folder: OpID?) {
            let described = entries.map { entry -> (Row, [SymbolLibraryEntry]) in
                switch entry {
                case .symbol(let id):
                    return (Row(id: id, kind: .symbol, name: Self.name(of: id, in: state), count: counts[id] ?? 0, depth: depth, folder: folder,
                                usage: SymbolLibraryKind(state.props(id).symbol.usage), changed: document.flatMap { SymbolChangeLog.shared.entry(id, in: $0) }), [])
                case .folder(let id, let name, let children):
                    return (Row(id: id, kind: .folder, name: name, count: children.count, depth: depth, folder: folder), children)
                }
            }
            let sorted = described.filter { $0.0.kind != .symbol || shown.contains($0.0.usage) }.sorted { a, b in
                let key: Bool
                if sort == .count, a.0.count != b.0.count {
                    key = a.0.count < b.0.count
                } else if sort == .kind, a.0.usage != b.0.usage {
                    key = a.0.usage < b.0.usage
                } else if sort == .date, a.0.changed?.date != b.0.changed?.date {
                    key = (a.0.changed?.date ?? .distantPast) < (b.0.changed?.date ?? .distantPast)
                } else {
                    key = a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
                }
                return ascending ? key : !key
            }
            for (row, children) in sorted {
                result.append(row)
                visit(children, depth: depth + 1, folder: row.id)
            }
        }
        visit(Symbols.library(in: state), depth: 0, folder: nil)
        if shown.contains(.masterPage), let pages = document?.pageList {
            for master in pages.masters {
                result.append(Row(id: master.id, kind: .master, name: master.name.isEmpty ? "Master" : master.name,
                                  count: pages.pages.filter { $0.master == master.id }.count, depth: 0, folder: nil, usage: .masterPage))
            }
        }
        return result
    }

    /// A symbol's name ("Symbol" when it has none).
    static func name(of symbol: OpID, in state: EngineState) -> String {
        let name = state.props(symbol).symbol.common.name
        return name.isEmpty ? "Symbol" : name
    }

    /// Clicking a column header: that column, or the other direction.
    func sort(by column: Sort) {
        if sort == column { ascending.toggle() } else { sort = column; ascending = true }
    }

    // MARK: Selection

    func click(_ id: OpID, modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
            return
        }
        let rows = rows
        if modifiers.contains(.shift), let anchor, let from = rows.firstIndex(where: { $0.id == anchor }), let to = rows.firstIndex(where: { $0.id == id }) {
            selected = Set(rows[min(from, to)...max(from, to)].map(\.id))
            return
        }
        selected = [id]
        anchor = id
    }

    /// The selected rows that are still listed, in list order.
    var selectedRows: [Row] { rows.filter { selected.contains($0.id) } }

    /// The one selected symbol (Swap, Place, Replace Artwork, the preview).
    var selectedSymbol: OpID? {
        let symbols = selectedRows.filter { $0.kind == .symbol }
        return symbols.count == 1 ? symbols[0].id : nil
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        if let editing { return editing.perform(command) }
        return document?.perform(command)
    }

    /// btn:[New symbol] / *New Graphic*: the selected objects become a symbol and an instance of it.
    @discardableResult
    func newSymbol() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = canvasObjects
        guard !nodes.isEmpty else { return nil }
        return perform(ConvertToSymbol(nodes, layer: editing?.activeLayer))
    }

    /// menu:Modify[Symbol > Copy to Symbol]: a symbol from copies of the selection.
    @discardableResult
    func copyToSymbol() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let nodes = canvasObjects
        guard !nodes.isEmpty else { return nil }
        return perform(CopyToSymbol(nodes))
    }

    /// btn:[New folder]: in the selected folder, else at the top level.
    @discardableResult
    func newFolder() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let folder = selectedRows.count == 1 && selectedRows[0].kind == .folder ? selectedRows[0].id : nil
        return perform(CreateSymbolFolder(in: folder))
    }

    @discardableResult
    func duplicate() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let symbols = selectedRows.filter { $0.kind == .symbol }.map(\.id)
        guard !symbols.isEmpty else { return nil }
        return perform(DuplicateSymbols(symbols))
    }

    /// btn:[Remove]: asks first when a symbol has instances.
    @discardableResult
    func remove() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = selectedRows.filter { $0.kind != .master }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let counts = Symbols.instanceIndex(in: state)
        let symbols = ids.flatMap { id -> [OpID] in
            if case .folder = rows.first(where: { $0.id == id })?.kind { return Symbols.symbols(in: state).filter { isInside($0, id) } }
            return [id]
        }
        guard symbols.contains(where: { !(counts[$0] ?? []).isEmpty }) else { return commitRemove(ids, instances: .release) }
        pendingRemoval = ids
        present(self)
        return nil
    }

    /// Whether `node` is inside folder `folder`.
    private func isInside(_ node: OpID, _ folder: OpID) -> Bool {
        var current = state.store.placement(node)?.parent
        while let id = current {
            if id == folder { return true }
            current = state.store.placement(id)?.parent
        }
        return false
    }

    /// The Remove sheet's btn:[Release Instances] and btn:[Delete Instances].
    @discardableResult
    func confirmRemove(_ instances: InstanceHandling) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = pendingRemoval
        pendingRemoval = []
        dismiss()
        return ids.isEmpty ? nil : commitRemove(ids, instances: instances)
    }

    func cancelRemove() {
        pendingRemoval = []
        dismiss()
    }

    private func commitRemove(_ ids: [OpID], instances: InstanceHandling) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        selected.subtract(ids)
        return perform(RemoveSymbols(ids, instances: instances, in: state))
    }

    /// btn:[Swap]: the selected canvas objects become instances of the selected symbol.
    @discardableResult
    func swap() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let symbol = selectedSymbol, !canvasObjects.isEmpty else { return nil }
        return perform(SwapSymbol(canvasObjects, to: symbol))
    }

    /// *Place*: an instance of the selected symbol at the centre of the view.
    @discardableResult
    func place() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let symbol = selectedSymbol else { return nil }
        let point = editing?.visibleCenter() ?? .zero
        return perform(PlaceInstance(symbol, at: point, layer: editing?.activeLayer))
    }

    /// *Replace Artwork* (the drop of objects onto a symbol): the symbol's artwork becomes the
    /// selected objects.
    @discardableResult
    func replaceArtwork() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let symbol = selectedSymbol, !canvasObjects.isEmpty else { return nil }
        return perform(ReplaceSymbolArtwork(symbol, with: canvasObjects, layer: editing?.activeLayer))
    }

    /// *Move to Folder*: the selection (not the folder itself) into `folder`; nil is the top level.
    @discardableResult
    func move(to folder: OpID?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = selectedRows.map(\.id).filter { $0 != folder }
        guard !ids.isEmpty else { return nil }
        return perform(MoveSymbolsToFolder(ids, to: folder))
    }

    /// *Edit*, and a double-click on the preview or a symbol's icon: the selected symbol's
    /// editing window.  Returns whether one was asked for.
    @discardableResult
    func editSelected() -> Bool {
        guard let symbol = selectedSymbol else { return false }
        edit(symbol)
        return true
    }

    /// Double-click on a symbol's icon: selects it and opens its editing window; on a master
    /// page's, opens the master in its tab (master-pages.adoc, "Editing a master page").
    func editRow(_ id: OpID) {
        if rows.first(where: { $0.id == id })?.kind == .master { return editMaster(id) }
        guard rows.first(where: { $0.id == id })?.kind == .symbol else { return }
        click(id)
        editSelected()
    }

    /// Double-click on the name: rename in place.
    func beginRename(_ id: OpID) {
        guard rows.first(where: { $0.id == id })?.kind != .master else { return }
        renaming = id
        renameText = rows.first { $0.id == id }?.name ?? ""
    }

    /// kbd:[Return] in the name field.
    @discardableResult
    func commitRename() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        defer { renaming = nil }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renaming, !name.isEmpty, name != rows.first(where: { $0.id == id })?.name else { return nil }
        return perform(RenameLibraryEntry(node: id, name: name))
    }

    // MARK: Preview

    /// The selected symbol drawn to fit `size` points (2× pixels); nil without one.
    func preview(size: Size = Size(width: 200, height: 120)) -> CGImage? {
        guard showsPreview, let symbol = selectedSymbol, let document else { return nil }
        let item = SymbolRenderer().item(for: SymbolInstance(symbol: NodeID(symbol)), in: document.symbolLibrary)
        let list = DisplayList(canvas: "library", items: [item])
        guard let bounds = list.bounds, bounds.width > 0 || bounds.height > 0 else { return nil }
        let zoom = min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1)) * 0.9
        let origin = Point(x: bounds.center.x - size.width / 2 / zoom, y: bounds.center.y - size.height / 2 / zoom)
        return CoreGraphicsRenderer().renderBitmap(list, viewport: Viewport(scrollOrigin: origin, zoom: zoom, size: size), scale: 2)
    }

    // MARK: Menus

    /// The options menu (library.adoc, "The Library panel").
    func optionsMenu() -> [PanelMenuItem] {
        let hasDocument = document != nil
        let objects = !canvasObjects.isEmpty
        let symbol = selectedSymbol != nil
        let rows = selectedRows
        var items = [
            PanelMenuItem(title: "New Graphic", isEnabled: objects) { [weak self] in self?.newSymbol() },
            PanelMenuItem(title: "Copy to Symbol", isEnabled: objects) { [weak self] in self?.copyToSymbol() },
            PanelMenuItem(title: "New Folder", isEnabled: hasDocument) { [weak self] in self?.newFolder() },
            PanelMenuItem(title: "Duplicate", isEnabled: rows.contains { $0.kind == .symbol }) { [weak self] in self?.duplicate() },
            PanelMenuItem(title: "Remove", isEnabled: !rows.isEmpty) { [weak self] in self?.remove() },
            PanelMenuItem(title: "Swap", isEnabled: symbol && objects) { [weak self] in self?.swap() },
            PanelMenuItem(title: "Edit", isEnabled: symbol) { [weak self] in self?.editSelected() },
            PanelMenuItem(title: "Place", isEnabled: symbol) { [weak self] in self?.place() },
            PanelMenuItem(title: "Replace Artwork", isEnabled: symbol && objects) { [weak self] in self?.replaceArtwork() },
            PanelMenuItem(title: "Move to Top Level", isEnabled: rows.contains { $0.folder != nil }) { [weak self] in self?.move(to: nil) },
        ]
        for folder in self.rows where folder.kind == .folder && !selected.contains(folder.id) {
            items.append(PanelMenuItem(title: "Move to \u{201C}\(folder.name)\u{201D}", isEnabled: !rows.isEmpty) { [weak self] in self?.move(to: folder.id) })
        }
        for kind in SymbolLibraryKind.allCases {
            items.append(PanelMenuItem(title: (shown.contains(kind) ? "Hide " : "Show ") + kind.plural) { [weak self] in
                guard let self else { return }
                if self.shown.contains(kind) { self.shown.remove(kind) } else { self.shown.insert(kind) }
            })
        }
        items += SymbolTransferFeatures.shared?.menuItems(for: self) ?? []
        items.append(PanelMenuItem(title: showsPreview ? "Hide Preview" : "Show Preview") { [weak self] in self?.showsPreview.toggle() })
        return items
    }
}

/// Renames a symbol or a symbol folder (its `common.name`), one change "Rename".
struct RenameLibraryEntry: WTModel.Command {
    let node: OpID
    let name: String

    var label: String { "Rename" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kind = state.store.kind(node)
        var props = Wiretuner_Doc_V1_NodeProps()
        if kind == NodeKind.symbol.rawValue { props.symbol.common.name = name } else { props.symbolFolder.common.name = name }
        _ = builder.append(Ops.set(node, [RegisterPath([kind, 1, 1])], values: props))
    }
}
