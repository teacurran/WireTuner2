// What a print job is asked to do (docs/_includes/printing/printing.adoc, "Client"): the
// document's print settings as the print plan reads them, the paper the job goes to, and the job
// parameters that are never document state (page range, *Selected objects only*).  Everything
// here is neutral -- no WTModel, no AppKit -- so the plan is a pure function the tests drive
// directly; WTModel fills it from `DocumentPrintSettings` (`PrintSnapshot`) and the app from the
// queue's `NSPrintInfo`.

import Foundation
import WTGeometry
import WTRender

/// The document's print settings (`PrintSettings`), read-time normalized.
public struct PrintOptions: Hashable, Sendable {
    public enum ScaleMode: Hashable, Sendable { case uniform, variable, fit }
    public enum TileMode: Hashable, Sendable { case none, automatic, manual }

    /// Printer's marks (`Marks`).
    public struct Marks: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let crop = Marks(rawValue: 1)
        public static let registration = Marks(rawValue: 2)
        public static let separationNames = Marks(rawValue: 4)
        public static let fileNameDate = Marks(rawValue: 8)
        public static let all: Marks = [.crop, .registration, .separationNames, .fileNameDate]
    }

    /// False = composite, true = one sheet per plate.
    public var separations: Bool
    public var scaleMode: ScaleMode
    /// Percent; `uniform` reads `scaleX` only.  Outside 1...2000 reads 100.
    public var scaleX: Double
    public var scaleY: Double
    /// The page's offset on the paper in points, x right and y down.
    public var offset: Point
    public var tile: TileMode
    /// Artwork repeated along each shared tile edge, points.
    public var tileOverlap: Double
    /// Printing the output area: outline the pages inside it.
    public var printPageBoundary: Bool
    public var marks: Marks
    /// Artwork printed beyond the page edge, points.
    public var bleed: Double
    /// Mirror every sheet horizontally.
    public var emulsionDown: Bool
    /// Invert every sheet.
    public var negative: Bool
    /// Device pixels; 0 lets the printer decide.
    public var flatness: Double
    /// *Print text as outlines* (PRINT-014 supplies the conversion, `PrintSheetRenderer.textOutliner`).
    public var textAsOutlines: Bool
    /// 0 prints vectors; otherwise each sheet's artwork is one image at this resolution.
    public var rasterizeDPI: Double
    /// Spot inks print through their process equivalents: only the four process plates.
    public var spotAsProcess: Bool
    /// The document screen every plate starts from: its shape and frequency (its angle is the
    /// plate's).
    public var defaultScreen: HalftoneScreen
    /// Every ink the job can print, in sheet order (C, M, Y, K, then spots in swatch order), with
    /// its row of the ink list.
    public var plates: [PrintPlate]
    /// Halftone plates in the app (`Screener`) instead of leaving screening to the printer.
    public var screenInApp: Bool
    /// Print every object with its plate's screen.
    public var ignoreObjectHalftones: Bool

    public init(separations: Bool = false, scaleMode: ScaleMode = .uniform, scaleX: Double = 100, scaleY: Double = 100, offset: Point = .zero,
                tile: TileMode = .none, tileOverlap: Double = 0, printPageBoundary: Bool = false, marks: Marks = [], bleed: Double = 0,
                emulsionDown: Bool = false, negative: Bool = false, flatness: Double = 0, textAsOutlines: Bool = false, rasterizeDPI: Double = 0,
                spotAsProcess: Bool = false, defaultScreen: HalftoneScreen = HalftoneScreen(), plates: [PrintPlate] = PrintPlate.process,
                screenInApp: Bool = false, ignoreObjectHalftones: Bool = false) {
        self.separations = separations
        self.scaleMode = scaleMode
        self.scaleX = (1...2000).contains(scaleX) ? scaleX : 100
        self.scaleY = (1...2000).contains(scaleY) ? scaleY : 100
        self.offset = offset.x.isFinite && offset.y.isFinite ? offset : .zero
        // Manual tiling under *Fit on paper* reads as none (printing.adoc, read-time rules).
        self.tile = scaleMode == .fit && tile == .manual ? .none : tile
        self.tileOverlap = tileOverlap.isFinite ? min(max(tileOverlap, 0), 720) : 0
        self.printPageBoundary = printPageBoundary
        self.marks = marks
        self.bleed = bleed.isFinite ? min(max(bleed, 0), 720) : 0
        self.emulsionDown = emulsionDown
        self.negative = negative
        self.flatness = flatness.isFinite ? min(max(flatness, 0), 100) : 0
        self.textAsOutlines = textAsOutlines
        self.rasterizeDPI = rasterizeDPI.isFinite && (72...2400).contains(rasterizeDPI) ? rasterizeDPI : 0
        self.spotAsProcess = spotAsProcess
        self.defaultScreen = defaultScreen
        self.plates = plates
        self.screenInApp = screenInApp
        self.ignoreObjectHalftones = ignoreObjectHalftones
    }

    /// The horizontal and vertical scale factors before fitting (1 = 100%).
    var fixedScale: (x: Double, y: Double) {
        switch scaleMode {
        case .uniform, .fit: return (scaleX / 100, scaleX / 100)
        case .variable: return (scaleX / 100, scaleY / 100)
        }
    }

    /// Whether the job tiles: *Fit on paper* never does.
    var effectiveTile: TileMode { scaleMode == .fit ? .none : tile }

    /// The plates the job prints, in sheet order: the ink list's rows with *Print* on, spot rows
    /// dropped under *Print spot colors as process*.
    public var printedPlates: [PrintPlate] {
        plates.filter { plate in
            guard plate.print else { return false }
            if case .spot = plate.ink { return !spotAsProcess }
            return true
        }
    }
}

/// One row of the ink list (`PlateSettings`, resolved): which ink, its name for labels, whether
/// it prints, and its screen.
public struct PrintPlate: Hashable, Sendable {
    public var ink: Ink
    /// "Magenta", or the spot swatch's name.
    public var name: String
    public var print: Bool
    /// Degrees.
    public var angle: Double
    /// Lines per inch; 0 = the document default.
    public var frequency: Double

    public init(ink: Ink, name: String? = nil, print: Bool = true, angle: Double? = nil, frequency: Double = 0) {
        self.ink = ink
        self.name = name ?? ink.description
        self.print = print
        self.angle = angle ?? ink.defaultAngle
        self.frequency = frequency
    }

    /// The four process plates with their default screens.
    public static let process: [PrintPlate] = Ink.process.map { PrintPlate(ink: $0) }

    /// The plate's screen: its angle, its frequency (or the document's), the document's shape.
    public func screen(default screen: HalftoneScreen) -> HalftoneScreen {
        HalftoneScreen(shape: screen.shape, angle: angle, frequency: frequency > 0 ? frequency : screen.frequency)
    }

    /// `75`, `22.5`: a whole number without decimals.
    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// `Magenta 75° 133 lpi`, the separation-name label.
    public func label(default screen: HalftoneScreen) -> String {
        let resolved = self.screen(default: screen)
        return "\(name) \(Self.format(resolved.angle))° \(Self.format(resolved.frequency)) lpi"
    }
}

/// An object's own screen from the Halftones panel, before it meets a plate: parts left at
/// *Default* inherit the plate's (halftones.adoc, "Merge semantics").
public struct ObjectScreen: Hashable, Sendable {
    /// Nil: the plate's shape.
    public var shape: HalftoneShape?
    public var angle: Double
    /// Nil: the plate's frequency.
    public var frequency: Double?

    public init(shape: HalftoneShape?, angle: Double, frequency: Double?) {
        self.shape = shape
        self.angle = angle
        self.frequency = frequency.flatMap { $0.isFinite && (1...600).contains($0) ? $0 : nil }
    }

    /// The screen on a plate screened with `plate`; nil when every part inherits (no screen of its
    /// own).
    public func resolved(on plate: HalftoneScreen) -> HalftoneScreen? {
        guard shape != nil || frequency != nil else { return nil }
        return HalftoneScreen(shape: shape ?? plate.shape, angle: angle, frequency: frequency ?? plate.frequency)
    }
}

/// The paper a job prints on (the queue's `NSPrintInfo`): its size and the printable area, in
/// points with the origin at the paper's top-left and y down, and the device resolution.
public struct PrintPaper: Hashable, Sendable {
    public var size: Size
    /// Where the printer can reach (`imageablePageBounds`, flipped to y down).
    public var imageable: Rect
    /// Device pixels per inch from the queue; nil when the queue does not say (a PDF).
    public var resolution: Double?

    public init(size: Size, imageable: Rect? = nil, resolution: Double? = nil) {
        self.size = size
        self.imageable = imageable ?? Rect(x: 0, y: 0, width: size.width, height: size.height)
        self.resolution = resolution.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// US Letter with a quarter-inch unprintable margin.
    public static let letter = PrintPaper(size: Size(width: 612, height: 792), imageable: Rect(x: 18, y: 18, width: 576, height: 756))

    public var bounds: Rect { Rect(x: 0, y: 0, width: size.width, height: size.height) }
}

/// One print job: the snapshot of what prints, the settings, the paper and the job parameters.
public struct PrintRequest: Sendable {
    /// What the job prints from.
    public enum Source: Hashable, Sendable {
        /// Each page of `scene` in the page range.
        case pages
        /// `scene`'s single page is the output area; `pageOutlines` are the pages inside it,
        /// outlined when `printPageBoundary` is on.
        case outputArea(pageOutlines: [Rect])
    }

    /// The pages (or the output area) as `ExportSnapshot` captured them, each page's list holding
    /// everything reaching into its bleed.
    public var scene: ExportScene
    public var source: Source
    public var options: PrintOptions
    public var paper: PrintPaper
    /// The page numbers to print (the dialog's range); nil prints every page.
    public var pageRange: ClosedRange<Int>?
    /// *Selected objects only*: the selected nodes (top-level or inside groups); nil prints
    /// everything.
    public var selection: Set<NodeID>?
    /// The rulers' zero point of each page (pasteboard), by page number: *Manual* tiling's tile
    /// starts there.
    public var zeroPoints: [Int: Point]
    /// Object screens by node, at any depth (a member's own screen wins over its group's).
    public var objectScreens: [NodeID: ObjectScreen]
    /// Paths' own flatness (device pixels), by node: it overrides `flatness` around the path.
    public var pathFlatness: [NodeID: Double]
    /// When the job was printed, for the file name and date label, shown in `timeZone`.
    public var date: Date
    public var timeZone: TimeZone

    public init(scene: ExportScene, source: Source = .pages, options: PrintOptions = PrintOptions(), paper: PrintPaper = .letter,
                pageRange: ClosedRange<Int>? = nil, selection: Set<NodeID>? = nil, zeroPoints: [Int: Point] = [:],
                objectScreens: [NodeID: ObjectScreen] = [:], pathFlatness: [NodeID: Double] = [:], date: Date = Date(), timeZone: TimeZone = .current) {
        self.scene = scene
        self.source = source
        self.options = options
        self.paper = paper
        self.pageRange = pageRange
        self.selection = selection
        self.zeroPoints = zeroPoints
        self.objectScreens = objectScreens
        self.pathFlatness = pathFlatness
        self.date = date
        self.timeZone = timeZone
    }
}
