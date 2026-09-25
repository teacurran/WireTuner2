import Foundation
import WTCRDT
import WTInterchange
import WTProto
import WTRender

/// Print presets in the model (PRINT-004's pipeline half; printing.adoc, "Client": "on preset load
/// the keys are read back and written to the document as one change labelled `Apply print
/// preset`").  The pane's settings travel as WTInterchange's `PrintPreset` in the print info's
/// `WTPrint*` keys; this reads the document into one and writes one back.
public enum PrintPresets {
    /// The document's pane settings as a preset: every register, and a plate row for each process
    /// ink and each spot swatch (spot rows keyed by swatch name).
    public static func preset(_ state: EngineState) -> (preset: PrintPreset, includeHiddenLayers: Bool) {
        let settings = DocumentPrintSettings(state)
        return (PrintPreset(options: PrintSnapshot.options(settings, state: state, lists: nil)), settings.includeHiddenLayers)
    }

    /// The registers a preset writes.
    static func settings(_ options: PrintOptions, includeHiddenLayers: Bool) -> [PrintSetting] {
        let scale: [PrintOptions.ScaleMode: DocumentPrintSettings.ScaleMode] = [.uniform: .uniform, .variable: .variable, .fit: .fit]
        let tile: [PrintOptions.TileMode: DocumentPrintSettings.TileMode] = [.none: .none, .automatic: .automatic, .manual: .manual]
        let shapes: [HalftoneShape: Wiretuner_Doc_V1_HalftoneShape] = [.round: .round, .ellipse: .ellipse, .line: .line, .diamond: .diamond,
                                                                        .square: .square, .cross: .cross]
        var halftone = Wiretuner_Doc_V1_Halftone()
        halftone.shape = shapes[options.defaultScreen.shape]!
        halftone.frequency = options.defaultScreen.frequency
        return [
            .separations(options.separations), .scaleMode(scale[options.scaleMode]!), .scaleX(options.scaleX), .scaleY(options.scaleY),
            .offset(options.offset), .tile(tile[options.tile]!), .tileOverlap(options.tileOverlap), .printPageBoundary(options.printPageBoundary),
            .mark(.crop, options.marks.contains(.crop)), .mark(.registration, options.marks.contains(.registration)),
            .mark(.separationNames, options.marks.contains(.separationNames)), .mark(.fileNameDate, options.marks.contains(.fileNameDate)),
            .bleed(options.bleed), .emulsionDown(options.emulsionDown), .negative(options.negative), .includeHiddenLayers(includeHiddenLayers),
            .flatness(options.flatness), .textAsOutlines(options.textAsOutlines), .rasterizeDPI(options.rasterizeDPI),
            .spotAsProcess(options.spotAsProcess), .defaultHalftone(halftone), .screenInApp(options.screenInApp),
            .ignoreObjectHalftones(options.ignoreObjectHalftones),
        ]
    }
}

/// Applies a print preset to the document: every pane register and every plate row the preset
/// holds whose ink this document has (process inks always; spot inks by swatch name), as one
/// change labelled "Apply print preset".  A row edits the ink's effective plate entry (deleting its
/// duplicates) or inserts one.
public struct ApplyPrintPreset: Command {
    public var preset: PrintPreset
    public var includeHiddenLayers: Bool
    public var label: String { "Apply print preset" }

    public init(_ preset: PrintPreset, includeHiddenLayers: Bool) {
        self.preset = preset
        self.includeHiddenLayers = includeHiddenLayers
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try SetPrintSettings(PrintPresets.settings(preset.options, includeHiddenLayers: includeHiddenLayers), label: label).execute(&builder, state: state)
        let swatches = SwatchList(state)
        let current = DocumentPrintSettings(state).plates
        var inserts: [Wiretuner_Doc_V1_PlateSettings] = []
        var seen: Set<PrintInk> = []
        for row in preset.plates {
            let ink: PrintInk
            switch row.ink {
            case .process(let process):
                let inks: [Ink: PrintInk] = [.cyan: .cyan, .magenta: .magenta, .yellow: .yellow, .black: .black]
                guard let mapped = inks[process] else { continue }
                ink = mapped
            case .spot(let name):
                guard let swatch = swatches.swatches.first(where: { $0.isSpot && !$0.isTint && $0.plainName == name }) else { continue }
                ink = .spot(swatch.id)
            }
            guard seen.insert(ink).inserted, row.angle.isFinite, (0...360).contains(row.angle), row.frequency.isFinite, (0...600).contains(row.frequency) else { continue }
            var element = Wiretuner_Doc_V1_PlateSettings()
            element.print = row.print
            element.angle = row.angle
            element.frequency = row.frequency
            if let plate = current.first(where: { $0.ink == ink }) {
                builder.append(Ops.set(WellKnown.settings, [3, 4, 5].map { PrintFields.plate(plate.element, $0) }, values: PrintFields.values { $0.plates = [element] }))
                if !plate.duplicates.isEmpty {
                    builder.append(Ops.elementDelete(WellKnown.settings, plate.duplicates.map { PrintFields.plates.element($0) }))
                }
            } else {
                element.ink = ink.stored
                inserts.append(element)
            }
        }
        guard !inserts.isEmpty else { return }
        let last = state.store.elementOrder(WellKnown.settings, PrintFields.plates).last.flatMap { state.position(WellKnown.settings, PrintFields.plates, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: inserts.count)
        builder.append(Ops.elementInsert(WellKnown.settings, PrintFields.plates, positions: keys, values: PrintFields.values { $0.plates = inserts }))
    }
}
