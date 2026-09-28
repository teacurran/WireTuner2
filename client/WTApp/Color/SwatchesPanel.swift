import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Swatches panel's state and actions (swatches.adoc; COLOR-007): the list as sections and
/// rows, the selected swatches (local view state, never synced), inline rename, removal with the
/// in-use sheet, reordering, drops (redefine on a swatch, add below the list or on the Add
/// arrow, the Fill / Stroke / Both wells), *Hide Names*, groups and the Options menu.  A click
/// with objects selected applies the swatch to them; with nothing selected it selects swatches.
@MainActor
@Observable
final class SwatchesPanelModel {
    /// One line of the list: a group header or a swatch.
    enum Row: Identifiable, Hashable {
        case header(String, collapsed: Bool)
        case swatch(Swatch)

        var id: String {
            switch self {
            case .header(let name, _): "group:\(name)"
            case .swatch(let swatch): "swatch:\(swatch.id)"
            }
        }
    }

    let workspace: ColorWorkspace
    /// The selected swatches.
    var selected: Set<OpID> = []
    /// Where a kbd:[Shift]-click extends from.
    private(set) var anchor: OpID?
    /// *Hide Names*: a grid of chips.
    var namesHidden = false
    /// Collapsed group headers.
    var collapsed: Set<String> = []
    /// The swatch whose name is being edited, and the typed text.
    var renaming: OpID?
    var renameText = ""
    /// Counts refused renames (the field shakes each time).
    private(set) var refusedRenames = 0
    /// The swatches waiting on the in-use sheet.
    private(set) var pendingRemoval: [OpID] = []
    /// The modifier keys of the click being handled; replaceable in tests.
    @ObservationIgnored var modifiers: @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// kbd:[Option]-click hands a swatch to the Tints panel (tints.adoc).
    @ObservationIgnored var loadTint: @MainActor (OpID) -> Void = { _ in }

    static let removeSheet = "swatches.remove-sheet"
    static let groupSheet = "swatches.group-sheet"

    init(workspace: ColorWorkspace) {
        self.workspace = workspace
    }

    var swatches: SwatchesModel? { workspace.swatches }
    var list: SwatchList? { swatches?.list }

    /// The rows in panel order: the ungrouped swatches, then each group's header and (unless
    /// collapsed) its swatches.
    var rows: [Row] {
        guard let list else { return [] }
        var rows: [Row] = []
        for section in list.sections {
            let isCollapsed = collapsed.contains(section.group)
            if !section.group.isEmpty { rows.append(.header(section.group, collapsed: isCollapsed)) }
            if !isCollapsed { rows += section.swatches.map(Row.swatch) }
        }
        return rows
    }

    /// The swatches the list shows, in order.
    var visibleSwatches: [Swatch] {
        rows.compactMap { if case .swatch(let swatch) = $0 { swatch } else { nil } }
    }

    /// The selected swatches that are still listed, in list order.
    var selection: [Swatch] {
        (list?.swatches ?? []).filter { selected.contains($0.id) }
    }

    // MARK: The wells

    /// What the Fill or Stroke well shows: the selected objects' colour on their topmost Basic
    /// row of that kind, mixed when they differ; nil with nothing selected.
    func well(_ target: ColorTarget) -> ColorWellModel? {
        guard let document = workspace.document, !workspace.selectedNodes.isEmpty else { return nil }
        if let text = TextSwatchTarget.well(workspace.selectedNodes, target: target, document: document, appliesTo: TextSwatchTarget.appliesTo(workspace.preferences ?? workspace.selection.preferences)) {
            return text
        }
        let state = document.state
        let refs = ApplyColor.rows(workspace.selectedNodes, target: target, in: state).compactMap { row in
            AppearanceEditing.entries(row.node, in: state).first { $0.row == row.row }.flatMap(AttributeFields.color)
        }
        let first = refs.first
        return ColorWellModel(ref: refs.allSatisfy { $0 == first } ? first ?? ColorResolver.none : nil, state: state, documentID: document.id)
    }

    // MARK: Clicking

    /// A click on a swatch: with objects selected it applies the swatch to them (Fill, Stroke
    /// or Both); kbd:[Option] loads it into the Tints panel; otherwise it selects, kbd:[Shift]
    /// extending to adjacent swatches and kbd:[Cmd] adding or removing one.
    @discardableResult
    func click(_ id: OpID) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let flags = modifiers()
        if flags.contains(.option) {
            loadTint(id)
            return nil
        }
        if !workspace.selectedNodes.isEmpty, let list, let swatch = list[id] {
            return workspace.apply(list.resolver.reference(to: id), name: swatch.name)
        }
        select(id, extend: flags.contains(.shift), toggle: flags.contains(.command))
        return nil
    }

    func select(_ id: OpID, extend: Bool = false, toggle: Bool = false) {
        let order = visibleSwatches.map(\.id)
        if extend, let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            selected = Set(order[min(from, to)...max(from, to)])
            return
        }
        if toggle {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
        anchor = id
    }

    // MARK: Renaming

    /// kbd:[Return] or a double-click: edits the name of `id` (the single selected swatch by
    /// default).  The protected swatches are not renamed.
    func beginRename(_ id: OpID? = nil) {
        guard let id = id ?? (selected.count == 1 ? selected.first : nil), let swatch = list?[id], !swatch.isProtected else { return }
        renaming = id
        renameText = swatch.props.common.name.isEmpty ? swatch.name : swatch.props.common.name
    }

    /// kbd:[Return] in the field: renames, or -- when another swatch holds the name -- shakes and
    /// stays open.
    @discardableResult
    func commitRename() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let id = renaming, let list, let swatch = list[id] else {
            renaming = nil
            return nil
        }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if list.isTaken(name, except: id) || (name.isEmpty && !swatch.isTint) {
            refusedRenames += 1
            return nil
        }
        renaming = nil
        return workspace.perform(RenameSwatch(id, to: name, from: swatch.name))
    }

    /// kbd:[Esc].
    func cancelRename() {
        renaming = nil
    }

    // MARK: Removing

    /// The selected swatches that can be removed (not the defaults).
    var removable: [Swatch] { selection.filter { !$0.isProtected } }

    /// *Remove* / kbd:[Delete]: removes the selected swatches, asking first when any is in use.
    @discardableResult
    func remove() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = removable.map(\.id)
        guard let swatches, !ids.isEmpty, let list else { return nil }
        let used = swatches.userCount(of: ids.flatMap { [$0] + list.tints(of: $0) })
        guard used == 0 else {
            pendingRemoval = ids
            workspace.present(RemoveSwatchesSheet(count: ids.count, users: used, model: self), title: "Remove Colors", identifier: Self.removeSheet)
            return nil
        }
        return perform(removing: ids, unusedOnly: false)
    }

    /// The sheet's btn:[Remove All].
    @discardableResult
    func removeAll() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        finishRemoval(unusedOnly: false)
    }

    /// The sheet's btn:[Remove Unused Only].
    @discardableResult
    func removeUnused() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        finishRemoval(unusedOnly: true)
    }

    /// The sheet's btn:[Cancel].
    func cancelRemoval() {
        pendingRemoval = []
        workspace.dismiss(Self.removeSheet)
    }

    private func finishRemoval(unusedOnly: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = pendingRemoval
        cancelRemoval()
        return ids.isEmpty ? nil : perform(removing: ids, unusedOnly: unusedOnly)
    }

    private func perform(removing ids: [OpID], unusedOnly: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let names = ids.compactMap { list?[$0]?.name }
        selected.subtract(ids)
        return workspace.perform(RemoveSwatches(ids, unusedOnly: unusedOnly, index: swatches?.index, names: names))
    }

    // MARK: Ordering

    /// A drag by name to a new place: `offsets` and `destination` index `visibleSwatches`.
    /// Tints move with their base; the defaults stay at the top.
    @discardableResult
    func move(_ offsets: IndexSet, to destination: Int) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let order = visibleSwatches
        let moving = offsets.map { order[$0] }.filter { !$0.isProtected && !$0.isTint }.map(\.id)
        guard !moving.isEmpty else { return nil }
        let before = order[..<min(destination, order.count)].filter { !moving.contains($0.id) && !$0.isTint && !$0.isProtected }
        return workspace.perform(MoveSwatches(moving, after: before.last?.id))
    }

    // MARK: Drops

    /// A colour dropped on the swatch `target` redefines it (a tint dropped on with kbd:[Option]
    /// held and a swatch payload is re-based instead); dropped anywhere else it is added (a
    /// swatch from another document with its tints).
    @discardableResult
    func drop(_ payload: ColorRefPasteboard, on target: OpID?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let document = workspace.document, let list else { return nil }
        if let target, let swatch = list[target] {
            let base = ColorResolver.swatch(of: payload.ref)
            // The Tints panel's well dragged back onto a tint of the same base: its percentage.
            if swatch.isTint, case .tint(let tint)? = payload.ref.ref, payload.document == document.id, base == swatch.base {
                return workspace.perform(SetTintPercent(target, percent: tint.percent))
            }
            if swatch.isTint, modifiers().contains(.option), let base, payload.document == document.id, list[base] != nil {
                return workspace.perform(RebaseTint(target, onto: base))
            }
            guard let color = payload.color, !swatch.isProtected else { return nil }
            return workspace.perform(RedefineSwatch(target, to: color, autoRename: workspace.autoRename, name: swatch.name))
        }
        if ColorDrop.needsImport(payload, into: document.id) {
            return Task { @MainActor in
                _ = await ColorDrop.reference(for: payload, in: document)
                return nil
            }
        }
        guard let color = payload.color else { return nil }
        return workspace.perform(AddSwatch(color, spot: payload.spot))
    }

    /// A drop read from the drag pasteboard.
    @discardableResult
    func drop(from pasteboard: NSPasteboard, on target: OpID?) -> Bool {
        // A gradient's ramp dropped anywhere but on a swatch keeps it as a gradient swatch (ATTR-029).
        if target == nil, GradientRampDrag.read(from: pasteboard) != nil { return dropRamp(from: pasteboard) }
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace) else { return false }
        drop(payload, on: target)
        return true
    }

    /// A colour dropped on the Fill, Stroke or Both well applies it to the selection.
    @discardableResult
    func dropOnWell(from pasteboard: NSPasteboard, target: ColorTarget) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace), let document = workspace.document else { return false }
        workspace.apply(payload.reference(in: document.state, document: document.id), name: payload.name, target: target)
        return true
    }

    /// A swatch dropped on a group header joins that group.
    @discardableResult
    func drop(from pasteboard: NSPasteboard, onGroup group: String) -> Bool {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: workspace.defaultSpace), let id = ColorResolver.swatch(of: payload.ref),
              payload.document == workspace.document?.id, list?[id] != nil else { return false }
        workspace.perform(SetSwatchGroup([id], group: group))
        return true
    }

    /// Dragging a swatch's chip carries the swatch (and its tints).
    func dragPayload(_ id: OpID) -> ColorRefPasteboard? {
        guard let document = workspace.document, let list else { return nil }
        return ColorRefPasteboard(swatch: id, list: list, document: document.id)
    }

    // MARK: Options menu

    func toggleNames() {
        namesHidden.toggle()
    }

    func toggleGroup(_ name: String) {
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
    }

    @discardableResult
    func duplicate() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let swatch = selection.first else { return nil }
        return workspace.perform(DuplicateSwatch(swatch.id, name: swatch.name))
    }

    @discardableResult
    func setSpot(_ spot: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let ids = selection.map(\.id)
        return ids.isEmpty ? nil : workspace.perform(SetSwatchSpot(ids, spot: spot))
    }

    /// *Convert to*: named, unprotected swatches not already in `space`, with no object selected.
    func canConvert(to space: RenderColor.Space) -> Bool {
        workspace.selectedNodes.isEmpty && !selection.isEmpty && selection.allSatisfy { ConvertSwatchSpace.canConvert($0, to: space) }
    }

    @discardableResult
    func convert(to space: RenderColor.Space) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard canConvert(to: space) else { return nil }
        let swatches = selection
        return workspace.perform(ConvertSwatchSpace(swatches.map(\.id), to: space, autoRename: workspace.autoRename, name: swatches.count == 1 ? swatches[0].name : ""))
    }

    /// *New Group…*: asks for a name, then puts the selected swatches in it.
    func newGroup() {
        workspace.present(NewGroupSheet(model: self), title: "New Group", identifier: Self.groupSheet)
    }

    /// The group sheet's btn:[OK].
    @discardableResult
    func createGroup(named name: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.groupSheet)
        let ids = selection.filter { !$0.isProtected }.map(\.id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ids.isEmpty, !trimmed.isEmpty else { return nil }
        return workspace.perform(SetSwatchGroup(ids, group: trimmed))
    }

    func cancelGroup() {
        workspace.dismiss(Self.groupSheet)
    }

    /// The panel's Options menu (swatches.adoc, "The panel").
    func optionsMenu(extras: [PanelMenuItem] = []) -> [PanelMenuItem] {
        let hasSelection = !selection.isEmpty
        var items: [PanelMenuItem] = [
            PanelMenuItem(title: "Duplicate", isEnabled: hasSelection) { [weak self] in self?.duplicate() },
            PanelMenuItem(title: "Remove", isEnabled: !removable.isEmpty) { [weak self] in self?.remove() },
            PanelMenuItem(title: "Make Spot", isEnabled: hasSelection) { [weak self] in self?.setSpot(true) },
            PanelMenuItem(title: "Make Process", isEnabled: hasSelection) { [weak self] in self?.setSpot(false) },
        ]
        for space in ConvertSwatchSpace.targets {
            items.append(PanelMenuItem(title: "Convert to \(ConvertSwatchSpace.title(space))", isEnabled: canConvert(to: space)) { [weak self] in self?.convert(to: space) })
        }
        items.append(PanelMenuItem(title: namesHidden ? "Show Names" : "Hide Names") { [weak self] in self?.toggleNames() })
        items.append(PanelMenuItem(title: "New Group…", isEnabled: !removable.isEmpty) { [weak self] in self?.newGroup() })
        return items + extras
    }
}

// MARK: - Views

/// The Swatches panel body: the Fill / Stroke / Both wells, the Add arrow, and the list (or the
/// chip grid with names hidden).
struct SwatchesPanelBody: View {
    let model: SwatchesPanelModel

    static func selecting(_ target: ColorTarget, _ workspace: ColorWorkspace) -> () -> Void {
        { workspace.target = target }
    }

    static func clicking(_ id: OpID, _ model: SwatchesPanelModel) -> () -> Void {
        { model.click(id) }
    }

    static func renaming(_ id: OpID, _ model: SwatchesPanelModel) -> () -> Void {
        { model.beginRename(id) }
    }

    static func toggling(_ group: String, _ model: SwatchesPanelModel) -> () -> Void {
        { model.toggleGroup(group) }
    }

    static func dropping(on target: OpID?, _ model: SwatchesPanelModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.drop(from: pasteboard, on: target) }
    }

    static func droppingOnWell(_ target: ColorTarget, _ model: SwatchesPanelModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.dropOnWell(from: pasteboard, target: target) }
    }

    static func droppingOnGroup(_ group: String, _ model: SwatchesPanelModel, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> ([NSItemProvider]) -> Bool {
        { _ in model.drop(from: pasteboard, onGroup: group) }
    }

    static func dragging(_ id: OpID, _ model: SwatchesPanelModel) -> () -> NSItemProvider {
        { model.dragPayload(id).map(ColorDrag.itemProvider) ?? NSItemProvider() }
    }

    static func moving(_ model: SwatchesPanelModel) -> (IndexSet, Int) -> Void {
        { model.move($0, to: $1) }
    }

    /// kbd:[Return] in the list starts renaming the selected swatch.
    static func returnKey(_ model: SwatchesPanelModel) -> () -> KeyPress.Result {
        {
            guard model.renaming == nil else { return .ignored }
            model.beginRename()
            return .handled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.swatches == nil {
                Text("Open a document to see its colors.").font(.callout).foregroundStyle(.secondary).padding()
            } else if model.namesHidden {
                chipGrid
            } else {
                list
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelContextMenu(.swatchesArea)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(ColorTarget.allCases, id: \.self) { target in
                Button(action: Self.selecting(target, model.workspace)) {
                    VStack(spacing: 2) {
                        ColorChipView(chip: model.well(target == .stroke ? .stroke : .fill)?.chip ?? .none, size: CGSize(width: 18, height: 14))
                        Text(target.title).font(.caption2)
                    }
                    .padding(2)
                    .background(model.workspace.target == target ? SwiftUI.Color.accentColor.opacity(0.25) : SwiftUI.Color.clear)
                }
                .buttonStyle(.plain)
                .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.droppingOnWell(target, model))
                .accessibilityIdentifier("swatches.target.\(target.rawValue)")
                .accessibilityValue(model.workspace.target == target ? "on" : "off")
            }
            Spacer()
            Image(systemName: "arrow.down.to.line")
                .help("Add")
                .onDrop(of: Self.addDropTypes, isTargeted: nil, perform: Self.dropping(on: nil, model))
                .accessibilityIdentifier("swatches.add")
        }
    }

    /// A document's swatches can run to hundreds: the list fills over two updates (ListRowGrowth).
    private var list: some View {
        let rows = model.rows
        return GrowingRows(count: rows.count) { limit in
            rowList(limit < rows.count ? Array(rows.prefix(limit)) : rows)
        }
    }

    private func rowList(_ rows: [SwatchesPanelModel.Row]) -> some View {
        List {
            ForEach(rows) { row in
                switch row {
                case .header(let name, let collapsed):
                    Button(action: Self.toggling(name, model)) {
                        Label(name, systemImage: collapsed ? "chevron.right" : "chevron.down").font(.caption.bold())
                    }
                    .buttonStyle(.plain)
                    .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.droppingOnGroup(name, model))
                    .accessibilityIdentifier("swatches.group.\(name)")
                case .swatch(let swatch):
                    SwatchRowView(swatch: swatch, model: model)
                        .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(on: swatch.id, model))
                }
            }
            .onMove(perform: Self.moving(model))
            GradientSwatchRows(model: model)
            SwiftUI.Color.clear.frame(height: 24)
                .onDrop(of: Self.addDropTypes, isTargeted: nil, perform: Self.dropping(on: nil, model))
                .accessibilityIdentifier("swatches.below")
        }
        .onDeleteCommand(perform: ColorAction.run(model.remove))
        .onKeyPress(.return, action: Self.returnKey(model))
        .onExitCommand(perform: model.cancelRename)
        .accessibilityIdentifier("swatches.list")
    }

    private var chipGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 10), spacing: 4) {
            ForEach(model.visibleSwatches) { swatch in
                Button(action: Self.clicking(swatch.id, model)) {
                    ColorChipView(chip: .color(model.chipColor(swatch)), size: CGSize(width: 20, height: 20))
                        .overlay(Rectangle().stroke(SwiftUI.Color.primary, lineWidth: model.selected.contains(swatch.id) ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .onDrag(Self.dragging(swatch.id, model))
                .onDrop(of: ColorDrag.dropTypes, isTargeted: nil, perform: Self.dropping(on: swatch.id, model))
                .accessibilityIdentifier("swatches.chip.\(swatch.name)")
            }
        }
        .accessibilityIdentifier("swatches.grid")
    }
}

/// One swatch: chip (drag it to drop the colour elsewhere), name -- italic for process, upright
/// for spot, indented under its base for a tint, a field while renaming -- the space badge and
/// the "base color removed" mark.
struct SwatchRowView: View {
    let swatch: Swatch
    let model: SwatchesPanelModel

    static func renameBinding(_ model: SwatchesPanelModel) -> Binding<String> {
        Binding(get: { model.renameText }, set: { model.renameText = $0 })
    }

    var body: some View {
        HStack(spacing: 6) {
            ColorChipView(chip: .color(model.chipColor(swatch)))
                .onDrag(SwatchesPanelBody.dragging(swatch.id, model))
            if model.renaming == swatch.id {
                TextField("Name", text: Self.renameBinding(model))
                    .onSubmit(ColorAction.run(model.commitRename))
                    .offset(x: model.refusedRenames % 2 == 0 ? 0 : 4)
                    .animation(.default, value: model.refusedRenames)
                    .accessibilityIdentifier("swatches.rename")
            } else {
                Button(action: SwatchesPanelBody.clicking(swatch.id, model)) {
                    Text(swatch.name).italic(!swatch.isSpot)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded(SwatchesPanelBody.renaming(swatch.id, model)))
            }
            Spacer()
            if swatch.baseRemoved {
                Image(systemName: "exclamationmark.triangle").help("Base color removed").accessibilityIdentifier("swatches.base-removed")
            }
            if model.libraryMissing(swatch) {
                Image(systemName: "questionmark.square.dashed").help(SpotChips.unavailable).accessibilityIdentifier("swatches.library-missing")
            }
            if let badge = swatch.badge {
                Text(badge).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, Double(swatch.depth) * 14)
        .background(model.selected.contains(swatch.id) ? SwiftUI.Color.accentColor.opacity(0.2) : SwiftUI.Color.clear)
        .accessibilityIdentifier("swatches.row.\(swatch.name)")
    }
}

/// The in-use sheet of *Remove* (swatches.adoc, "Removing colors").
struct RemoveSwatchesSheet: View {
    let count: Int
    let users: Int
    let model: SwatchesPanelModel

    static func message(count: Int, users: Int) -> String {
        let colors = count == 1 ? "This color is" : "These \(count) colors are"
        return "\(colors) used by \(users) \(users == 1 ? "object" : "objects").  Removing keeps each object's color as an unnamed color."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove Colors").font(.headline)
            Text(Self.message(count: count, users: users)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: model.cancelRemoval).keyboardShortcut(.cancelAction).accessibilityIdentifier("swatches.remove.cancel")
                Spacer()
                Button("Remove Unused Only", action: ColorAction.run(model.removeUnused)).accessibilityIdentifier("swatches.remove.unused")
                Button("Remove All", action: ColorAction.run(model.removeAll)).keyboardShortcut(.defaultAction).accessibilityIdentifier("swatches.remove.all")
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// *New Group…*.
struct NewGroupSheet: View {
    let model: SwatchesPanelModel
    @State private var name = ""

    static func creating(_ name: Binding<String>, _ model: SwatchesPanelModel) -> () -> Void {
        { model.createGroup(named: name.wrappedValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group").font(.headline)
            TextField("Group name", text: $name).accessibilityIdentifier("swatches.group.name")
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelGroup).keyboardShortcut(.cancelAction)
                Button("OK", action: Self.creating($name, model)).keyboardShortcut(.defaultAction).accessibilityIdentifier("swatches.group.ok")
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
