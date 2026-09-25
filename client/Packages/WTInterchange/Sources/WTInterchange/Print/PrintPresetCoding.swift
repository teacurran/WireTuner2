// Print presets (PRINT-004's pipeline half; printing.adoc, "What is remembered, and where", and
// "Client"): the pane's settings mirrored into the print info's dictionary under `WTPrint*` keys,
// so the Print dialog's *Presets* menu captures them with the paper and printer; loading a preset
// reads them back.  Values are property-list types (Bool, Double, String, arrays and
// dictionaries of them), which is what `NSPrintInfo.dictionary()` keeps.  Plates are keyed by
// ink -- process inks by name, spot inks by swatch name -- so a preset applies to a document
// whose swatches have other ids.

import Foundation
import WTRender

/// A preset plate's ink.
public enum PresetInk: Hashable, Sendable {
    case process(Ink)
    /// A spot swatch, by name.
    case spot(String)
}

/// One plate row of a preset.
public struct PresetPlate: Hashable, Sendable {
    public var ink: PresetInk
    public var print: Bool
    public var angle: Double
    public var frequency: Double

    public init(ink: PresetInk, print: Bool, angle: Double, frequency: Double) {
        self.ink = ink
        self.print = print
        self.angle = angle
        self.frequency = frequency
    }
}

/// The pane's settings as a preset holds them.
public struct PrintPreset: Hashable, Sendable {
    public var options: PrintOptions
    public var plates: [PresetPlate]

    public init(options: PrintOptions) {
        self.options = options
        plates = options.plates.map { plate in
            let ink: PresetInk
            if case .spot = plate.ink { ink = .spot(plate.name) } else { ink = .process(plate.ink) }
            return PresetPlate(ink: ink, print: plate.print, angle: plate.angle, frequency: plate.frequency)
        }
    }

    init(options: PrintOptions, plates: [PresetPlate]) {
        self.options = options
        self.plates = plates
    }

    /// The keys every preset writes.
    public enum Key {
        public static let prefix = "WTPrint"
        static let separations = "WTPrintSeparations", scaleMode = "WTPrintScaleMode", scaleX = "WTPrintScaleX", scaleY = "WTPrintScaleY"
        static let offsetX = "WTPrintOffsetX", offsetY = "WTPrintOffsetY", tile = "WTPrintTile", tileOverlap = "WTPrintTileOverlap"
        static let pageBoundary = "WTPrintPageBoundary", marks = "WTPrintMarks", bleed = "WTPrintBleed", emulsionDown = "WTPrintEmulsionDown"
        static let negative = "WTPrintNegative", flatness = "WTPrintFlatness", textAsOutlines = "WTPrintTextAsOutlines"
        static let rasterizeDPI = "WTPrintRasterizeDPI", spotAsProcess = "WTPrintSpotAsProcess", screenShape = "WTPrintScreenShape"
        static let screenFrequency = "WTPrintScreenFrequency", screenInApp = "WTPrintScreenInApp", ignoreObjectScreens = "WTPrintIgnoreObjectScreens"
        static let plates = "WTPrintPlates", includeHidden = "WTPrintIncludeHiddenLayers"
    }

    static let scaleModes: [PrintOptions.ScaleMode: String] = [.uniform: "uniform", .variable: "variable", .fit: "fit"]
    static let tileModes: [PrintOptions.TileMode: String] = [.none: "none", .automatic: "automatic", .manual: "manual"]
    static let processNames: [Ink: String] = [.cyan: "cyan", .magenta: "magenta", .yellow: "yellow", .black: "black"]
    static let markNames: [(PrintOptions.Marks, String)] = [(.crop, "crop"), (.registration, "registration"), (.separationNames, "separationNames"),
                                                            (.fileNameDate, "fileNameDate")]

    /// The preset as `WTPrint*` dictionary entries; `includeHiddenLayers` rides along because it
    /// is a pane setting the plan receives through the snapshot rather than `PrintOptions`.
    public func dictionary(includeHiddenLayers: Bool) -> [String: Any] {
        let o = options
        var plateEntries: [[String: Any]] = []
        for plate in plates {
            var entry: [String: Any] = ["print": plate.print, "angle": plate.angle, "frequency": plate.frequency]
            switch plate.ink {
            case .process(let ink): entry["process"] = Self.processNames[ink] ?? "black"
            case .spot(let name): entry["spot"] = name
            }
            plateEntries.append(entry)
        }
        return [
            Key.separations: o.separations, Key.scaleMode: Self.scaleModes[o.scaleMode]!, Key.scaleX: o.scaleX, Key.scaleY: o.scaleY,
            Key.offsetX: o.offset.x, Key.offsetY: o.offset.y, Key.tile: Self.tileModes[o.tile]!, Key.tileOverlap: o.tileOverlap,
            Key.pageBoundary: o.printPageBoundary, Key.marks: Self.markNames.filter { o.marks.contains($0.0) }.map(\.1), Key.bleed: o.bleed,
            Key.emulsionDown: o.emulsionDown, Key.negative: o.negative, Key.flatness: o.flatness, Key.textAsOutlines: o.textAsOutlines,
            Key.rasterizeDPI: o.rasterizeDPI, Key.spotAsProcess: o.spotAsProcess, Key.screenShape: o.defaultScreen.shape.rawValue,
            Key.screenFrequency: o.defaultScreen.frequency, Key.screenInApp: o.screenInApp, Key.ignoreObjectScreens: o.ignoreObjectHalftones,
            Key.plates: plateEntries, Key.includeHidden: includeHiddenLayers,
        ]
    }

    /// The preset in `dictionary` and its *Include hidden layers*; nil when the dictionary holds
    /// no `WTPrint*` settings (a preset saved without the pane).  Missing or mistyped values read
    /// as the defaults.
    public static func read(_ dictionary: [String: Any]) -> (preset: PrintPreset, includeHiddenLayers: Bool)? {
        guard dictionary.keys.contains(where: { $0.hasPrefix(Key.prefix) }) else { return nil }
        func bool(_ key: String) -> Bool { (dictionary[key] as? NSNumber)?.boolValue ?? false }
        func number(_ key: String, _ fallback: Double = 0) -> Double { (dictionary[key] as? NSNumber)?.doubleValue ?? fallback }
        func string(_ key: String) -> String? { dictionary[key] as? String }
        let marks = Set((dictionary[Key.marks] as? [String]) ?? [])
        var markSet: PrintOptions.Marks = []
        for (mark, name) in markNames where marks.contains(name) { markSet.insert(mark) }
        let processes = Dictionary(uniqueKeysWithValues: processNames.map { ($1, $0) })
        var plates: [PresetPlate] = []
        for entry in (dictionary[Key.plates] as? [[String: Any]]) ?? [] {
            let ink: PresetInk
            if let name = entry["process"] as? String, let process = processes[name] {
                ink = .process(process)
            } else if let name = entry["spot"] as? String {
                ink = .spot(name)
            } else {
                continue
            }
            plates.append(PresetPlate(ink: ink, print: (entry["print"] as? NSNumber)?.boolValue ?? true,
                                      angle: (entry["angle"] as? NSNumber)?.doubleValue ?? 45, frequency: (entry["frequency"] as? NSNumber)?.doubleValue ?? 0))
        }
        let scaleMode = string(Key.scaleMode).flatMap { name in scaleModes.first { $0.value == name }?.key } ?? .uniform
        let tile = string(Key.tile).flatMap { name in tileModes.first { $0.value == name }?.key } ?? .none
        let shape = string(Key.screenShape).flatMap(HalftoneShape.init(rawValue:)) ?? .round
        let options = PrintOptions(
            separations: bool(Key.separations), scaleMode: scaleMode, scaleX: number(Key.scaleX, 100), scaleY: number(Key.scaleY, 100),
            offset: .init(x: number(Key.offsetX), y: number(Key.offsetY)), tile: tile, tileOverlap: number(Key.tileOverlap),
            printPageBoundary: bool(Key.pageBoundary), marks: markSet, bleed: number(Key.bleed), emulsionDown: bool(Key.emulsionDown),
            negative: bool(Key.negative), flatness: number(Key.flatness), textAsOutlines: bool(Key.textAsOutlines), rasterizeDPI: number(Key.rasterizeDPI),
            spotAsProcess: bool(Key.spotAsProcess), defaultScreen: HalftoneScreen(shape: shape, angle: 45, frequency: number(Key.screenFrequency, 60)),
            plates: [], screenInApp: bool(Key.screenInApp), ignoreObjectHalftones: bool(Key.ignoreObjectScreens)
        )
        return (PrintPreset(options: options, plates: plates), bool(Key.includeHidden))
    }
}
