import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

/// What a print job takes from the document (printing.adoc, "Client"; print-performance.adoc: "A
/// print job reads an immutable snapshot of the model"): the pages -- or the output area -- as
/// `ExportSnapshot` captures them, each page's list holding everything that reaches into its
/// bleed, with the print settings read into WTInterchange's `PrintOptions`, the ink list, every
/// object's own screen, every path's own flatness and each page's ruler zero point.  The result is
/// a `PrintRequest` the print plan plans off the main actor; remote changes applied afterwards
/// reach the live model only.
public enum PrintSnapshot {
    /// What the job prints from (a job parameter, never document state).
    public enum Source: Hashable, Sendable {
        case pages
        /// The output area (`OutputArea.read`), in pasteboard coordinates.
        case outputArea(Rect)
    }

    /// The job parameters.
    public struct Request: Sendable {
        public var name: String
        public var source: Source
        /// The queue's paper (`NSPrintInfo`, flipped to y down by the app).
        public var paper: PrintPaper
        /// The dialog's page range; nil prints every page.
        public var pageRange: ClosedRange<Int>?
        /// *Selected objects only*: the selection when the dialog opened; nil prints everything.
        public var selection: Set<NodeID>?
        public var date: Date
        public var timeZone: TimeZone

        public init(name: String, source: Source = .pages, paper: PrintPaper = .letter, pageRange: ClosedRange<Int>? = nil, selection: Set<NodeID>? = nil,
                    date: Date = Date(), timeZone: TimeZone = .current) {
            self.name = name
            self.source = source
            self.paper = paper
            self.pageRange = pageRange
            self.selection = selection
            self.date = date
            self.timeZone = timeZone
        }
    }

    /// The job for `request`, drawn with `builder` (its text layout set as the window's) and the
    /// blobs `blob` answers.
    public static func capture(_ state: EngineState, request: Request, builder: DocumentDisplayListBuilder,
                               blob: @escaping (Data) -> Data? = { _ in nil }) -> PrintRequest {
        let settings = DocumentPrintSettings(state)
        let pageList = PageList(state)
        let bleed = settings.bleed
        let scope: ExportSnapshot.Scope
        let source: PrintRequest.Source
        let bounds: [Rect]
        switch request.source {
        case .pages:
            scope = .pages(Array(pageList.pages.indices))
            source = .pages
            bounds = pageList.pages.map(\.rect)
        case .outputArea(let area):
            scope = .area(area.expanded(by: bleed))
            source = .outputArea(pageOutlines: pageList.pages(intersecting: area).map(\.rect))
            bounds = [area]
        }
        // Captured with the bleed so artwork reaching only into it prints, then set back to the page.
        let captured = pageList.exportPages.map { ExportSnapshot.Page(bounds: $0.bounds.expanded(by: bleed), name: $0.name, bleed: $0.bleed) }
        let exportRequest = ExportSnapshot.Request(name: request.name, pages: captured, scope: scope, includePageBoundary: true,
                                                   includeHidden: settings.includeHiddenLayers)
        var scene = ExportSnapshot.capture(state, request: exportRequest, builder: builder, blob: blob).scene
        for index in scene.pages.indices where bounds.indices.contains(index) {
            scene.pages[index].bounds = bounds[index]
        }
        let zeroPoints = Dictionary(uniqueKeysWithValues: pageList.pages.map { ($0.number, $0.zeroPoint) })
        return PrintRequest(scene: scene, source: source, options: options(settings, state: state, lists: scene.pages.map(\.displayList)), paper: request.paper,
                            pageRange: request.pageRange, selection: request.selection, zeroPoints: zeroPoints, objectScreens: objectScreens(state),
                            pathFlatness: pathFlatness(state), date: request.date, timeZone: request.timeZone)
    }

    // MARK: Settings

    /// The print settings as the plan reads them, with the ink list of the spot inks `lists` use.
    public static func options(_ settings: DocumentPrintSettings, state: EngineState, lists: [DisplayList]?) -> PrintOptions {
        let halftone = settings.defaultHalftone
        let screen = HalftoneScreen(shape: shape(halftone.shape) ?? .round, angle: 45, frequency: halftone.frequency)
        let scale: [DocumentPrintSettings.ScaleMode: PrintOptions.ScaleMode] = [.uniform: .uniform, .variable: .variable, .fit: .fit]
        let tile: [DocumentPrintSettings.TileMode: PrintOptions.TileMode] = [.none: .none, .automatic: .automatic, .manual: .manual]
        var marks: PrintOptions.Marks = []
        let markMap: [DocumentPrintSettings.Mark: PrintOptions.Marks] = [.crop: .crop, .registration: .registration, .separationNames: .separationNames,
                                                                         .fileNameDate: .fileNameDate]
        for mark in settings.marks { marks.insert(markMap[mark]!) }
        return PrintOptions(
            separations: settings.separations, scaleMode: scale[settings.scaleMode]!, scaleX: settings.scaleX, scaleY: settings.scaleY,
            offset: settings.offset, tile: tile[settings.tile]!, tileOverlap: settings.tileOverlap, printPageBoundary: settings.printPageBoundary,
            marks: marks, bleed: settings.bleed, emulsionDown: settings.emulsionDown, negative: settings.negative, flatness: settings.flatness,
            textAsOutlines: settings.textAsOutlines, rasterizeDPI: settings.rasterizeDPI, spotAsProcess: settings.spotAsProcess, defaultScreen: screen,
            plates: plates(settings, state: state, lists: lists), screenInApp: settings.screenInApp, ignoreObjectHalftones: settings.ignoreObjectHalftones
        )
    }

    /// The ink list (printing.adoc, "Composite or separations"): one row per process ink, then one
    /// per spot ink used in `lists` (every spot swatch when nil; never the protected Black and
    /// Registration swatches, which print on the process plates and every plate) in swatch order, each with its
    /// plate entry's settings or the defaults (printing, the ink's conventional angle, the document
    /// frequency).
    public static func plates(_ settings: DocumentPrintSettings, state: EngineState, lists: [DisplayList]?) -> [PrintPlate] {
        let used = lists.map { Set($0.flatMap { PlateRenderer().inks(in: $0) }) }
        let swatches = SwatchList(state)
        let spots = swatches.swatches.filter { $0.isSpot && !$0.isTint && $0.role == nil && used?.contains(.spot(NodeID($0.id))) != false }.map { PrintInk.spot($0.id) }
        return ([.cyan, .magenta, .yellow, .black] + spots).map { ink in
            let plate = settings.plate(ink)
            return PrintPlate(ink: renderInk(ink), name: ink.name(in: state), print: plate?.print ?? true, angle: plate?.angle ?? ink.defaultAngle,
                              frequency: plate?.frequency ?? 0)
        }
    }

    /// The ink list's inks for the print pane's rows: the process inks and the spot inks the
    /// printed artwork uses.
    public static func inks(_ state: EngineState, lists: [DisplayList]) -> [PrintInk] {
        plates(DocumentPrintSettings(state), state: state, lists: lists).map { plate in
            switch plate.ink {
            case .cyan: .cyan
            case .magenta: .magenta
            case .yellow: .yellow
            case .black: .black
            case .spot(let id): .spot(OpID(id))
            }
        }
    }

    static func renderInk(_ ink: PrintInk) -> Ink {
        switch ink {
        case .cyan: .cyan
        case .magenta: .magenta
        case .yellow: .yellow
        case .black: .black
        case .spot(let id): .spot(NodeID(id))
        }
    }

    static func shape(_ shape: Wiretuner_Doc_V1_HalftoneShape) -> HalftoneShape? {
        let shapes: [Wiretuner_Doc_V1_HalftoneShape: HalftoneShape] = [
            .round: .round, .ellipse: .ellipse, .line: .line, .diamond: .diamond, .square: .square, .cross: .cross,
        ]
        return shapes[shape]
    }

    // MARK: Objects

    /// Every live object's own screen (`CommonProps.halftone`), at any depth: the plan resolves
    /// *Default* parts against each plate, and the screener lets a member's own screen win over its
    /// group's (halftones.adoc, "Client").
    public static func objectScreens(_ state: EngineState) -> [NodeID: ObjectScreen] {
        var result: [NodeID: ObjectScreen] = [:]
        for node in state.store.nodes where state.isLive(node) {
            guard let common = NodeValues.common(state.props(node)), common.hasHalftone else { continue }
            let halftone = common.halftone
            result[NodeID(node)] = ObjectScreen(shape: shape(halftone.shape), angle: halftone.angle, frequency: halftone.frequency)
        }
        return result
    }

    /// Every live path's own *Flatness* (`PathProps.flatness`), device pixels.
    public static func pathFlatness(_ state: EngineState) -> [NodeID: Double] {
        var result: [NodeID: Double] = [:]
        for node in state.store.nodes where state.store.kind(node) == PathFields.kind && state.isLive(node) {
            let flatness = state.props(node).path.flatness
            if flatness.isFinite, flatness > 0 { result[NodeID(node)] = min(flatness, 100) }
        }
        return result
    }
}
