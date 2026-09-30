import WTCRDT
import WTProto
import WTRender

/// *Resample at* the printer resolution (find-replace.adoc, "Find & Replace tab"; OBJ-023; D-090):
/// the number of steps a blend needs so that no step is finer than the output can print.  A
/// halftone screen of `lpi` lines per inch on a `dpi` device prints `(dpi / lpi)²` grey levels of
/// one ink, at most 256 (PostScript's limit); a blend whose largest change of any one ink between
/// adjacent key objects is `Δ` (0 ... 1) crosses `levels × Δ` of them, so it gets
/// `ceil(levels × Δ)` steps, 1 ... 1000.  The resolution is the document's printer resolution
/// (300 dpi when never set) and the screen the document's default halftone frequency (60 lpi when
/// unset), so a 300 dpi document gets 25 steps for black to white and a 2,540 dpi one at 150 lpi
/// 256.  A blend whose key objects do not change colour has nothing to resample.
public enum BlendResampling {
    /// PostScript's grey levels per ink.
    public static let maximumLevels = 256.0

    /// The grey levels one ink prints at `resolution` dpi through a `frequency` lpi screen.
    public static func levels(resolution: Double, frequency: Double) -> Double {
        let screen = HalftoneScreen(frequency: frequency).frequency
        let dpi = resolution.isFinite && resolution > 0 ? resolution : Double(DocumentSettings.defaultPrinterResolution)
        let ratio = dpi / screen
        return min(ratio * ratio, maximumLevels)
    }

    /// The document's grey levels: its printer resolution and default screen frequency.
    public static func levels(in state: EngineState) -> Double {
        levels(resolution: Double(DocumentSettings(state).printerResolution), frequency: DocumentPrintSettings(state).defaultHalftone.frequency)
    }

    /// The largest change of any one ink between two colours, 0 ... 1: the tint change of one spot
    /// ink, else the process inks' change (the colours converted to CMYK).
    public static func inkChange(_ a: Color, _ b: Color) -> Double {
        if let spotA = a.spot, let spotB = b.spot, spotA.identity == spotB.identity { return abs(spotA.tint - spotB.tint) }
        let difference = a.converted(to: .cmyk).components - b.converted(to: .cmyk).components
        return min(max(abs(difference.x), abs(difference.y), abs(difference.z), abs(difference.w)), 1)
    }

    /// The steps for `levels` grey levels and an ink change of `change`; nil without a change.
    public static func steps(levels: Double, change: Double) -> Int? {
        guard change.isFinite, change > 1e-9, levels.isFinite, levels > 0 else { return nil }
        return min(max(Int((levels * change - 1e-9).rounded(.up)), 1), 1000)
    }

    /// The steps blend `node` resamples to, or nil when it is no blend or its colours do not
    /// change.
    public static func steps(for node: OpID, in state: EngineState) -> Int? {
        guard state.nodeKind(node) == .blend else { return nil }
        let resolver = ColorResolver(state)
        let keys = BlendReading.keyObjects(node, in: state).map { colors(of: $0, resolver: resolver, in: state) }
        var change = 0.0
        for (a, b) in zip(keys, keys.dropFirst()) {
            for (list, other) in zip(a, b) {
                for (x, y) in zip(list, other) { change = max(change, inkChange(x, y)) }
            }
        }
        return steps(levels: levels(in: state), change: change)
    }

    /// A key object's blended colours: its topmost visible fill's (a Basic colour, or a
    /// gradient's stops in ramp order) and its topmost visible Basic stroke's.
    static func colors(of node: OpID, resolver: ColorResolver, in state: EngineState) -> [[Color]] {
        var fill: [Color] = []
        if let entry = BlendEligibility.topmost(node, .fills, in: state) {
            if entry.fill.settings.kind == .gradient {
                fill = GradientReading.ramp(entry.fill.settings.gradient).compactMap { resolver.color($0.color) }
            } else if let color = resolver.color(entry.fill.settings.basic.color) {
                fill = [color]
            }
        }
        var stroke: [Color] = []
        if let entry = BlendEligibility.topmost(node, .strokes, in: state), let color = resolver.color(entry.stroke.settings.basic.color) {
            stroke = [color]
        }
        return [fill, stroke]
    }
}
