import AppKit
import Observation
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTRender

// The page sheets (pages.adoc, "Adding pages", "Page order", "Modifying, resizing and rotating
// pages"; document-panel.adoc, the Page Size pop-up's *Edit…*; DOC-005, DOC-007, DOC-008): Add
// Pages, Move Page, Modify Page and Page Sizes.  Lengths are typed in the document's units; each
// button press is one change.

/// A page size as the sheets edit it: a preset (standard or custom) or Custom with a typed width
/// and height, and an orientation.
@MainActor
@Observable
final class PageSizeChoice {
    static let custom = "Custom"

    let settings: DocumentSettings
    let units: Units
    var preset: String
    var widthText: String
    var heightText: String
    var orientation: PageGeometry.Orientation

    init(_ geometry: PageGeometry, settings: DocumentSettings, units: Units) {
        self.settings = settings
        self.units = units
        preset = geometry.preset.isEmpty ? Self.custom : geometry.preset
        widthText = units.format(geometry.width)
        heightText = units.format(geometry.height)
        orientation = geometry.orientation
    }

    /// The pop-up's items: standard sizes, custom sizes, Custom.
    var items: [String] { settings.presetNames + [Self.custom] }

    var isCustom: Bool { preset == Self.custom }

    /// The geometry chosen; nil when a typed width or height is not a page size.
    var geometry: PageGeometry? {
        if !isCustom, let size = settings.portraitSize(of: preset) {
            return PageGeometry(preset: preset, portrait: size, orientation: orientation)
        }
        guard let width = units.parse(widthText), let height = units.parse(heightText) else { return nil }
        let geometry = PageGeometry(width: width, height: height, orientation: orientation)
        return geometry.isValid ? geometry : nil
    }
}

/// *Add Pages…* (pages.adoc, "Adding pages"): how many, size, orientation, bleed and, when the
/// document has master pages, *Make child of master page*; the pages go after the active page
/// ("Add N pages").
@MainActor
@Observable
final class AddPagesSheetModel {
    let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var countText = "1"
    let size: PageSizeChoice
    var bleedText: String
    var childOfMaster: Bool
    var master: OpID?
    private(set) var problem: String?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
        let page = document.activePage
        size = PageSizeChoice(page.ownGeometry, settings: document.settings, units: document.unitConverter)
        bleedText = document.unitConverter.format(page.ownBleed)
        childOfMaster = page.isChild
        master = page.master ?? document.pageList.masters.first?.id
    }

    static let invalid = "Type how many pages (1 to 1,000), a page size and a bleed"

    var masters: [MasterPage] { document.pageList.masters }

    /// The command btn:[Add] performs; nil when a field does not read.
    func command() -> AddPages? {
        guard let count = Int(countText.trimmingCharacters(in: .whitespaces)), (1...1000).contains(count),
              let geometry = size.geometry, let bleed = document.unitConverter.parse(bleedText), bleed >= 0, bleed <= 720 else { return nil }
        let anchor = document.activePage
        return AddPages(count: count, geometry: geometry, bleed: bleed, master: .some(childOfMaster ? master : nil),
                        after: anchor.isSynthesized ? nil : anchor.id)
    }

    /// btn:[Add]: whether the pages were added (the sheet closes).
    @discardableResult
    func add() -> Bool {
        guard let command = command() else {
            problem = Self.invalid
            return false
        }
        perform(command)
        return true
    }
}

/// *Move Page…* (pages.adoc, "Page order"): the active page to a page number ("Move page N").
@MainActor
@Observable
final class MovePageSheetModel {
    let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var numberText: String
    private(set) var problem: String?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
        numberText = "\(document.activePage.number)"
    }

    var pageCount: Int { document.pageList.pages.count }

    @discardableResult
    func move() -> Bool {
        guard let number = Int(numberText.trimmingCharacters(in: .whitespaces)), (1...pageCount).contains(number) else {
            problem = "Type a page number from 1 to \(pageCount)"
            return false
        }
        let page = document.activePage
        if number != page.number { perform(ReorderPage(page.id, to: number)) }
        return true
    }
}

/// *Modify Page* (the Page tool's kbd:[Option]-double-click): size, orientation, bleed and master
/// of one page, written together ("Modify page"); a child's size and bleed are its master's and
/// are shown disabled.
@MainActor
@Observable
final class ModifyPageSheetModel {
    let document: DocumentHandle
    let page: OpID
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    let size: PageSizeChoice
    var bleedText: String
    var master: OpID?
    private(set) var problem: String?

    init(document: DocumentHandle, page: OpID, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.page = page
        self.perform = perform
        let read = document.pageList[page] ?? document.activePage
        size = PageSizeChoice(read.geometry, settings: document.settings, units: document.unitConverter)
        bleedText = document.unitConverter.format(read.bleed)
        master = read.master
    }

    var masters: [MasterPage] { document.pageList.masters }
    /// Whether the size and bleed are the master's (a child, and still one in the sheet).
    var followsMaster: Bool { master != nil }

    static let invalid = "Type a page size and a bleed"

    /// The command btn:[OK] performs: only what changed; nil when nothing did or a field does not
    /// read (`problem` says which).
    func command() -> ModifyPage? {
        guard let current = document.pageList[page] else { return nil }
        var geometry: PageGeometry?
        var bleed: Double?
        if !followsMaster {
            guard let chosen = size.geometry, let typed = document.unitConverter.parse(bleedText), typed >= 0, typed <= 720 else {
                problem = Self.invalid
                return nil
            }
            if chosen != current.ownGeometry { geometry = chosen }
            if abs(typed - current.ownBleed) > 1e-9 { bleed = typed }
        }
        let masterChange: OpID?? = master == current.master ? nil : .some(master)
        guard geometry != nil || bleed != nil || masterChange != nil else { return nil }
        return ModifyPage(page, geometry: geometry, bleed: bleed, master: masterChange)
    }

    @discardableResult
    func ok() -> Bool {
        problem = nil
        let command = command()
        guard problem == nil else { return false }
        if let command { perform(command) }
        return true
    }
}

/// The *Page Sizes* sheet (DOC-005): the document's custom sizes with name, width and height in
/// its units; btn:[New] adds one, btn:[Delete] removes the selected one (pages using it read
/// Custom, keeping their size), and each inline edit is one change -- pages using a size follow
/// its new name and dimensions.
@MainActor
@Observable
final class PageSizesSheetModel {
    let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Void
    var selection: OpID?

    init(document: DocumentHandle, perform: @escaping @MainActor (any WTModel.Command) -> Void) {
        self.document = document
        self.perform = perform
    }

    var sizes: [CustomPageSize] { document.settings.customPageSizes }
    var units: Units { document.unitConverter }

    /// btn:[New]: "Size N" at the active page's size, portrait.
    func add() {
        let taken = Set(sizes.map(\.name))
        let name = (1...).lazy.map { "Size \($0)" }.first { !taken.contains($0) }!
        let geometry = document.activePage.geometry
        perform(AddCustomPageSize(name: name, size: Size(width: min(geometry.width, geometry.height), height: max(geometry.width, geometry.height))))
    }

    func rename(_ size: CustomPageSize, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != size.name else { return }
        perform(EditCustomPageSize(size.id, name: trimmed))
    }

    /// A width or height typed (points): the size, portrait.
    func resize(_ size: CustomPageSize, width: Double? = nil, height: Double? = nil) {
        let w = width ?? size.size.width
        let h = height ?? size.size.height
        guard PageGeometry(width: w, height: h).isValid, w != size.size.width || h != size.size.height else { return }
        perform(EditCustomPageSize(size.id, size: Size(width: w, height: h)))
    }

    func delete() {
        guard let id = selection, sizes.contains(where: { $0.id == id }) else { return }
        perform(RemoveCustomPageSize(id))
        selection = nil
    }
}

// MARK: Views

struct PageSizeFields: View {
    @Bindable var size: PageSizeChoice
    var disabled = false

    var body: some View {
        Picker("Page Size", selection: $size.preset) {
            ForEach(size.items, id: \.self) { Text($0).tag($0) }
        }
        .disabled(disabled)
        .accessibilityIdentifier("pageSheet.size")
        if size.isCustom {
            TextField("Width", text: $size.widthText).disabled(disabled).accessibilityIdentifier("pageSheet.width")
            TextField("Height", text: $size.heightText).disabled(disabled).accessibilityIdentifier("pageSheet.height")
        }
        Picker("Orientation", selection: $size.orientation) {
            Text("Portrait").tag(PageGeometry.Orientation.portrait)
            Text("Landscape").tag(PageGeometry.Orientation.landscape)
        }
        .pickerStyle(.segmented)
        .disabled(disabled)
        .accessibilityIdentifier("pageSheet.orientation")
    }
}

struct AddPagesSheet: View {
    @Bindable var model: AddPagesSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Pages").font(.headline)
            Form {
                TextField("Number of pages", text: $model.countText).accessibilityIdentifier("addPages.count")
                PageSizeFields(size: model.size)
                TextField("Bleed", text: $model.bleedText).accessibilityIdentifier("addPages.bleed")
                if !model.masters.isEmpty {
                    Toggle("Make child of master page", isOn: $model.childOfMaster).accessibilityIdentifier("addPages.child")
                    Picker("Master", selection: $model.master) {
                        ForEach(model.masters) { Text($0.name).tag(OpID?.some($0.id)) }
                    }
                    .disabled(!model.childOfMaster)
                    .accessibilityIdentifier("addPages.master")
                }
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: SheetButtons.closing(model.add, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("addPages.add")
            }
        }
        .padding()
        .frame(width: 340)
    }
}

struct MovePageSheet: View {
    @Bindable var model: MovePageSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move Page").font(.headline)
            TextField("New page number (1–\(model.pageCount))", text: $model.numberText).accessibilityIdentifier("movePage.number")
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Move", action: SheetButtons.closing(model.move, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("movePage.move")
            }
        }
        .padding()
        .frame(width: 280)
    }
}

struct ModifyPageSheet: View {
    @Bindable var model: ModifyPageSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Modify Page").font(.headline)
            Form {
                PageSizeFields(size: model.size, disabled: model.followsMaster)
                TextField("Bleed", text: $model.bleedText).disabled(model.followsMaster).accessibilityIdentifier("modifyPage.bleed")
                if !model.masters.isEmpty {
                    Picker("Make child of master page", selection: $model.master) {
                        Text("None").tag(OpID?.none)
                        ForEach(model.masters) { Text($0.name).tag(OpID?.some($0.id)) }
                    }
                    .accessibilityIdentifier("modifyPage.master")
                }
            }
            if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK", action: SheetButtons.closing(model.ok, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("modifyPage.ok")
            }
        }
        .padding()
        .frame(width: 340)
    }
}

struct PageSizesSheet: View {
    @Bindable var model: PageSizesSheetModel
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Page Sizes").font(.headline)
            List(selection: $model.selection) {
                ForEach(model.sizes) { size in PageSizeRow(model: model, size: size).tag(size.id) }
            }
            .frame(minHeight: 140)
            .accessibilityIdentifier("pageSizes.list")
            HStack {
                Button("New", action: model.add).accessibilityIdentifier("pageSizes.new")
                Button("Delete", action: model.delete).disabled(model.selection == nil).accessibilityIdentifier("pageSizes.delete")
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction).accessibilityIdentifier("pageSizes.done")
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct PageSizeRow: View {
    let model: PageSizesSheetModel
    let size: CustomPageSize

    static func rename(_ model: PageSizesSheetModel, _ size: CustomPageSize) -> (String) -> Void {
        { model.rename(size, to: $0) }
    }

    static func width(_ model: PageSizesSheetModel, _ size: CustomPageSize) -> (Double) -> Void {
        { model.resize(size, width: $0) }
    }

    static func height(_ model: PageSizesSheetModel, _ size: CustomPageSize) -> (Double) -> Void {
        { model.resize(size, height: $0) }
    }

    var body: some View {
        HStack {
            CommitTextField(title: "Name", value: size.name, identifier: "pageSizes.name.\(size.name)", commit: Self.rename(model, size))
            MeasureField(title: "Width", value: size.size.width, units: model.units, identifier: "pageSizes.width", commit: Self.width(model, size))
                .frame(width: 70)
            Text("×")
            MeasureField(title: "Height", value: size.size.height, units: model.units, identifier: "pageSizes.height", commit: Self.height(model, size))
                .frame(width: 70)
        }
    }
}

/// The sheets' buttons that close them when their action went through.
@MainActor
enum SheetButtons {
    static func closing(_ action: @escaping @MainActor () -> Bool, _ close: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        { if action() { close() } }
    }
}

extension DocumentWindowController {
    /// The Options menu's *Add Pages…*.
    @discardableResult
    func presentAddPagesSheet() -> NSWindow? {
        let model = AddPagesSheetModel(document: documentHandle, perform: sheetPerform)
        return presentSheet("sheet.addPages") { close in AddPagesSheet(model: model, close: close) }
    }

    /// The Options menu's *Move Page…*.
    @discardableResult
    func presentMovePageSheet() -> NSWindow? {
        let model = MovePageSheetModel(document: documentHandle, perform: sheetPerform)
        return presentSheet("sheet.movePage") { close in MovePageSheet(model: model, close: close) }
    }

    /// The Page tool's kbd:[Option]-double-click.
    @discardableResult
    func presentModifyPageSheet(page: OpID) -> NSWindow? {
        let model = ModifyPageSheetModel(document: documentHandle, page: page, perform: sheetPerform)
        return presentSheet("sheet.modifyPage") { close in ModifyPageSheet(model: model, close: close) }
    }

    /// The Page Size pop-up's *Edit…*.
    @discardableResult
    func presentPageSizesSheet() -> NSWindow? {
        let model = PageSizesSheetModel(document: documentHandle, perform: sheetPerform)
        return presentSheet("sheet.pageSizes") { close in PageSizesSheet(model: model, close: close) }
    }
}
