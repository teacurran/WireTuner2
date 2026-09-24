import Foundation
import WTGeometry

/// The settings of the path tools this file's siblings deliver -- the Variable Stroke Pen
/// (freeform.adoc; DRAW-018), tablet input (DRAW-020), the Knife (editing-paths.adoc; DRAW-028),
/// the Freeform tool (DRAW-027), Mirror and 3D Rotation (transforming.adoc, path-effects.adoc;
/// OBJ-035) -- as preferences on this Mac: each tool's options sheet lists its keys and the tool
/// reads them at each use.  They never travel with the document.
enum PathToolPreferences {
    private static func stepper(_ range: ClosedRange<Double>, step: Double = 1, _ unit: String) -> PreferenceControl {
        .stepper(range: range, step: step, unit: unit)
    }

    private static func popup(_ options: [(String, String)]) -> PreferenceControl {
        .popup(options.map { PreferenceOption(.string($0.0), $0.1) })
    }

    // Variable Stroke Pen.
    static let strokePrecision = PreferenceKey<Int>("tools.variableStroke.precision", "Precision", category: .object, default: 5, control: stepper(1...10, ""), help: "freeform")
    static let strokeDotted = PreferenceKey<Bool>("tools.variableStroke.dotted", "Draw dotted line", category: .object, default: false, control: .toggle, help: "freeform")
    static let strokeRemoveOverlap = PreferenceKey<Bool>("tools.variableStroke.removeOverlap", "Auto remove overlap", category: .object, default: false,
                                                         control: .toggle, help: "freeform")
    static let strokeMin = PreferenceKey<Double>("tools.variableStroke.min", "Min", category: .object, default: 2, control: stepper(1...72, "pt"), help: "freeform")
    static let strokeMax = PreferenceKey<Double>("tools.variableStroke.max", "Max", category: .object, default: 12, control: stepper(1...72, "pt"), help: "freeform")

    /// The pressure curve hook (DRAW-020): width follows `pressure ^ curve`; 1 is linear.
    static let pressureCurve = PreferenceKey<Double>("tools.tablet.pressureCurve", "Pressure curve", category: .object, default: 1,
                                                     control: stepper(0.25...4, step: 0.25, ""), help: "freeform")

    // Knife.
    static let knifeStraight = PreferenceKey<String>("tools.knife.cut", "Cut", category: .object, default: "free",
                                                     control: popup([("free", "Free"), ("straight", "Straight")]), help: "editing-paths")
    static let knifeWidth = PreferenceKey<Double>("tools.knife.width", "Width", category: .object, default: 0, control: stepper(0...72, "pt"), help: "editing-paths")
    static let knifeClose = PreferenceKey<Bool>("tools.knife.close", "Close cut paths", category: .object, default: false, control: .toggle, help: "editing-paths")
    static let knifeTightFit = PreferenceKey<Bool>("tools.knife.tightFit", "Tight fit", category: .object, default: false, control: .toggle, help: "editing-paths")

    // Freeform.
    static let freeformMode = PreferenceKey<String>("tools.freeform.mode", "Mode", category: .object, default: "pushPull",
                                                    control: popup([("pushPull", "Push/Pull"), ("reshape", "Reshape area")]), help: "editing-paths")
    static let pushSize = PreferenceKey<Double>("tools.freeform.pushSize", "Push size", category: .object, default: 40, control: stepper(1...1000, "px"), help: "editing-paths")
    static let pushPrecision = PreferenceKey<Int>("tools.freeform.pushPrecision", "Push precision", category: .object, default: 5, control: stepper(1...10, ""), help: "editing-paths")
    static let pullBend = PreferenceKey<String>("tools.freeform.pullBend", "Pull bend", category: .object, default: "length",
                                                control: popup([("length", "By length"), ("points", "Between points")]), help: "editing-paths")
    static let pullLength = PreferenceKey<Double>("tools.freeform.length", "Length", category: .object, default: 100, control: stepper(1...1000, "px"), help: "editing-paths")
    static let pressureSize = PreferenceKey<Bool>("tools.freeform.pressureSize", "Pressure: Size", category: .object, default: false, control: .toggle, help: "editing-paths")
    static let pressureLength = PreferenceKey<Bool>("tools.freeform.pressureLength", "Pressure: Length", category: .object, default: false, control: .toggle,
                                                    help: "editing-paths")
    static let reshapeSize = PreferenceKey<Double>("tools.freeform.reshapeSize", "Size", category: .object, default: 60, control: stepper(1...1000, "px"), help: "editing-paths")
    static let reshapeStrength = PreferenceKey<Double>("tools.freeform.strength", "Strength", category: .object, default: 50, control: stepper(1...100, "%"),
                                                       help: "editing-paths")
    static let reshapePrecision = PreferenceKey<Int>("tools.freeform.reshapePrecision", "Precision", category: .object, default: 5, control: stepper(1...10, ""),
                                                     help: "editing-paths")

    // Mirror.
    static let mirrorAxis = PreferenceKey<String>("tools.mirror.axis", "Axis", category: .object, default: "vertical",
                                                  control: popup([("horizontal", "Horizontal"), ("vertical", "Vertical"), ("both", "Horizontal & Vertical"),
                                                                  ("multiple", "Multiple")]), help: "path-effects")
    static let mirrorAxes = PreferenceKey<Int>("tools.mirror.axes", "Axes", category: .object, default: 6, control: stepper(1...100, ""), help: "path-effects")
    static let mirrorRotate = PreferenceKey<Bool>("tools.mirror.rotate", "Rotate (not reflect) copies", category: .object, default: false, control: .toggle,
                                                  help: "path-effects")
    static let mirrorClosePaths = PreferenceKey<Bool>("tools.mirror.closePaths", "Close paths", category: .object, default: false, control: .toggle, help: "path-effects")

    // 3D Rotation.
    static let rotationExpert = PreferenceKey<Bool>("tools.rotation3D.expert", "Expert", category: .object, default: false, control: .toggle, help: "path-effects")
    static let rotationFrom = PreferenceKey<String>("tools.rotation3D.from", "Rotate from", category: .object, default: "center",
                                                    control: popup([("click", "Mouse click"), ("center", "Center of selection"), ("gravity", "Center of gravity"),
                                                                    ("origin", "Origin")]), help: "path-effects")
    static let rotationDistance = PreferenceKey<Double>("tools.rotation3D.distance", "Distance", category: .object, default: 500, control: stepper(10...10_000, "pt"),
                                                        help: "path-effects")
    static let projectFrom = PreferenceKey<String>("tools.rotation3D.project", "Project from", category: .object, default: "center",
                                                   control: popup([("click", "Mouse click"), ("center", "Center of selection"), ("gravity", "Center of gravity"),
                                                                   ("origin", "Origin"), ("point", "X/Y coordinates")]), help: "path-effects")
    static let projectX = PreferenceKey<Double>("tools.rotation3D.projectX", "X", category: .object, default: 0, control: stepper(-100_000...100_000, "pt"),
                                                help: "path-effects")
    static let projectY = PreferenceKey<Double>("tools.rotation3D.projectY", "Y", category: .object, default: 0, control: stepper(-100_000...100_000, "pt"),
                                                help: "path-effects")

    /// Each tool's sheet: the keys it lists.
    @MainActor static let sheets: [ToolID: [AnyPreferenceKey]] = [
        VariableStrokePen.id: [strokePrecision.erased, strokeDotted.erased, strokeRemoveOverlap.erased, strokeMin.erased, strokeMax.erased, pressureCurve.erased],
        KnifeTool.id: [knifeStraight.erased, knifeWidth.erased, knifeClose.erased, knifeTightFit.erased],
        FreeformTool.id: [freeformMode.erased, pushSize.erased, pushPrecision.erased, pullBend.erased, pullLength.erased, pressureSize.erased,
                          pressureLength.erased, reshapeSize.erased, reshapeStrength.erased, reshapePrecision.erased],
        MirrorTool.id: [mirrorAxis.erased, mirrorAxes.erased, mirrorRotate.erased, mirrorClosePaths.erased],
        Rotation3DTool.id: [rotationExpert.erased, rotationFrom.erased, rotationDistance.erased, projectFrom.erased, projectX.erased, projectY.erased],
    ]
}

/// How pen pressure becomes a width (freeform.adoc, "Drawing with a pen tablet"; DRAW-020): a
/// pen in contact maps its pressure through the curve onto `min...max`; a mouse, a trackpad or a
/// lifted pen leaves the width the bracket keys set, which kbd:[{startsb}] and kbd:[{endsb}] step
/// by `step` -- except while a pen is in contact, when they are ignored.
struct StrokeWidthControl: Equatable, Sendable {
    var min: Double
    var max: Double
    /// `pressure ^ curve`; 1 is linear.
    var curve: Double
    /// The width the bracket keys set.
    private(set) var keyWidth: Double
    /// Whether the last sample came from a pen in contact.
    private(set) var penInContact = false
    static let step = 1.0

    init(min: Double, max: Double, curve: Double = 1, keyWidth: Double? = nil) {
        let low = Swift.min(Swift.max(min, 0), Swift.max(max, 0)), high = Swift.max(Swift.max(min, 0), Swift.max(max, 0))
        self.min = low
        self.max = high
        self.curve = curve > 0 ? curve : 1
        self.keyWidth = keyWidth.map { Swift.min(Swift.max($0, low), high) } ?? (low + high) / 2
    }

    /// The width of a sample: mapped pressure for a pen, else the key width.
    mutating func width(for event: CanvasEvent) -> Double {
        penInContact = event.isTablet
        guard event.isTablet else { return keyWidth }
        let pressure = Swift.min(Swift.max(event.pressure, 0), 1)
        return min + (max - min) * pow(pressure, curve)
    }

    /// A bracket key: narrower (`[`) or wider (`]`); false (ignored) while a pen is in contact.
    @discardableResult
    mutating func bracket(wider: Bool) -> Bool {
        guard !penInContact else { return false }
        keyWidth = Swift.min(Swift.max(keyWidth + (wider ? Self.step : -Self.step), min), max)
        return true
    }

    /// The bracket a key event stands for: true for `]`, false for `[`, nil for another key.
    static func bracket(_ characters: String?) -> Bool? {
        switch characters {
        case "]": true
        case "[": false
        default: nil
        }
    }
}
