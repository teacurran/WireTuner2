import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

/// The gallery's built-in starting points (templates.adoc, "Starting a document from a template";
/// DOC-029): *Blank*, *Print*, *Screen*, *Stationery*, *Publication* and *Technical*, each built
/// from the side panel's options.  A starting point is composed from the ordinary commands on a
/// scratch document (`state(for:)`) and written into the new document as its one creation change
/// by re-issuing that state with fresh ids (`CreateDocument(.startingPoint(_))`), exactly as a
/// template document is; *Blank* with its default options is the built-in template itself.
public enum StartingPoints {
    public enum Kind: String, CaseIterable, Hashable, Sendable, Identifiable {
        case blank, print, screen, stationery, publication, technical

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .blank: "Blank"
            case .print: "Print"
            case .screen: "Screen"
            case .stationery: "Stationery"
            case .publication: "Publication"
            case .technical: "Technical"
            }
        }

        /// The gallery's one-line description.
        public var summary: String {
            switch self {
            case .blank: "One Letter page"
            case .print: "A CMYK document with bleed and print marks"
            case .screen: "An RGB document in pixels with web-safe swatches"
            case .stationery: "Letterhead, envelope and business card pages with guides"
            case .publication: "Facing pages, a master page and folio text"
            case .technical: "Picas and inches, a fine grid and technical strokes"
            }
        }
    }

    /// The colour mode, which picks the default swatch set: the process swatches (White, Black,
    /// Registration) for CMYK, those and the 216 web-safe colours for RGB.  The model has no
    /// document colour mode of its own.
    public enum ColorMode: String, CaseIterable, Hashable, Sendable {
        case cmyk, rgb

        public var title: String { self == .cmyk ? "CMYK" : "RGB" }
    }

    /// The side panel's options.
    public struct Options: Hashable, Sendable {
        public var kind: Kind
        /// The page size, portrait (the first page's for *Stationery*); `preset` names it.
        public var size: Size
        public var preset: String
        public var orientation: PageGeometry.Orientation
        public var units: LengthUnit
        public var colorMode: ColorMode
        /// *Publication*'s page count.
        public var pageCount: Int

        public init(kind: Kind, size: Size, preset: String = "", orientation: PageGeometry.Orientation = .portrait, units: LengthUnit,
                    colorMode: ColorMode, pageCount: Int = 1) {
            self.kind = kind
            self.size = size
            self.preset = preset
            self.orientation = orientation
            self.units = units
            self.colorMode = colorMode
            self.pageCount = pageCount
        }

        /// The first page's geometry.
        public var geometry: PageGeometry { PageGeometry(preset: preset, portrait: size, orientation: orientation) }
    }

    /// The most pages a *Publication* starts with.
    public static let maximumPageCount = 999
    /// *Print*'s bleed, ⅛ in.
    public static let printBleed = 9.0
    /// *Screen*'s default size, 1920 × 1080 px (portrait-normalized: turned landscape).
    public static let screenSize = Size(width: 1080, height: 1920)
    /// *Stationery*'s other pages: a #10 envelope and a business card.
    public static let envelope = PageGeometry(preset: "#10 Envelope", width: 684, height: 297)
    public static let businessCard = PageGeometry(preset: "Business Card", width: 252, height: 144)
    /// *Technical*'s grid, 6 pt.
    public static let technicalGrid = 6.0
    /// *Technical*'s stroke weights: graphic styles named after them, and 0.5 pt as the default.
    public static let technicalWeights: [(name: String, width: Double)] = [
        ("Hairline 0.25 pt", 0.25), ("Fine 0.5 pt", 0.5), ("Medium 1 pt", 1), ("Heavy 2 pt", 2),
    ]
    /// The folio text on *Publication*'s master (the model has no page-number character yet).
    public static let folioText = "Folio"
    public static let masterName = "A-Master"

    /// A starting point's default options.
    public static func defaults(for kind: Kind) -> Options {
        let letter = Size(width: 612, height: 792)
        switch kind {
        case .blank: return Options(kind: kind, size: letter, preset: "Letter", units: .points, colorMode: .cmyk)
        case .print: return Options(kind: kind, size: letter, preset: "Letter", units: .inches, colorMode: .cmyk)
        case .screen: return Options(kind: kind, size: screenSize, preset: "", orientation: .landscape, units: .pixels, colorMode: .rgb)
        case .stationery: return Options(kind: kind, size: letter, preset: "Letter", units: .inches, colorMode: .cmyk)
        case .publication: return Options(kind: kind, size: letter, preset: "Letter", units: .picas, colorMode: .cmyk, pageCount: 8)
        case .technical: return Options(kind: kind, size: letter, preset: "Letter", units: .picas, colorMode: .cmyk)
        }
    }

    /// The creation change's label: "Created" for *Blank*, "Created from Print" and so on.
    public static func label(for options: Options) -> String {
        options.kind == .blank ? "Created" : "Created from \(options.kind.title)"
    }

    /// Whether `options` are *Blank*'s defaults, which the built-in template writes as it is.
    public static func isBuiltIn(_ options: Options) -> Bool {
        options == defaults(for: .blank)
    }

    public enum Failure: Error, Hashable {
        case invalidSize
        case invalidPageCount
    }

    /// The starting point's content on a scratch document of `replica`: the built-in template,
    /// then the kind's pages, units, swatches, guides, master, grid, print settings and styles.
    public static func state(for options: Options, replica: UInt64 = 1, now: Date = Date(timeIntervalSince1970: 0)) throws -> EngineState {
        let geometry = options.geometry
        guard geometry.isValid else { throw Failure.invalidSize }
        guard (1...maximumPageCount).contains(options.pageCount) else { throw Failure.invalidPageCount }
        var core = try DocumentCreation.newDocument(from: .builtIn, replica: replica, now: now)
        let recording = DocumentCore.Recording(limit: 1, now: now)
        func perform(_ command: any Command) throws { _ = try core.perform(command, recording: recording) }
        var pages: [OpID] { PageList(core.state).pages.map(\.id) }
        func pageSize(_ id: OpID) -> Size { PageList(core.state).pages.first { $0.id == id }?.geometry.size ?? Size(width: 612, height: 792) }

        try perform(SetPageGeometry(pages, to: geometry))
        try perform(SetUnits(options.units))
        if options.colorMode == .rgb { try perform(ImportLibraryColors(BundledColorLibraries.webSafe)) }
        switch options.kind {
        case .blank:
            break
        case .print:
            try perform(SetBleed(pages, to: printBleed))
            try perform(SetPrintSettings([.bleed(printBleed), .mark(.crop, true), .mark(.registration, true)], label: "Print marks"))
        case .screen:
            try perform(SetPrinterResolution(72))
        case .stationery:
            try perform(AddPages(count: 1, geometry: envelope))
            try perform(AddPages(count: 1, geometry: businessCard))
            for page in pages {
                let size = pageSize(page)
                let margin = size.height < 200 ? 9.0 : 36
                try perform(AddGuides(on: [page], axis: .vertical, at: [margin, size.width - margin]))
                try perform(AddGuides(on: [page], axis: .horizontal, at: [margin, size.height - margin]))
            }
        case .publication:
            if options.pageCount > 1 { try perform(AddPages(count: options.pageCount - 1, geometry: geometry)) }
            try layOutSpreads(&core, recording: recording)
            try perform(NewMasterPage(from: pages[0], name: masterName))
            guard let master = PageList(core.state).masters.first?.id else { break }
            try perform(ApplyMasterPage(master, to: pages))
            let size = geometry.size
            try perform(AddGuides(on: pages, axis: .vertical, at: [36, size.width - 36]))
            try perform(AddGuides(on: pages, axis: .horizontal, at: [36, size.height - 36]))
            try perform(FolioText(master: master, at: Point(x: 36, y: size.height - 30)))
        case .technical:
            try perform(SetGrid(size: technicalGrid))
            for weight in technicalWeights {
                try perform(SetDefaultsStyle(style: nil, appearance: appearance(width: weight.width)))
                try perform(CreateGraphicStyle(.defaults, name: weight.name))
            }
            try perform(SetDefaultsStyle(style: nil, appearance: appearance(width: 0.5)))
        }
        return core.state
    }

    /// A black basic stroke of `width`.
    static func appearance(width: Double) -> Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: width)]
        return appearance
    }

    /// Facing pages: page 1 alone on the right, then pairs side by side, each spread below the
    /// one before (the model has no spread setting; the pages' origins make the spreads).
    static func layOutSpreads(_ core: inout DocumentCore, recording: DocumentCore.Recording) throws {
        let list = PageList(core.state)
        guard let first = list.pages.first else { return }
        let size = first.geometry.size
        let gap = 72.0
        let rows = list.pages.count / 2 + 1
        let top = max(0, (DocumentCreation.pasteboardSide - Double(rows) * (size.height + gap)) / 2)
        let left = (DocumentCreation.pasteboardSide - 2 * size.width) / 2
        for page in list.pages {
            let index = page.number
            let row = Double(index / 2)
            let column = Double(index % 2 == 0 ? 0 : 1)
            let origin = Point(x: left + column * size.width, y: top + row * (size.height + gap))
            _ = try core.perform(MovePage(page.id, by: origin - page.origin, withContents: false), recording: recording)
        }
    }
}

/// *Publication*'s folio: a point text block on `master`'s canvas, in master coordinates.
struct FolioText: Command {
    var master: OpID
    var at: Point
    var label: String { "Folio" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let before = builder.ops.count
        try CreateTextBlock(.point(at), text: StartingPoints.folioText).execute(&builder, state: state)
        var counter = builder.startCounter
        for (index, op) in builder.ops.enumerated() {
            defer { counter &+= EngineState.counters(op) }
            guard index >= before, case .create(let create) = op.op, case .text? = create.props.kind else { continue }
            let node = OpID(counter: counter, replica: builder.replica)
            builder.append(Ops.set(node, [CommonFields.canvas(.text)], values: NodeValues.common(kind: .text) { $0.canvas.id = master.proto }))
            return
        }
    }
}
