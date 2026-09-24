import Foundation
import WTCRDT
import WTGeometry
import WTProto

// PRINT-002: the document's print settings in the model (printing/printing.adoc, "Data model",
// "Merge semantics").  `SettingsProps.print` (31) is a STRUCT, so every register merges on its
// own; `offset`, `default_halftone` and a plate's `ink` are ATOMIC; `plates` is a SEQUENCE with the
// duplicate-ink rule read here.  `SettingsProps.print_info` (32) is this Mac's archived NSPrintInfo,
// `local_only`: written like any register, never on the wire (crdt-model.adoc, "Local-only
// fields"), kept by the local store in its `view` table.

/// Register paths of the print settings on the settings node (0:1).
public enum PrintFields {
    /// `SettingsProps.print`.
    public static let print = RegisterPath([SettingsFields.kind, 31])
    /// `SettingsProps.print_info` (local_only).
    public static let printInfo = RegisterPath([SettingsFields.kind, 32])
    /// `PrintSettings.plates`.
    public static let plates = print.child(19)

    /// Field `number` of `PrintSettings`.
    public static func field(_ number: UInt32) -> RegisterPath { print.child(number) }
    /// Field `number` of `Marks`.
    public static func mark(_ number: UInt32) -> RegisterPath { print.child(9).child(number) }
    /// Field `number` of plate element `id`.
    public static func plate(_ id: OpID, _ number: UInt32) -> RegisterPath { plates.element(id).child(number) }

    static func values(_ build: (inout Wiretuner_Doc_V1_PrintSettings) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        SettingsFields.values { build(&$0.print) }
    }
}

/// An ink with a plate: a process ink or a spot colour swatch.
public enum PrintInk: Hashable, Sendable, Comparable {
    case cyan, magenta, yellow, black
    case spot(OpID)

    /// The stored `Ink`, or nil for one the model ignores (unspecified process, no case).
    init?(_ ink: Wiretuner_Doc_V1_Ink) {
        switch ink.ink {
        case .process(let process)?:
            switch process {
            case .cyan: self = .cyan
            case .magenta: self = .magenta
            case .yellow: self = .yellow
            case .black: self = .black
            default: return nil
            }
        case .spot(let ref)?: self = .spot(OpID(ref.id))
        case nil: return nil
        }
    }

    var stored: Wiretuner_Doc_V1_Ink {
        var ink = Wiretuner_Doc_V1_Ink()
        switch self {
        case .cyan: ink.process = .cyan
        case .magenta: ink.process = .magenta
        case .yellow: ink.process = .yellow
        case .black: ink.process = .black
        case .spot(let id): ink.spot.id = id.proto
        }
        return ink
    }

    /// Sheet order: C, M, Y, K, then spots (by node id here; the print plan orders them by swatch).
    var rank: (Int, OpID) {
        switch self {
        case .cyan: (0, .zero)
        case .magenta: (1, .zero)
        case .yellow: (2, .zero)
        case .black: (3, .zero)
        case .spot(let id): (4, id)
        }
    }

    public static func < (lhs: PrintInk, rhs: PrintInk) -> Bool { lhs.rank < rhs.rank }

    /// The conventional screen angle of the ink when its entry has none.
    public var defaultAngle: Double {
        switch self {
        case .cyan: 15
        case .magenta: 75
        case .yellow: 0
        case .black, .spot: 45
        }
    }

    /// "Magenta", or the spot swatch's name, for labels.
    public func name(in state: EngineState) -> String {
        switch self {
        case .cyan: "Cyan"
        case .magenta: "Magenta"
        case .yellow: "Yellow"
        case .black: "Black"
        case .spot(let id): SwatchList(state)[id]?.plainName ?? "spot"
        }
    }
}

/// One plate's effective settings.
public struct PlateInfo: Hashable, Sendable {
    public var ink: PrintInk
    /// The sequence element holding them (the smallest live element id for the ink).
    public var element: OpID
    public var print: Bool
    /// The written angle, or the ink's default when never written.
    public var angle: Double
    public var angleWritten: Bool
    /// Lines per inch; 0 = the document default.
    public var frequency: Double
    /// The other live entries for the same ink, ignored on read and deleted by the next edit.
    public var duplicates: [OpID]
}

/// The print settings as read (printing.adoc, read-time normalizations): scale outside 1...2000
/// (or never set) reads 100; negative bleed and overlap read 0; manual tiling with *Fit on
/// paper* reads as no tiling; of several live plate entries for one ink the smallest element id
/// holds the plate; an entry whose ink is unset, whose spot swatch is gone or no longer a spot
/// colour, is ignored.
public struct DocumentPrintSettings: Hashable, Sendable {
    public enum ScaleMode: Hashable, Sendable { case uniform, variable, fit }
    public enum TileMode: Hashable, Sendable { case none, automatic, manual }
    public enum Mark: UInt32, CaseIterable, Hashable, Sendable {
        case crop = 1, registration = 2, separationNames = 3, fileNameDate = 4
    }

    public var separations: Bool
    public var scaleMode: ScaleMode
    public var scaleX: Double
    public var scaleY: Double
    public var offset: Point
    public var tile: TileMode
    public var tileOverlap: Double
    public var printPageBoundary: Bool
    public var marks: Set<Mark>
    public var bleed: Double
    public var emulsionDown: Bool
    public var negative: Bool
    public var includeHiddenLayers: Bool
    public var flatness: Double
    public var textAsOutlines: Bool
    public var rasterizeDPI: Double
    public var spotAsProcess: Bool
    public var defaultHalftone: Wiretuner_Doc_V1_Halftone
    /// The effective plates, C, M, Y, K, then spots.
    public var plates: [PlateInfo]
    public var screenInApp: Bool
    public var ignoreObjectHalftones: Bool
    /// This Mac's archived NSPrintInfo (local-only); nil when never set up here.
    public var printInfo: Data?

    public init(_ state: EngineState) {
        let settings = state.props(WellKnown.settings).settings
        let stored = settings.print
        separations = stored.separations
        scaleMode = [.variable: .variable, .fit: .fit][stored.scaleMode] ?? .uniform
        scaleX = Self.scale(stored.scaleX)
        scaleY = Self.scale(stored.scaleY)
        offset = Point(x: stored.offset.x, y: stored.offset.y)
        let tile: TileMode = [.automatic: .automatic, .manual: .manual][stored.tile] ?? .none
        self.tile = tile == .manual && scaleMode == .fit ? .none : tile
        tileOverlap = max(stored.tileOverlap, 0)
        printPageBoundary = stored.printPageBoundary
        var marks: Set<Mark> = []
        if stored.marks.crop { marks.insert(.crop) }
        if stored.marks.registration { marks.insert(.registration) }
        if stored.marks.separationNames { marks.insert(.separationNames) }
        if stored.marks.fileNameDate { marks.insert(.fileNameDate) }
        self.marks = marks
        bleed = max(stored.bleed, 0)
        emulsionDown = stored.emulsionDown
        negative = stored.negative
        includeHiddenLayers = stored.includeHiddenLayers
        flatness = stored.flatness
        textAsOutlines = stored.textAsOutlines
        rasterizeDPI = stored.rasterizeDpi
        spotAsProcess = stored.spotAsProcess
        defaultHalftone = stored.defaultHalftone
        screenInApp = stored.screenInApp
        ignoreObjectHalftones = stored.ignoreObjectHalftones
        printInfo = settings.printInfo.isEmpty ? nil : settings.printInfo
        plates = Self.plates(stored.plates, in: state)
    }

    static func scale(_ value: Double) -> Double {
        (1...2000).contains(value) ? value : 100
    }

    /// Whether `ink` has a plate the model reads: a process ink, or a live spot swatch.
    static func isValid(_ ink: PrintInk, list: SwatchList) -> Bool {
        guard case .spot(let id) = ink else { return true }
        return list[id]?.isSpot == true
    }

    static func plates(_ entries: [Wiretuner_Doc_V1_PlateSettings], in state: EngineState) -> [PlateInfo] {
        let list = SwatchList(state)
        var byInk: [PrintInk: PlateInfo] = [:]
        for entry in entries {
            guard let ink = PrintInk(entry.ink), isValid(ink, list: list), let id = OpID(element: entry.id) else { continue }
            let written = state.register(WellKnown.settings, PrintFields.plate(id, 4))?.isSet == true
            let info = PlateInfo(ink: ink, element: id, print: entry.print, angle: written ? entry.angle : ink.defaultAngle,
                                 angleWritten: written, frequency: entry.frequency, duplicates: [])
            if var existing = byInk[ink] {
                if id < existing.element {
                    var replaced = info
                    replaced.duplicates = (existing.duplicates + [existing.element]).sorted()
                    byInk[ink] = replaced
                } else {
                    existing.duplicates = (existing.duplicates + [id]).sorted()
                    byInk[ink] = existing
                }
            } else {
                byInk[ink] = info
            }
        }
        return byInk.values.sorted { $0.ink < $1.ink }
    }

    /// The effective plate of `ink`, when it has an entry.
    public func plate(_ ink: PrintInk) -> PlateInfo? {
        plates.first { $0.ink == ink }
    }
}

/// Why a print settings command was refused.
public enum PrintSettingsError: Error, Equatable, Sendable {
    /// A value outside the field's range.
    case invalidValue(String)
    /// An ink with no plate: an unset process ink, or a swatch that is not a live spot colour.
    case notAnInk
}

/// One print settings register and its new value.
public enum PrintSetting: Hashable, Sendable {
    case separations(Bool)
    case scaleMode(DocumentPrintSettings.ScaleMode)
    /// Percent, 1...2000.
    case scaleX(Double)
    case scaleY(Double)
    case offset(Point)
    case tile(DocumentPrintSettings.TileMode)
    /// Points, 0...720.
    case tileOverlap(Double)
    case printPageBoundary(Bool)
    case mark(DocumentPrintSettings.Mark, Bool)
    /// Points, 0...720.
    case bleed(Double)
    case emulsionDown(Bool)
    case negative(Bool)
    case includeHiddenLayers(Bool)
    /// Device pixels, 0...100.
    case flatness(Double)
    case textAsOutlines(Bool)
    /// 0 (vector) or 72...2400.
    case rasterizeDPI(Double)
    case spotAsProcess(Bool)
    case defaultHalftone(Wiretuner_Doc_V1_Halftone)
    case screenInApp(Bool)
    case ignoreObjectHalftones(Bool)

    /// The register the setting writes and the sparse value holding it.
    func write() throws -> (RegisterPath, Wiretuner_Doc_V1_NodeProps) {
        func check(_ value: Double, _ range: ClosedRange<Double>, _ name: String, zeroAllowed: Bool = false) throws {
            guard value.isFinite, range.contains(value) || (zeroAllowed && value == 0) else { throw PrintSettingsError.invalidValue(name) }
        }
        switch self {
        case .separations(let on): return (PrintFields.field(1), PrintFields.values { $0.separations = on })
        case .scaleMode(let mode):
            let stored: Wiretuner_Doc_V1_PrintScaleMode = [.uniform: .uniform, .variable: .variable, .fit: .fit][mode]!
            return (PrintFields.field(2), PrintFields.values { $0.scaleMode = stored })
        case .scaleX(let value):
            try check(value, 1...2000, "scale")
            return (PrintFields.field(3), PrintFields.values { $0.scaleX = value })
        case .scaleY(let value):
            try check(value, 1...2000, "scale")
            return (PrintFields.field(4), PrintFields.values { $0.scaleY = value })
        case .offset(let point):
            guard point.isFinite else { throw PrintSettingsError.invalidValue("offset") }
            return (PrintFields.field(5), PrintFields.values { $0.offset = PathEditing.proto(point) })
        case .tile(let mode):
            let stored: Wiretuner_Doc_V1_PrintTileMode = [.none: .none, .automatic: .automatic, .manual: .manual][mode]!
            return (PrintFields.field(6), PrintFields.values { $0.tile = stored })
        case .tileOverlap(let value):
            try check(value, 0...720, "tile overlap")
            return (PrintFields.field(7), PrintFields.values { $0.tileOverlap = value })
        case .printPageBoundary(let on): return (PrintFields.field(8), PrintFields.values { $0.printPageBoundary = on })
        case .mark(let mark, let on):
            return (PrintFields.mark(mark.rawValue), PrintFields.values { props in
                switch mark {
                case .crop: props.marks.crop = on
                case .registration: props.marks.registration = on
                case .separationNames: props.marks.separationNames = on
                case .fileNameDate: props.marks.fileNameDate = on
                }
            })
        case .bleed(let value):
            try check(value, 0...720, "bleed")
            return (PrintFields.field(10), PrintFields.values { $0.bleed = value })
        case .emulsionDown(let on): return (PrintFields.field(11), PrintFields.values { $0.emulsionDown = on })
        case .negative(let on): return (PrintFields.field(12), PrintFields.values { $0.negative = on })
        case .includeHiddenLayers(let on): return (PrintFields.field(13), PrintFields.values { $0.includeHiddenLayers = on })
        case .flatness(let value):
            try check(value, 0...100, "flatness")
            return (PrintFields.field(14), PrintFields.values { $0.flatness = value })
        case .textAsOutlines(let on): return (PrintFields.field(15), PrintFields.values { $0.textAsOutlines = on })
        case .rasterizeDPI(let value):
            try check(value, 72...2400, "rasterize resolution", zeroAllowed: true)
            return (PrintFields.field(16), PrintFields.values { $0.rasterizeDpi = value })
        case .spotAsProcess(let on): return (PrintFields.field(17), PrintFields.values { $0.spotAsProcess = on })
        case .defaultHalftone(let halftone):
            guard halftone.angle.isFinite, (0...360).contains(halftone.angle), halftone.frequency.isFinite, (0...600).contains(halftone.frequency) else {
                throw PrintSettingsError.invalidValue("halftone")
            }
            return (PrintFields.field(18), PrintFields.values { $0.defaultHalftone = halftone })
        case .screenInApp(let on): return (PrintFields.field(20), PrintFields.values { $0.screenInApp = on })
        case .ignoreObjectHalftones(let on): return (PrintFields.field(21), PrintFields.values { $0.ignoreObjectHalftones = on })
        }
    }

    /// The Undo menu's name for a change of this setting alone.
    public var label: String {
        func toggle(_ on: Bool, _ name: String) -> String { "Turn \(on ? "on" : "off") \(name)" }
        switch self {
        case .separations(let on): return toggle(on, "separations")
        case .scaleMode: return "Change scaling"
        case .scaleX, .scaleY: return "Change scale"
        case .offset: return "Change offset"
        case .tile: return "Change tiling"
        case .tileOverlap: return "Change tile overlap"
        case .printPageBoundary(let on): return toggle(on, "page boundary")
        case .mark(let mark, let on):
            let names: [DocumentPrintSettings.Mark: String] = [.crop: "crop marks", .registration: "registration marks",
                                                               .separationNames: "separation names", .fileNameDate: "file name and date"]
            return toggle(on, names[mark]!)
        case .bleed: return "Change bleed"
        case .emulsionDown(let on): return toggle(on, "emulsion down")
        case .negative(let on): return toggle(on, "negative")
        case .includeHiddenLayers(let on): return toggle(on, "hidden layers")
        case .flatness: return "Change flatness"
        case .textAsOutlines(let on): return toggle(on, "text as outlines")
        case .rasterizeDPI: return "Change rasterize resolution"
        case .spotAsProcess(let on): return toggle(on, "spot colors as process")
        case .defaultHalftone: return "Change halftone screen"
        case .screenInApp(let on): return toggle(on, "screening in app")
        case .ignoreObjectHalftones(let on): return toggle(on, "ignore object screens")
        }
    }
}

/// Writes print settings registers (the print dialog pane's controls, a preset): one `SetFields`
/// on the settings node, one change.  A single setting is labelled by it ("Change bleed", "Turn
/// off crop marks"); several by `label` ("Apply print preset").
public struct SetPrintSettings: Command {
    public var settings: [PrintSetting]
    public let label: String

    public init(_ setting: PrintSetting) {
        settings = [setting]
        label = setting.label
    }

    public init(_ settings: [PrintSetting], label: String = "Apply print preset") {
        self.settings = settings
        self.label = settings.count == 1 ? settings[0].label : label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !settings.isEmpty else { return }
        var paths: [RegisterPath] = []
        var values = Wiretuner_Doc_V1_NodeProps()
        for setting in settings {
            let (path, value) = try setting.write()
            paths.append(path)
            let bytes: [UInt8] = try value.serializedBytes()
            try values.merge(serializedBytes: bytes)
        }
        builder.append(Ops.set(WellKnown.settings, paths, values: values))
    }
}

/// Edits one ink's plate row (Output section of the print pane): the effective entry's registers,
/// or -- the first time the row is touched -- a new entry with `print` written true (unless set
/// here) and the given values.  Live duplicates of the ink (two users touching the same untouched
/// row concurrently) are deleted in the same change.  "Turn off Magenta plate", "Change Magenta
/// plate screen".
public struct SetPlate: Command {
    public var ink: PrintInk
    public var print: Bool?
    public var angle: Double?
    public var frequency: Double?
    public let label: String

    public init(_ ink: PrintInk, print: Bool? = nil, angle: Double? = nil, frequency: Double? = nil, in state: EngineState) {
        self.ink = ink
        self.print = print
        self.angle = angle
        self.frequency = frequency
        let name = ink.name(in: state)
        if let print, angle == nil, frequency == nil {
            label = "Turn \(print ? "on" : "off") \(name) plate"
        } else {
            label = "Change \(name) plate screen"
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard DocumentPrintSettings.isValid(ink, list: SwatchList(state)) else { throw PrintSettingsError.notAnInk }
        if let angle { guard angle.isFinite, (0...360).contains(angle) else { throw PrintSettingsError.invalidValue("angle") } }
        if let frequency { guard frequency.isFinite, (0...600).contains(frequency) else { throw PrintSettingsError.invalidValue("frequency") } }
        var element = Wiretuner_Doc_V1_PlateSettings()
        var paths: [UInt32] = []
        if let print {
            element.print = print
            paths.append(3)
        }
        if let angle {
            element.angle = angle
            paths.append(4)
        }
        if let frequency {
            element.frequency = frequency
            paths.append(5)
        }
        let current = DocumentPrintSettings.plates(state.props(WellKnown.settings).settings.print.plates, in: state).first { $0.ink == ink }
        if let current {
            guard !paths.isEmpty else { return }
            builder.append(Ops.set(WellKnown.settings, paths.map { PrintFields.plate(current.element, $0) }, values: PrintFields.values { $0.plates = [element] }))
            if !current.duplicates.isEmpty {
                builder.append(Ops.elementDelete(WellKnown.settings, current.duplicates.map { PrintFields.plates.element($0) }))
            }
        } else {
            element.ink = ink.stored
            if print == nil { element.print = true }
            let last = state.store.elementOrder(WellKnown.settings, PrintFields.plates).last.flatMap { state.position(WellKnown.settings, PrintFields.plates, $0) }
            let key = try PathEditing.keys(between: last, and: nil, count: 1)
            builder.append(Ops.elementInsert(WellKnown.settings, PrintFields.plates, positions: key, values: PrintFields.values { $0.plates = [element] }))
        }
    }
}

/// Stores this Mac's archived NSPrintInfo for the document (menu:File[Page Setup…] and the print
/// dialog's btn:[Print]): the local-only `print_info` register, which never leaves the Mac; nil
/// clears it.  "Page Setup".
public struct SetPrintInfo: Command {
    public var archive: Data?
    public var label: String { "Page Setup" }

    public init(_ archive: Data?) {
        self.archive = archive
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let archive, archive.count > 262_144 { throw PrintSettingsError.invalidValue("print info") }
        builder.append(Ops.set(WellKnown.settings, [PrintFields.printInfo], values: SettingsFields.values { $0.printInfo = archive ?? Data() }))
    }
}
