import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DOC-002: the Document panel's commands (document-panel.adoc, "Client"): geometry, bleed,
// printer resolution, units and custom page sizes, each one change with the panel's label.

/// Why a page setup command could not build its change.
public enum PageSetupError: Error, Equatable, Sendable {
    /// The node is not a live page (or master page).
    case notAPage(OpID)
    /// A child of a master page cannot be resized, re-oriented or given its own bleed.
    case childOfMaster(OpID)
    /// A value outside the stored range.
    case invalidValue(String)
    /// The custom size or unit is not in the document.
    case unknownElement(OpID)
    /// The last page cannot be removed.
    case lastPage
    /// A single-page document has exactly one page (typeface-documents.adoc, "Document kinds"):
    /// convert it to multi-page first.
    case singlePageDocument
}

/// Shared helpers of the page commands.
enum PageEditing {
    /// The page `id` names in `pages`, or throws.
    static func page(_ id: OpID, in pages: PageList) throws -> Page {
        guard let page = pages[id] else { throw PageSetupError.notAPage(id) }
        return page
    }

    /// Writes the synthesized page of a document with no live page (the zero-pages
    /// normalization: "the first command that touches pages writes it") and returns its id;
    /// returns `id` unchanged for a real page.
    static func materialize(_ id: OpID, in pages: PageList, builder: inout ChangeBuilder) throws -> OpID {
        guard id == PageList.synthesizedID, pages.isSynthesized else { return id }
        return try create(pages.pages[0], builder: &builder).id
    }

    /// Appends the `CreateNode` writing the synthesized `page`; returns its id and position key.
    static func create(_ page: Page, builder: inout ChangeBuilder) throws -> (id: OpID, position: [UInt8]) {
        let props = PageFields.values {
            $0.origin = point(page.origin)
            $0.geometry = page.geometry.stored
        }
        let position = try PathEditing.keys(between: nil, and: nil, count: 1)[0]
        return (builder.append(Ops.create(parent: WellKnown.pages, position: position, props: props)), position)
    }

    /// A position after the last element of `sequence` (tombstones included, so a restored
    /// element keeps its place).
    static func appendKey(_ node: OpID, _ sequence: RegisterPath, in state: EngineState) throws -> [[UInt8]] {
        let last = state.store.elementOrder(node, sequence).last.flatMap { state.position(node, sequence, $0) }
        return try PathEditing.keys(between: last, and: nil, count: 1)
    }

    static func point(_ point: Point) -> Wiretuner_Doc_V1_Point {
        var value = Wiretuner_Doc_V1_Point()
        value.x = point.x
        value.y = point.y
        return value
    }
}

/// *Page Size* pop-up, orientation buttons and the Page tool's resize: writes each page's
/// `geometry` (ATOMIC: width, height, orientation and preset together), "Change page size".
/// Pages that are children of a master are skipped (their geometry is the master's); a master
/// page given as a target is resized itself.
public struct SetPageGeometry: Command {
    public var pages: [OpID]
    public var geometry: PageGeometry
    public var label: String { "Change page size" }

    public init(_ pages: [OpID], to geometry: PageGeometry) {
        self.pages = pages
        self.geometry = geometry
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard geometry.isValid else { throw PageSetupError.invalidValue("geometry") }
        let list = PageList(state)
        for id in pages {
            if list.master(id) != nil {
                builder.append(Ops.set(id, [MasterPageFields.geometry], values: MasterPageFields.values { $0.geometry = geometry.stored }))
                continue
            }
            let page = try PageEditing.page(id, in: list)
            guard !page.isChild else { continue }
            let node = try PageEditing.materialize(page.id, in: list, builder: &builder)
            builder.append(Ops.set(node, [PageFields.geometry], values: PageFields.values { $0.geometry = geometry.stored }))
        }
    }
}

/// The orientation buttons: each page's geometry turned to `orientation` (width and height swap
/// around the top-left corner), "Change orientation".  Children of a master are skipped.
public struct SetPageOrientation: Command {
    public var pages: [OpID]
    public var orientation: PageGeometry.Orientation
    public var label: String { "Change orientation" }

    public init(_ pages: [OpID], to orientation: PageGeometry.Orientation) {
        self.pages = pages
        self.orientation = orientation
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = PageList(state)
        for id in pages {
            if let master = list.master(id) {
                guard master.geometry.orientation != orientation else { continue }
                try SetPageGeometry([id], to: master.geometry.oriented(orientation)).execute(&builder, state: state)
                continue
            }
            let page = try PageEditing.page(id, in: list)
            guard !page.isChild, page.geometry.orientation != orientation else { continue }
            try SetPageGeometry([id], to: page.geometry.oriented(orientation)).execute(&builder, state: state)
        }
    }
}

/// The *Bleed* field: each page's `bleed`, "Change bleed".  Children of a master are skipped.
public struct SetBleed: Command {
    public var pages: [OpID]
    public var bleed: Double
    public var label: String { "Change bleed" }

    public init(_ pages: [OpID], to bleed: Double) {
        self.pages = pages
        self.bleed = bleed
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard bleed.isFinite, bleed >= 0, bleed <= 720 else { throw PageSetupError.invalidValue("bleed") }
        let list = PageList(state)
        for id in pages {
            if list.master(id) != nil {
                builder.append(Ops.set(id, [MasterPageFields.bleed], values: MasterPageFields.values { $0.bleed = bleed }))
                continue
            }
            let page = try PageEditing.page(id, in: list)
            guard !page.isChild else { continue }
            let node = try PageEditing.materialize(id, in: list, builder: &builder)
            builder.append(Ops.set(node, [PageFields.bleed], values: PageFields.values { $0.bleed = bleed }))
        }
    }
}

/// The *Printer Resolution* pop-up and field: `SettingsProps.printer_resolution`, 72...9600 dpi,
/// "Change printer resolution".
public struct SetPrinterResolution: Command {
    public var dpi: Int
    public var label: String { "Change printer resolution" }

    public init(_ dpi: Int) {
        self.dpi = dpi
    }

    /// The pop-up's values.
    public static let presets = [72, 144, 300, 600, 1200, 2400, 3600]

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard (72...9600).contains(dpi) else { throw PageSetupError.invalidValue("printer resolution") }
        builder.append(Ops.set(WellKnown.settings, [SettingsFields.printerResolution], values: SettingsFields.values { $0.printerResolution = UInt32(dpi) }))
    }
}

/// The *Units* pop-up: `SettingsProps.units` (ATOMIC), "Change units".  Stored values are never
/// changed: everything is points.
public struct SetUnits: Command {
    public var unit: LengthUnit
    public var label: String { "Change units" }

    public init(_ unit: LengthUnit) {
        self.unit = unit
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if case .custom(let id) = unit, !state.liveElements(WellKnown.settings, SettingsFields.customUnits).contains(id) {
            throw PageSetupError.unknownElement(id)
        }
        builder.append(Ops.set(WellKnown.settings, [SettingsFields.units], values: SettingsFields.values { $0.units = unit.choice }))
    }
}

/// *Page Sizes* sheet btn:[New]: a custom size at the end of the list, "Add page size".
public struct AddCustomPageSize: Command {
    public var name: String
    /// Portrait width and height, points.
    public var size: Size
    public var label: String { "Add page size" }

    public init(name: String, size: Size) {
        self.name = name
        self.size = size
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard PageGeometry(width: size.width, height: size.height).isValid else { throw PageSetupError.invalidValue("size") }
        let keys = try PageEditing.appendKey(WellKnown.settings, SettingsFields.customPageSizes, in: state)
        var element = Wiretuner_Doc_V1_CustomPageSize()
        element.name = String(name.prefix(64))
        element.size.width = size.width
        element.size.height = size.height
        builder.append(Ops.elementInsert(WellKnown.settings, SettingsFields.customPageSizes, positions: keys,
                                         values: SettingsFields.values { $0.customPageSizes = [element] }))
    }
}

/// *Page Sizes* sheet inline editing: renames and/or resizes a custom size, "Change page size".
/// The name and size are separate registers, so a rename on one replica and a resize on another
/// both hold.  Pages and masters using the size (by its current name) follow it in the same
/// change: their geometry takes the new name and size in their own orientation.
public struct EditCustomPageSize: Command {
    public var id: OpID
    public var name: String?
    public var size: Size?
    public var label: String { "Change page size" }

    public init(_ id: OpID, name: String? = nil, size: Size? = nil) {
        self.id = id
        self.name = name
        self.size = size
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let settings = DocumentSettings(state)
        guard let current = settings.customPageSizes.first(where: { $0.id == id }) else { throw PageSetupError.unknownElement(id) }
        if let size, !PageGeometry(width: size.width, height: size.height).isValid { throw PageSetupError.invalidValue("size") }
        let sequence = SettingsFields.customPageSizes.element(id)
        var element = Wiretuner_Doc_V1_CustomPageSize()
        var paths: [RegisterPath] = []
        if let name, name != current.name {
            element.name = String(name.prefix(64))
            paths.append(sequence.child(2))
        }
        if let size, size != current.size {
            element.size.width = size.width
            element.size.height = size.height
            paths.append(sequence.child(3))
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: SettingsFields.values { $0.customPageSizes = [element] }))
        let newName = name.map { String($0.prefix(64)) } ?? current.name
        let newSize = size ?? current.size
        // Only the first size of a duplicated name is what pages using that name read.
        guard settings.customPageSize(named: current.name)?.id == id else { return }
        let list = PageList(state, settings: settings)
        for master in list.masters where master.geometry.preset == current.name {
            let geometry = PageGeometry(preset: newName, portrait: newSize, orientation: master.geometry.orientation)
            builder.append(Ops.set(master.id, [MasterPageFields.geometry], values: MasterPageFields.values { $0.geometry = geometry.stored }))
        }
        for page in list.pages where !page.isSynthesized && page.ownGeometry.preset == current.name {
            let geometry = PageGeometry(preset: newName, portrait: newSize, orientation: page.ownGeometry.orientation)
            builder.append(Ops.set(page.id, [PageFields.geometry], values: PageFields.values { $0.geometry = geometry.stored }))
        }
    }
}

/// *Page Sizes* sheet btn:[Delete]: an `ElementDelete`, "Remove page size".  Pages using the size
/// keep their dimensions and read as *Custom* (the dangling-preset normalization); nothing else
/// is written, so restoring the size brings their preset back.
public struct RemoveCustomPageSize: Command {
    public var id: OpID
    public var label: String { "Remove page size" }

    public init(_ id: OpID) {
        self.id = id
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.liveElements(WellKnown.settings, SettingsFields.customPageSizes).contains(id) else { throw PageSetupError.unknownElement(id) }
        builder.append(Ops.elementDelete(WellKnown.settings, [SettingsFields.customPageSizes.element(id)]))
    }
}

/// The Units sheet: adds a custom unit equal to `amount` of `base`, "Add unit".
public struct AddCustomUnit: Command {
    public var name: String
    public var amount: Double
    public var base: LengthUnit
    public var label: String { "Add unit" }

    public init(name: String, amount: Double, base: LengthUnit) {
        self.name = name
        self.amount = amount
        self.base = base
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard amount.isFinite, amount > 0 else { throw PageSetupError.invalidValue("amount") }
        if case .custom = base { throw PageSetupError.invalidValue("base") }
        let keys = try PageEditing.appendKey(WellKnown.settings, SettingsFields.customUnits, in: state)
        var element = Wiretuner_Doc_V1_CustomUnit()
        element.name = String(name.prefix(32))
        element.definition.amount = amount
        element.definition.base = base.stored
        builder.append(Ops.elementInsert(WellKnown.settings, SettingsFields.customUnits, positions: keys,
                                         values: SettingsFields.values { $0.customUnits = [element] }))
    }
}

/// The Units sheet: renames and/or redefines a custom unit (separate registers; the definition
/// ATOMIC), "Change unit".
public struct EditCustomUnit: Command {
    public var id: OpID
    public var name: String?
    public var definition: (amount: Double, base: LengthUnit)?
    public var label: String { "Change unit" }

    public init(_ id: OpID, name: String? = nil, amount: Double? = nil, base: LengthUnit? = nil) {
        self.id = id
        self.name = name
        if let amount, let base { definition = (amount, base) }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.liveElements(WellKnown.settings, SettingsFields.customUnits).contains(id) else { throw PageSetupError.unknownElement(id) }
        let element = SettingsFields.customUnits.element(id)
        var value = Wiretuner_Doc_V1_CustomUnit()
        var paths: [RegisterPath] = []
        if let name {
            value.name = String(name.prefix(32))
            paths.append(element.child(2))
        }
        if let definition {
            guard definition.amount.isFinite, definition.amount > 0 else { throw PageSetupError.invalidValue("amount") }
            if case .custom = definition.base { throw PageSetupError.invalidValue("base") }
            value.definition.amount = definition.amount
            value.definition.base = definition.base.stored
            paths.append(element.child(3))
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: SettingsFields.values { $0.customUnits = [value] }))
    }
}

/// The Units sheet's btn:[Delete], "Remove unit".  A document unit naming it reads as points.
public struct RemoveCustomUnit: Command {
    public var id: OpID
    public var label: String { "Remove unit" }

    public init(_ id: OpID) {
        self.id = id
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.liveElements(WellKnown.settings, SettingsFields.customUnits).contains(id) else { throw PageSetupError.unknownElement(id) }
        builder.append(Ops.elementDelete(WellKnown.settings, [SettingsFields.customUnits.element(id)]))
    }
}

/// The Grid sheet: `grid.size` and/or `grid.relative` (independent registers), "Change grid".
public struct SetGrid: Command {
    public var size: Double?
    public var relative: Bool?
    public var label: String { "Change grid" }

    public init(size: Double? = nil, relative: Bool? = nil) {
        self.size = size
        self.relative = relative
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let size, !(size > 0 && size <= 7200) { throw PageSetupError.invalidValue("grid size") }
        var paths: [RegisterPath] = []
        if size != nil { paths.append(SettingsFields.gridSize) }
        if relative != nil { paths.append(SettingsFields.gridRelative) }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: SettingsFields.values {
            $0.grid.size = size ?? 0
            $0.grid.relative = relative ?? false
        }))
    }
}

/// View > Guides > Lock: `guides_locked` (shared), "Lock guides" / "Unlock guides".
public struct SetGuidesLocked: Command {
    public var locked: Bool
    public var label: String { locked ? "Lock guides" : "Unlock guides" }

    public init(_ locked: Bool) {
        self.locked = locked
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        builder.append(Ops.set(WellKnown.settings, [SettingsFields.guidesLocked], values: SettingsFields.values { $0.guidesLocked = locked }))
    }
}

/// The zero-point drag and its reset: `ruler_origin` (ATOMIC; nil writes it unset, the
/// bottom-left default), "Move zero point" / "Reset zero point".
public struct SetRulerOrigin: Command {
    public var page: OpID
    /// Relative to the page's top-left corner, y down; nil resets.
    public var origin: Point?
    public var label: String { origin == nil ? "Reset zero point" : "Move zero point" }

    public init(_ page: OpID, to origin: Point?) {
        self.page = page
        self.origin = origin
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let origin, !origin.isFinite { throw PageSetupError.invalidValue("origin") }
        let list = PageList(state)
        _ = try PageEditing.page(page, in: list)
        let node = try PageEditing.materialize(page, in: list, builder: &builder)
        let values = origin.map { origin in PageFields.values { $0.rulerOrigin = PageEditing.point(origin) } } ?? Wiretuner_Doc_V1_NodeProps()
        builder.append(Ops.set(node, [PageFields.rulerOrigin], values: values))
    }
}
