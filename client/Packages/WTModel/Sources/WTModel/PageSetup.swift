import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DOC-002: typed views over the document setup nodes (document-panel.adoc, "Data model",
// "Read-time normalizations"; pages.adoc; master-pages.adoc, "Effective page geometry").

extension WellKnown {
    /// The master pages collection (0:3): children are `master_page` nodes.
    public static let masters = OpID.wellKnown(3)
}

/// Register paths of `PageProps` (`NodeProps.page` = 3).
public enum PageFields {
    public static let kind: UInt32 = 3
    public static let name = RegisterPath([3, 1, 1])
    public static let origin = RegisterPath([3, 2])
    public static let geometry = RegisterPath([3, 3])
    public static let bleed = RegisterPath([3, 4])
    public static let master = RegisterPath([3, 5])
    public static let rulerOrigin = RegisterPath([3, 6])
    public static let guides = RegisterPath([3, 7])

    /// A sparse `NodeProps` holding the page values `build` sets.
    public static func values(_ build: (inout Wiretuner_Doc_V1_PageProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.page)
        return props
    }
}

/// Register paths of `MasterPageProps` (`NodeProps.master_page` = 4).
public enum MasterPageFields {
    public static let kind: UInt32 = 4
    public static let name = RegisterPath([4, 1, 1])
    public static let geometry = RegisterPath([4, 2])
    public static let bleed = RegisterPath([4, 3])
    public static let guides = RegisterPath([4, 4])

    public static func values(_ build: (inout Wiretuner_Doc_V1_MasterPageProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.masterPage)
        return props
    }
}

/// Register paths of the document setup fields of `SettingsProps` (`NodeProps.settings` = 2).
public enum SettingsFields {
    public static let kind: UInt32 = 2
    public static let units = RegisterPath([2, 2])
    public static let printerResolution = RegisterPath([2, 3])
    public static let gridSize = RegisterPath([2, 4, 1])
    public static let gridRelative = RegisterPath([2, 4, 2])
    public static let customPageSizes = RegisterPath([2, 5])
    public static let customUnits = RegisterPath([2, 6])
    public static let guidesLocked = RegisterPath([2, 7])

    public static func values(_ build: (inout Wiretuner_Doc_V1_SettingsProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.settings)
        return props
    }
}

/// A standard page size, portrait (document-panel.adoc, "Page Size pop-up").
public struct PagePreset: Hashable, Sendable {
    public var name: String
    public var width: Double
    public var height: Double

    public init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    static func mm(_ name: String, _ width: Double, _ height: Double) -> PagePreset {
        PagePreset(name: name, width: width * 72 / 25.4, height: height * 72 / 25.4)
    }

    /// Letter, Legal, Tabloid, A3, A4, A5, B4, B5 (ISO B), in the pop-up's order.
    public static let standard: [PagePreset] = [
        PagePreset(name: "Letter", width: 612, height: 792),
        PagePreset(name: "Legal", width: 612, height: 1008),
        PagePreset(name: "Tabloid", width: 792, height: 1224),
        mm("A3", 297, 420), mm("A4", 210, 297), mm("A5", 148, 210), mm("B4", 250, 353), mm("B5", 176, 250),
    ]

    /// The standard size named `name`.
    public static func named(_ name: String) -> PagePreset? {
        standard.first { $0.name == name }
    }
}

/// A page's size: width and height as oriented, the orientation and the preset they came from
/// (`PageGeometry`, ATOMIC: one choice).
public struct PageGeometry: Hashable, Sendable {
    public enum Orientation: Hashable, Sendable {
        case portrait, landscape
    }

    /// Largest width or height, 222 inches.
    public static let maximumSide = 15_984.0

    /// A standard size's name, a custom size's name, or "" for Custom.
    public var preset: String
    public var width: Double
    public var height: Double
    public var orientation: Orientation

    /// A geometry of `width` × `height`; the orientation reads from the dimensions when nil.
    public init(preset: String = "", width: Double, height: Double, orientation: Orientation? = nil) {
        self.preset = preset
        self.width = width
        self.height = height
        self.orientation = orientation ?? (height >= width ? .portrait : .landscape)
    }

    /// A named size (standard or custom, portrait `size`) turned to `orientation`.
    public init(preset: String, portrait size: Size, orientation: Orientation = .portrait) {
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        self.init(preset: preset, width: orientation == .portrait ? short : long, height: orientation == .portrait ? long : short,
                  orientation: orientation)
    }

    /// A standard size turned to `orientation`.
    public init(_ preset: PagePreset, orientation: Orientation = .portrait) {
        self.init(preset: preset.name, portrait: Size(width: preset.width, height: preset.height), orientation: orientation)
    }

    /// US Letter, portrait: the page a document with none reads as.
    public static let letter = PageGeometry(PagePreset.standard[0])

    /// The stored geometry as read: an unspecified orientation reads from the dimensions.
    public init(_ stored: Wiretuner_Doc_V1_PageGeometry) {
        let orientation: Orientation?
        switch stored.orientation {
        case .portrait: orientation = .portrait
        case .landscape: orientation = .landscape
        default: orientation = nil
        }
        self.init(preset: stored.preset, width: stored.width, height: stored.height, orientation: orientation)
    }

    public var stored: Wiretuner_Doc_V1_PageGeometry {
        var geometry = Wiretuner_Doc_V1_PageGeometry()
        geometry.preset = String(preset.prefix(64))
        geometry.width = width
        geometry.height = height
        geometry.orientation = orientation == .portrait ? .portrait : .landscape
        return geometry
    }

    public var size: Size { Size(width: width, height: height) }

    /// The same page turned to `orientation`: width and height swap when it changes (around the
    /// top-left corner; objects do not move).
    public func oriented(_ orientation: Orientation) -> PageGeometry {
        guard orientation != self.orientation else { return self }
        return PageGeometry(preset: preset, width: height, height: width, orientation: orientation)
    }

    /// Whether both sides are in the stored range (0, 222 in].
    public var isValid: Bool {
        width > 0 && height > 0 && width <= Self.maximumSide && height <= Self.maximumSide
    }
}

/// A ruler guide as read: coincident guides (same axis and position) on one page read as one,
/// holding every element id (grid-guides.adoc, "Read-time normalizations").
public struct PageGuide: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        /// A horizontal line; `position` is a y offset.
        case horizontal
        /// A vertical line; `position` is an x offset.
        case vertical
    }

    /// Every element of the coincident guides this row stands for, smallest first.
    public var ids: [OpID]
    public var axis: Axis
    /// Points from the page's top-left corner along the axis.
    public var position: Double

    public init(ids: [OpID], axis: Axis, position: Double) {
        self.ids = ids
        self.axis = axis
        self.position = position
    }

    /// The first element id (the row's identity).
    public var id: OpID { ids[0] }

    /// Reads a `guides` sequence: unspecified axis → horizontal; coincident guides merged.
    static func read(_ guides: [Wiretuner_Doc_V1_Guide]) -> [PageGuide] {
        var result: [PageGuide] = []
        for guide in guides {
            guard let id = OpID(element: guide.id), guide.position.isFinite else { continue }
            let axis: Axis = guide.axis == .vertical ? .vertical : .horizontal
            if let index = result.firstIndex(where: { $0.axis == axis && abs($0.position - guide.position) < 1e-9 }) {
                result[index].ids = (result[index].ids + [id]).sorted()
            } else {
                result.append(PageGuide(ids: [id], axis: axis, position: guide.position))
            }
        }
        return result
    }

    /// The guide in pasteboard space on a page whose top-left corner is `origin`.
    public func snapGuide(origin: Point) -> SnapGuide {
        axis == .horizontal ? .horizontal(y: origin.y + position) : .vertical(x: origin.x + position)
    }
}

/// A master page as read (master-pages.adoc).
public struct MasterPage: Identifiable, Hashable, Sendable {
    public var id: OpID
    public var name: String
    public var geometry: PageGeometry
    public var bleed: Double
    public var guides: [PageGuide]

    public var rect: Rect { Rect(x: 0, y: 0, width: geometry.width, height: geometry.height) }
}

/// A page as read, with the read-time rules applied (document-panel.adoc; master-pages.adoc).
public struct Page: Identifiable, Hashable, Sendable {
    /// The page node; `WellKnown.pages` for the page a document without pages reads as.
    public var id: OpID
    /// 1-based index among the live pages in sibling order.
    public var number: Int
    public var name: String
    /// Top-left corner on the pasteboard.
    public var origin: Point
    /// The effective geometry: the master's while `master` resolves, else the page's own.
    public var geometry: PageGeometry
    /// The effective bleed.
    public var bleed: Double
    /// The page's own registers (masked while it is a child of a master).
    public var ownGeometry: PageGeometry
    public var ownBleed: Double
    /// The master, when `master` names a live master page.
    public var master: OpID?
    /// The rulers' zero point relative to the top-left corner; unset reads `(0, height)`.
    public var rulerOrigin: Point
    /// The page's own guides.
    public var guides: [PageGuide]
    /// True for the Letter page a document with no live page reads as; not written until a
    /// command touches pages.
    public var isSynthesized: Bool

    /// The page rectangle on the pasteboard.
    public var rect: Rect { Rect(x: origin.x, y: origin.y, width: geometry.width, height: geometry.height) }
    /// The page rectangle grown by `bleed` on every side.
    public var bleedRect: Rect { rect.insetBy(dx: -bleed, dy: -bleed) }
    /// A child of a master: its geometry and bleed are the master's.
    public var isChild: Bool { master != nil }
    /// The zero point on the pasteboard.
    public var zeroPoint: Point { Point(x: origin.x + rulerOrigin.x, y: origin.y + rulerOrigin.y) }
}

/// A named page size (the *Page Sizes* sheet).
public struct CustomPageSize: Identifiable, Hashable, Sendable {
    public var id: OpID
    public var name: String
    /// Portrait width and height in points.
    public var size: Size
}

/// The grid settings with the default resolved.
public struct GridSettings: Hashable, Sendable {
    /// Points between grid lines when the document never set one: one pica.
    public static let defaultSize = 12.0

    public var size: Double
    public var relative: Bool

    public init(size: Double = GridSettings.defaultSize, relative: Bool = false) {
        self.size = size
        self.relative = relative
    }
}

/// The document setup fields of the settings node as read (document-panel.adoc, "Read-time
/// normalizations"): a unit naming a deleted custom unit reads as points, a resolution of 0 as
/// 300 dpi, a grid size of 0 as the default.
public struct DocumentSettings: Hashable, Sendable {
    /// Printer resolution a document that never set one reads as.
    public static let defaultPrinterResolution = 300

    public var units: LengthUnit
    public var printerResolution: Int
    public var grid: GridSettings
    public var customPageSizes: [CustomPageSize]
    public var customUnits: [CustomUnit]
    public var guidesLocked: Bool

    public init(_ state: EngineState) {
        self.init(state.props(WellKnown.settings).settings)
    }

    public init(_ stored: Wiretuner_Doc_V1_SettingsProps) {
        let customUnits = stored.customUnits.compactMap { unit in
            OpID(element: unit.id).map {
                CustomUnit(id: $0, name: unit.name, amount: unit.definition.amount, base: LengthUnit(builtIn: unit.definition.base))
            }
        }
        self.customUnits = customUnits
        customPageSizes = stored.customPageSizes.compactMap { size in
            OpID(element: size.id).map { CustomPageSize(id: $0, name: size.name, size: Size(width: size.size.width, height: size.size.height)) }
        }
        if stored.units.unit == .custom {
            let id = OpID(element: stored.units.custom)
            units = id.flatMap { id in customUnits.contains { $0.id == id } ? .custom(id) : nil } ?? .points
        } else {
            units = LengthUnit(builtIn: stored.units.unit)
        }
        printerResolution = stored.printerResolution == 0 ? Self.defaultPrinterResolution : Int(stored.printerResolution)
        grid = GridSettings(size: stored.grid.size > 0 && stored.grid.size.isFinite ? stored.grid.size : GridSettings.defaultSize,
                            relative: stored.grid.relative)
        guidesLocked = stored.guidesLocked
    }

    /// The custom size named `name` (the first, in sequence order, of duplicates).
    public func customPageSize(named name: String) -> CustomPageSize? {
        customPageSizes.first { $0.name == name && !name.isEmpty }
    }

    /// Whether a stored `preset` still names a size: a standard one or a live custom one.
    public func isKnownPreset(_ preset: String) -> Bool {
        PagePreset.named(preset) != nil || customPageSize(named: preset) != nil
    }

    /// `geometry` with a preset naming no size read as "" (Custom).
    public func normalized(_ geometry: PageGeometry) -> PageGeometry {
        guard !geometry.preset.isEmpty, !isKnownPreset(geometry.preset) else { return geometry }
        var result = geometry
        result.preset = ""
        return result
    }

    /// The Page Size pop-up's items: the standard sizes, then the custom sizes in order.
    public var presetNames: [String] {
        PagePreset.standard.map(\.name) + customPageSizes.map(\.name)
    }

    /// The portrait size a preset names.
    public func portraitSize(of preset: String) -> Size? {
        if let standard = PagePreset.named(preset) { return Size(width: standard.width, height: standard.height) }
        return customPageSize(named: preset)?.size
    }

    /// Field entry and display in these settings' units.
    public var unitConverter: Units { Units(self) }
}

/// The document's pages and master pages as read (DOC-002): pages in page order with their
/// numbers and effective geometry, the zero-pages normalization, and the page queries.
public struct PageList: Hashable, Sendable {
    /// The id the synthesized page of a document without pages carries.
    public static let synthesizedID = WellKnown.pages

    /// The live pages in page order; never empty.
    public let pages: [Page]
    /// The live master pages in sibling order.
    public let masters: [MasterPage]
    public let settings: DocumentSettings

    public init(_ state: EngineState) {
        self.init(state, settings: DocumentSettings(state))
    }

    public init(_ state: EngineState, settings: DocumentSettings) {
        self.settings = settings
        var masters: [MasterPage] = []
        for node in state.liveChildren(WellKnown.masters) where state.store.kind(node) == MasterPageFields.kind {
            let props = state.props(node).masterPage
            masters.append(MasterPage(id: node, name: props.common.name, geometry: Self.read(props.geometry, settings: settings),
                                      bleed: Self.bleed(props.bleed), guides: PageGuide.read(props.guides)))
        }
        self.masters = masters
        var pages: [Page] = []
        for node in state.liveChildren(WellKnown.pages) where state.store.kind(node) == PageFields.kind {
            let props = state.props(node).page
            let own = Self.read(props.geometry, settings: settings)
            let ownBleed = Self.bleed(props.bleed)
            let masterID = props.hasMaster ? OpID(props.master.id) : nil
            let master = masterID.flatMap { id in masters.first { $0.id == id } }
            let geometry = master?.geometry ?? own
            let rulerOrigin = props.hasRulerOrigin && props.rulerOrigin.x.isFinite && props.rulerOrigin.y.isFinite
                ? Point(x: props.rulerOrigin.x, y: props.rulerOrigin.y) : Point(x: 0, y: geometry.height)
            let origin = props.origin.x.isFinite && props.origin.y.isFinite ? Point(x: props.origin.x, y: props.origin.y) : .zero
            pages.append(Page(id: node, number: pages.count + 1, name: props.common.name, origin: origin, geometry: geometry,
                              bleed: master?.bleed ?? ownBleed, ownGeometry: own, ownBleed: ownBleed, master: master?.id,
                              rulerOrigin: rulerOrigin, guides: PageGuide.read(props.guides), isSynthesized: false))
        }
        if pages.isEmpty {
            let letter = PageGeometry.letter
            pages = [Page(id: Self.synthesizedID, number: 1, name: "", origin: .zero, geometry: letter, bleed: 0, ownGeometry: letter,
                          ownBleed: 0, master: nil, rulerOrigin: Point(x: 0, y: letter.height), guides: [], isSynthesized: true)]
        }
        self.pages = pages
    }

    /// A stored geometry as read: the preset normalized, a missing or out-of-range size read as
    /// Letter's (a page is never degenerate).
    static func read(_ stored: Wiretuner_Doc_V1_PageGeometry, settings: DocumentSettings) -> PageGeometry {
        let geometry = PageGeometry(stored)
        guard geometry.isValid else {
            var letter = PageGeometry.letter
            letter.preset = ""
            return letter
        }
        return settings.normalized(geometry)
    }

    static func bleed(_ stored: Double) -> Double {
        stored.isFinite ? min(max(stored, 0), 720) : 0
    }

    /// Whether the document has no live page and reads as the synthesized Letter page.
    public var isSynthesized: Bool { pages.count == 1 && pages[0].isSynthesized }

    public subscript(id: OpID) -> Page? {
        pages.first { $0.id == id }
    }

    /// The master page `id` names, if live.
    public func master(_ id: OpID) -> MasterPage? {
        masters.first { $0.id == id }
    }

    /// The 1-based page number of `id`.
    public func number(of id: OpID) -> Int? {
        self[id]?.number
    }

    /// The page with page number `number`.
    public func page(number: Int) -> Page? {
        pages.indices.contains(number - 1) ? pages[number - 1] : nil
    }

    /// The page whose bleed rectangle contains `point`: the lowest-numbered of overlapping pages;
    /// nil on the pasteboard.
    public func page(containing point: Point) -> Page? {
        pages.first { $0.bleedRect.contains(point) }
    }

    /// The page an object with `bounds` (pasteboard) belongs to: the one whose bleed rectangle
    /// contains the centre of its bounds (document-panel.adoc, "Derived, never stored").
    public func page(ofBounds bounds: Rect) -> Page? {
        page(containing: bounds.center)
    }

    /// The pages whose rectangle `rect` intersects, in page order.
    public func pages(intersecting rect: Rect) -> [Page] {
        pages.filter { $0.rect.intersects(rect) }
    }

    /// The union of every page rectangle (Fit All).
    public var bounds: Rect {
        pages.dropFirst().reduce(pages[0].rect) { $0.union($1.rect) }
    }

    /// The guides that show on `page`: its own and, for a child, its master's (master-pages.adoc).
    public func guides(on page: Page) -> [PageGuide] {
        guard let master = page.master.flatMap(master) else { return page.guides }
        return page.guides + master.guides
    }

    /// Every page's guides as snap targets in pasteboard space (grid-guides.adoc, "Client").
    public var snapGuides: [SnapGuide] {
        var seen: Set<SnapGuide> = []
        return pages.flatMap { page in guides(on: page).map { $0.snapGuide(origin: page.origin) } }.filter { seen.insert($0).inserted }
    }

    /// The pages as WTRender draws them (DOC-009): `active` emphasized, each page's presence
    /// colours from `presence` (collaborators whose active page it is).
    public func frames(active: OpID? = nil, presence: [OpID: [Color]] = [:]) -> [PageFrame] {
        pages.map { page in
            PageFrame(rect: page.rect, bleed: page.bleed, isActive: page.id == active, presence: presence[page.id] ?? [])
        }
    }

    /// The pages as `ExportSnapshot` takes them.
    public var exportPages: [ExportSnapshot.Page] {
        pages.map { ExportSnapshot.Page(bounds: $0.rect, name: $0.name.isEmpty ? nil : $0.name, bleed: $0.bleed) }
    }

    /// The grid as WTRender draws and snaps to it: the document's grid size from the zero point
    /// of `page` (the first page by default).
    public func grid(on page: Page? = nil) -> GridSpec {
        GridSpec(size: settings.grid.size, origin: (page ?? pages[0]).zeroPoint, relative: settings.grid.relative)
    }
}
