import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel

// The Grid, Guides and Units sheets (grid-guides.adoc, "The grid" and "Adding guides precisely";
// rulers.adoc, "Custom units"; DOC-015, DOC-018).  Each model reads the document as it is now, so
// a remote change shows the next time the sheet reads; each button press is one change.  Values
// are typed and shown in the document's units (`Units`: suffixes, `7p6`, arithmetic).

/// The Grid sheet: the grid size in the document's units and *Relative grid*; btn:[OK] writes what
/// changed in one change ("Change grid").
@MainActor
@Observable
final class GridSheetModel {
    let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var sizeText: String
    var relative: Bool
    /// Why OK was refused.
    private(set) var problem: String?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
        let grid = document.settings.grid
        sizeText = document.unitConverter.format(grid.size)
        relative = grid.relative
    }

    static let invalidSize = "Type a grid size between 0 and 100 inches"

    /// btn:[OK]: the change, or nil with nothing changed; a size that is not a length is refused
    /// (and the sheet stays).
    @discardableResult
    func commit() -> Bool {
        let grid = document.settings.grid
        guard let size = document.unitConverter.parse(sizeText), size > 0, size <= 7200 else {
            problem = Self.invalidSize
            return false
        }
        let newSize = abs(size - grid.size) < 1e-9 ? nil : size
        let newRelative = relative == grid.relative ? nil : relative
        if newSize != nil || newRelative != nil { perform(SetGrid(size: newSize, relative: newRelative)) }
        return true
    }
}

struct GridSheet: View {
    @Bindable var model: GridSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grid").font(.headline)
            Form {
                TextField("Grid size", text: $model.sizeText).accessibilityIdentifier("grid.size")
                Toggle("Relative grid", isOn: $model.relative).accessibilityIdentifier("grid.relative")
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("grid.problem") }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK", action: SheetButtons.closing(model.commit, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("grid.ok")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// The Guides sheet (grid-guides.adoc, "Adding guides precisely" and "Editing, releasing and
/// removing guides"): the guides of one page, positions from its zero point; *Add* by count or
/// increment over a page range; *Edit*, *Release* and *Delete* on the selected rows.
@MainActor
@Observable
final class GuidesSheetModel {
    enum Placement: String, CaseIterable, Identifiable {
        case count, increment
        var id: String { rawValue }
        var title: String { self == .count ? "Count" : "Increment" }
    }

    /// One row: a guide (coincident ones as one) with its position from the zero point.
    struct Row: Identifiable, Equatable {
        var guide: PageGuide
        var position: String
        var id: OpID { guide.id }
        var axisTitle: String { guide.axis == .horizontal ? "Horizontal" : "Vertical" }
    }

    let document: DocumentHandle
    /// The page (or master page) whose guides are listed.
    let page: OpID
    @ObservationIgnored let layer: @MainActor () -> OpID?
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var selection: Set<OpID> = []
    var axis: PageGuide.Axis = .horizontal
    var placement: Placement = .count
    var countText = "1"
    var incrementText: String
    var firstText: String
    var lastText: String
    /// The page range *Add* adds to ("1-3, 5"); the page itself by default.
    var pagesText: String
    /// The position *Edit* writes.
    var editText = ""
    private(set) var problem: String?

    init(document: DocumentHandle, page: OpID, layer: @escaping @MainActor () -> OpID? = { nil },
         perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.page = page
        self.layer = layer
        self.perform = perform
        let units = document.unitConverter
        firstText = units.format(0)
        lastText = units.format(0)
        incrementText = units.format(72)
        pagesText = document.pageList.number(of: page).map(String.init) ?? ""
    }

    var pageList: PageList { document.pageList }

    /// The listed page's guides (a page's own; a master's on the master).
    var guides: [PageGuide] {
        pageList[page]?.guides ?? pageList.master(page)?.guides ?? []
    }

    /// Where positions count from: the page's zero point relative to its top-left (a master's is
    /// its bottom-left corner).
    var zero: Point {
        if let page = pageList[page] { return page.rulerOrigin }
        return Point(x: 0, y: pageList.master(page)?.geometry.height ?? 0)
    }

    /// A guide's position from the top-left (stored) as shown from the zero point, y upward.
    func shown(_ position: Double, axis: PageGuide.Axis) -> Double {
        axis == .horizontal ? zero.y - position : position - zero.x
    }

    /// A position typed from the zero point, stored from the top-left.
    func stored(_ value: Double, axis: PageGuide.Axis) -> Double {
        axis == .horizontal ? zero.y - value : value + zero.x
    }

    var rows: [Row] {
        let units = document.unitConverter
        return guides.map { Row(guide: $0, position: units.format(shown($0.position, axis: $0.axis), suffix: true)) }
    }

    /// The selected rows' guides, each holding every coincident element.
    var selectedGuides: [PageGuide] { guides.filter { selection.contains($0.id) } }

    // MARK: Buttons

    static let invalidPositions = "Type the first and last positions and how many guides, or their spacing"
    static let invalidPages = "Type pages such as 1-3, 5"

    /// The positions *Add* places, stored from each page's top-left; nil when the fields do not
    /// read.
    func positions() -> [Double]? {
        let units = document.unitConverter
        guard let first = units.parse(firstText), let last = units.parse(lastText) else { return nil }
        let values: [Double]
        switch placement {
        case .count:
            guard let count = Int(countText.trimmingCharacters(in: .whitespaces)), count >= 1 else { return nil }
            values = GuidePlacement.byCount(count, from: first, to: last)
        case .increment:
            guard let increment = units.parse(incrementText), increment > 0 else { return nil }
            values = GuidePlacement.byIncrement(increment, from: first, to: last)
        }
        return values.isEmpty ? nil : values.map { stored($0, axis: axis) }
    }

    /// The pages *Add* adds to: the typed range, or the listed master page itself.
    func targetPages() -> [OpID]? {
        if pageList.master(page) != nil { return [page] }
        guard let indices = try? PageRange.parse(pagesText, pageCount: pageList.pages.count) else { return nil }
        return indices.map { pageList.pages[$0].id }
    }

    /// btn:[Add]: one change over every page in the range ("Add N guides").
    func add() {
        guard let positions = positions() else {
            problem = Self.invalidPositions
            return
        }
        guard let pages = targetPages() else {
            problem = Self.invalidPages
            return
        }
        problem = nil
        perform(AddGuides(on: pages, axis: axis, at: positions))
    }

    /// btn:[Edit]: the selected guides move to the typed position ("Move guide" each, one change).
    func edit() {
        guard let value = document.unitConverter.parse(editText), !selectedGuides.isEmpty else {
            problem = Self.invalidPositions
            return
        }
        problem = nil
        let moves = selectedGuides.map { MoveGuide(on: page, $0.ids, to: stored(value, axis: $0.axis)) }
        perform(moves.count == 1 ? moves[0] : CommandBatch("Move \(moves.count) guides", moves))
    }

    /// btn:[Release]: the selected guides become paths on the current layer.
    func release() {
        let ids = selectedGuides.flatMap(\.ids)
        guard !ids.isEmpty else { return }
        perform(ReleaseGuides(on: page, ids, layer: layer()))
        selection = []
    }

    /// btn:[Delete].
    func delete() {
        let ids = selectedGuides.flatMap(\.ids)
        guard !ids.isEmpty else { return }
        perform(DeleteGuides(on: page, ids))
        selection = []
    }
}

struct GuidesSheet: View {
    @Bindable var model: GuidesSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guides").font(.headline)
            Table(model.rows, selection: $model.selection) {
                TableColumn("Axis", value: \.axisTitle)
                TableColumn("Position", value: \.position)
            }
            .frame(minHeight: 140)
            .accessibilityIdentifier("guides.list")
            HStack {
                TextField("Position", text: $model.editText).accessibilityIdentifier("guides.editPosition")
                Button("Edit", action: model.edit).disabled(model.selection.isEmpty).accessibilityIdentifier("guides.edit")
                Button("Release", action: model.release).disabled(model.selection.isEmpty).accessibilityIdentifier("guides.release")
                Button("Delete", action: model.delete).disabled(model.selection.isEmpty).accessibilityIdentifier("guides.delete")
            }
            GroupBox("Add") {
                Form {
                    Picker("Axis", selection: $model.axis) {
                        Text("Horizontal").tag(PageGuide.Axis.horizontal)
                        Text("Vertical").tag(PageGuide.Axis.vertical)
                    }
                    .accessibilityIdentifier("guides.axis")
                    Picker("Place by", selection: $model.placement) {
                        ForEach(GuidesSheetModel.Placement.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("guides.placement")
                    if model.placement == .count {
                        TextField("Count", text: $model.countText).accessibilityIdentifier("guides.count")
                    } else {
                        TextField("Increment", text: $model.incrementText).accessibilityIdentifier("guides.increment")
                    }
                    TextField("First", text: $model.firstText).accessibilityIdentifier("guides.first")
                    TextField("Last", text: $model.lastText).accessibilityIdentifier("guides.last")
                    TextField("Pages", text: $model.pagesText).accessibilityIdentifier("guides.pages")
                    Button("Add", action: model.add).accessibilityIdentifier("guides.add")
                }
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("guides.problem") }
            HStack {
                Spacer()
                Button("OK", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier("guides.ok")
            }
        }
        .padding()
        .frame(width: 400)
    }
}

/// The Units sheet (rulers.adoc, "Custom units"): the document's custom units, each one equal to an
/// amount of a built-in unit; btn:[+] adds one with a placeholder name, btn:[-] removes the
/// selected one (switching a document using it to points in the same change), and each edit is one
/// change.  A name another unit already has is marked.
@MainActor
@Observable
final class UnitsSheetModel {
    let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var selection: OpID?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
    }

    var units: [CustomUnit] { document.settings.customUnits }

    /// The bases a custom unit can be defined in.
    static let bases: [LengthUnit] = LengthUnit.standard

    /// Whether `unit`'s name is taken by an earlier unit (the suffix then names that one).
    func isDuplicate(_ unit: CustomUnit) -> Bool {
        document.unitConverter.custom(named: unit.name).map { $0.id != unit.id } ?? false
    }

    /// btn:[+]: "Unit N", equal to one point.
    func add() {
        let taken = Set(units.map(\.name))
        let name = (1...).lazy.map { "Unit \($0)" }.first { !taken.contains($0) }!
        perform(AddCustomUnit(name: name, amount: 1, base: .points))
    }

    /// A name typed in the list.
    func rename(_ unit: CustomUnit, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != unit.name else { return }
        perform(EditCustomUnit(unit.id, name: trimmed))
    }

    /// An amount typed, or a base chosen: the definition (one register, both together).
    func redefine(_ unit: CustomUnit, amount: Double? = nil, base: LengthUnit? = nil) {
        let amount = amount ?? unit.amount
        guard amount.isFinite, amount > 0, amount != unit.amount || (base ?? unit.base) != unit.base else { return }
        perform(EditCustomUnit(unit.id, amount: amount, base: base ?? unit.base))
    }

    /// btn:[-]: "Remove unit"; the document's unit becomes points in the same change when it was
    /// this one.
    func remove() {
        guard let id = selection, units.contains(where: { $0.id == id }) else { return }
        let remove = RemoveCustomUnit(id)
        perform(document.units == .custom(id) ? CommandBatch(remove.label, [remove, SetUnits(.points)]) : remove)
        selection = nil
    }
}

struct UnitsSheet: View {
    @Bindable var model: UnitsSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Units").font(.headline)
            List(selection: $model.selection) {
                ForEach(model.units) { unit in
                    UnitRow(model: model, unit: unit).tag(unit.id)
                }
            }
            .frame(minHeight: 160)
            .accessibilityIdentifier("units.list")
            HStack {
                Button("+", action: model.add).accessibilityIdentifier("units.add")
                Button("-", action: model.remove).disabled(model.selection == nil).accessibilityIdentifier("units.remove")
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier("units.done")
            }
        }
        .padding()
        .frame(width: 420)
    }
}

/// One custom unit: its name (the suffix), "= amount base".
struct UnitRow: View {
    let model: UnitsSheetModel
    let unit: CustomUnit

    static func rename(_ model: UnitsSheetModel, _ unit: CustomUnit) -> (String) -> Void {
        { model.rename(unit, to: $0) }
    }

    static func amount(_ model: UnitsSheetModel, _ unit: CustomUnit) -> (Double) -> Void {
        { model.redefine(unit, amount: $0) }
    }

    static func base(_ model: UnitsSheetModel, _ unit: CustomUnit) -> Binding<LengthUnit> {
        Binding(get: { unit.base }, set: { model.redefine(unit, base: $0) })
    }

    var body: some View {
        HStack {
            CommitTextField(title: "Name", value: unit.name, identifier: "units.name.\(unit.name)", commit: Self.rename(model, unit))
                .frame(width: 90)
            if model.isDuplicate(unit) { Image(systemName: "exclamationmark.triangle").help("Another unit has this name") }
            Text("=")
            CommitField(title: "Amount", value: unit.amount, identifier: "units.amount.\(unit.name)", commit: Self.amount(model, unit))
                .frame(width: 70)
            Picker("", selection: Self.base(model, unit)) {
                ForEach(UnitsSheetModel.bases, id: \.self) { Text($0.name).tag($0) }
            }
            .frame(width: 140)
        }
    }
}
