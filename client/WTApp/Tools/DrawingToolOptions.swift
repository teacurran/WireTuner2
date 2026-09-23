import Foundation
import WTGeometry
import WTModel

/// The drawing tools' own settings (polygons-stars.adoc, spirals-arcs.adoc, freeform.adoc): set in
/// each tool's options sheet, stored as preferences on the Mac (they never travel with the
/// document).  Not in `PreferenceCatalog.all`, which mirrors the preferences page row by row.
enum DrawingToolPreferences {
    private static func stepper(_ range: ClosedRange<Double>, step: Double = 1, _ unit: String) -> PreferenceControl {
        .stepper(range: range, step: step, unit: unit)
    }

    static let polygonSides = PreferenceKey<Int>("tools.polygon.sides", "Number of sides", category: .object, default: 5, control: stepper(3...360, ""), help: "polygons-stars")
    static let polygonStar = PreferenceKey<Bool>("tools.polygon.star", "Star", category: .object, default: false, control: .toggle, help: "polygons-stars")
    static let polygonAutomatic = PreferenceKey<Bool>("tools.polygon.automatic", "Automatic star points", category: .object, default: true, control: .toggle, help: "polygons-stars")
    static let polygonSharpness = PreferenceKey<Double>("tools.polygon.sharpness", "Acute/Obtuse", category: .object, default: 0.5, control: stepper(0...1, step: 0.01, ""), help: "polygons-stars")

    static let spiralExpanding = PreferenceKey<Bool>("tools.spiral.expanding", "Expanding", category: .object, default: false, control: .toggle, help: "spirals-arcs")
    static let spiralByIncrements = PreferenceKey<Bool>("tools.spiral.by_increments", "Draw by increments", category: .object, default: false, control: .toggle, help: "spirals-arcs")
    static let spiralRotations = PreferenceKey<Double>("tools.spiral.rotations", "Number of rotations", category: .object, default: 3, control: stepper(0.25...100, step: 0.25, ""), help: "spirals-arcs")
    static let spiralIncrement = PreferenceKey<Double>("tools.spiral.increment", "Increment width", category: .object, default: 12, control: stepper(0.1...1000, "pt"), help: "spirals-arcs")
    static let spiralStartingRadius = PreferenceKey<Double>("tools.spiral.starting_radius", "Starting radius", category: .object, default: 6, control: stepper(0.1...1000, "pt"), help: "spirals-arcs")
    static let spiralExpansion = PreferenceKey<Double>("tools.spiral.expansion", "Expansion", category: .object, default: 50, control: stepper(1...100, "%"), help: "spirals-arcs")
    static let spiralDrawFrom = PreferenceKey<String>("tools.spiral.draw_from", "Draw from", category: .object, default: "center",
                                                      control: .popup([PreferenceOption(.string("center"), "Center"), PreferenceOption(.string("edge"), "Edge"),
                                                                       PreferenceOption(.string("corner"), "Corner")]), help: "spirals-arcs")
    static let spiralClockwise = PreferenceKey<Bool>("tools.spiral.clockwise", "Clockwise", category: .object, default: true, control: .toggle, help: "spirals-arcs")

    static let arcOpen = PreferenceKey<Bool>("tools.arc.open", "Create open arc", category: .object, default: true, control: .toggle, help: "spirals-arcs")
    static let arcFlipped = PreferenceKey<Bool>("tools.arc.flipped", "Create flipped arc", category: .object, default: false, control: .toggle, help: "spirals-arcs")
    static let arcConcave = PreferenceKey<Bool>("tools.arc.concave", "Create concave arc", category: .object, default: false, control: .toggle, help: "spirals-arcs")

    static let pencilPrecision = PreferenceKey<Int>("tools.pencil.precision", "Precision", category: .object, default: 5, control: stepper(1...10, ""), help: "freeform")
    static let pencilDotted = PreferenceKey<Bool>("tools.pencil.dotted", "Draw dotted line", category: .object, default: false, control: .toggle, help: "freeform")
}

/// The drawing tools' settings as the tools read them at each use.
struct DrawingToolOptions: Equatable, Sendable {
    enum DrawFrom: String, Sendable, CaseIterable {
        case center, edge, corner
    }

    var polygon = PolygonOptions()
    var spiral = SpiralOptions()
    var spiralDrawFrom = DrawFrom.center
    var arcOpen = true
    var arcFlipped = false
    var arcConcave = false
    var pencilPrecision = PrecisionSetting(5)
    var pencilDotted = false

    /// The Polygon Tool sheet's settings.
    struct PolygonOptions: Equatable, Sendable {
        var sides = 5
        var star = false
        var automatic = true
        var sharpness = 0.5
    }

    init() {}

    @MainActor init(preferences: PreferenceStore) {
        typealias P = DrawingToolPreferences
        polygon = PolygonOptions(sides: preferences[P.polygonSides], star: preferences[P.polygonStar], automatic: preferences[P.polygonAutomatic],
                                 sharpness: preferences[P.polygonSharpness])
        spiral = SpiralOptions(
            kind: preferences[P.spiralExpanding] ? .expanding : .concentric, drawBy: preferences[P.spiralByIncrements] ? .increments : .rotations,
            rotations: preferences[P.spiralRotations], incrementWidth: preferences[P.spiralIncrement],
            startingRadius: preferences[P.spiralStartingRadius], expansion: preferences[P.spiralExpansion], clockwise: preferences[P.spiralClockwise]
        )
        spiralDrawFrom = DrawFrom(rawValue: preferences[P.spiralDrawFrom]) ?? .center
        arcOpen = preferences[P.arcOpen]
        arcFlipped = preferences[P.arcFlipped]
        arcConcave = preferences[P.arcConcave]
        pencilPrecision = PrecisionSetting(preferences[P.pencilPrecision])
        pencilDotted = preferences[P.pencilDotted]
    }

    /// The polygon the tool draws at `radius` and `rotation`.
    func polygonShape(radius: Double, rotation: Double) -> PolygonShape {
        let inner = PolygonShape.innerRadius(sharpness: polygon.sharpness, sides: min(max(polygon.sides, 3), 360), radius: radius)
        return PolygonShape(sides: polygon.sides, star: polygon.star, radius: radius, innerRadius: inner, autoInner: polygon.automatic,
                            sharpness: polygon.sharpness, rotation: rotation)
    }
}
