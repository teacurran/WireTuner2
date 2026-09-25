import Foundation

/// The options of the destructive effect tools (path-effects.adoc; FX-032, FX-033): Roughen,
/// Fisheye Lens, Bend, Smudge and Shadow, as preferences on this Mac.  Each tool's options sheet
/// lists its keys (a double-click on the tool) and the tool reads them at each use; they never
/// travel with the document.
enum DistortPreferences {
    static let white = PreferenceColor(red: 1, green: 1, blue: 1)

    private static func stepper(_ range: ClosedRange<Double>, step: Double = 1, _ unit: String) -> PreferenceControl {
        .stepper(range: range, step: step, unit: unit)
    }

    private static func popup(_ options: [(String, String)]) -> PreferenceControl {
        .popup(options.map { PreferenceOption(.string($0.0), $0.1) })
    }

    // Roughen.
    static let roughenAmount = PreferenceKey<Double>("tools.roughen.amount", "Amount", category: .object, default: 20, control: stepper(0...100, "per inch"),
                                                     help: "path-effects")
    static let roughenEdge = PreferenceKey<String>("tools.roughen.edge", "Edge", category: .object, default: "rough",
                                                   control: popup([("rough", "Rough"), ("smooth", "Smooth")]), help: "path-effects")

    // Fisheye Lens.
    static let fisheyePerspective = PreferenceKey<Double>("tools.fisheye.perspective", "Perspective", category: .object, default: 50,
                                                          control: stepper(-100...100, ""), help: "path-effects")

    // Bend.
    static let bendAmount = PreferenceKey<Double>("tools.bend.amount", "Amount", category: .object, default: 5, control: stepper(1...10, ""), help: "path-effects")

    // Smudge.
    static let smudgeFill = PreferenceKey<PreferenceColor>("tools.smudge.fill", "Fill", category: .object, default: white, control: .color, help: "path-effects")
    static let smudgeFillNone = PreferenceKey<Bool>("tools.smudge.fillNone", "Fill: None", category: .object, default: false, control: .toggle, help: "path-effects")
    static let smudgeStroke = PreferenceKey<PreferenceColor>("tools.smudge.stroke", "Stroke", category: .object, default: white, control: .color, help: "path-effects")
    static let smudgeStrokeNone = PreferenceKey<Bool>("tools.smudge.strokeNone", "Stroke: None", category: .object, default: true, control: .toggle,
                                                      help: "path-effects")

    // Shadow.
    static let shadowType = PreferenceKey<String>("tools.shadow.type", "Type", category: .object, default: "hard",
                                                  control: popup([("hard", "Hard Edge"), ("soft", "Soft Edge"), ("zoom", "Zoom")]), help: "path-effects")
    static let shadowFill = PreferenceKey<String>("tools.shadow.fill", "Fill", category: .object, default: "shade",
                                                  control: popup([("tint", "Tint"), ("shade", "Shade"), ("color", "Color")]), help: "path-effects")
    static let shadowPercent = PreferenceKey<Double>("tools.shadow.percent", "Tint or shade", category: .object, default: 50, control: stepper(0...100, "%"),
                                                     help: "path-effects")
    static let shadowColor = PreferenceKey<PreferenceColor>("tools.shadow.color", "Color", category: .object, default: PreferenceColor(red: 0.5, green: 0.5, blue: 0.5),
                                                            control: .color, help: "path-effects")
    static let shadowFadeTo = PreferenceKey<PreferenceColor>("tools.shadow.fadeTo", "Fade to", category: .object, default: white, control: .color, help: "path-effects")
    static let shadowSoftEdge = PreferenceKey<Double>("tools.shadow.softEdge", "Soft edge", category: .object, default: 50, control: stepper(0...100, ""),
                                                      help: "path-effects")
    static let shadowZoomStroke = PreferenceKey<PreferenceColor>("tools.shadow.zoomStroke", "Zoom stroke", category: .object, default: white, control: .color,
                                                                 help: "path-effects")
    static let shadowZoomFill = PreferenceKey<PreferenceColor>("tools.shadow.zoomFill", "Zoom fill", category: .object, default: white, control: .color,
                                                               help: "path-effects")
    static let shadowScale = PreferenceKey<Double>("tools.shadow.scale", "Scale", category: .object, default: 100, control: stepper(1...1000, "%"), help: "path-effects")
    static let shadowOffsetX = PreferenceKey<Double>("tools.shadow.offsetX", "Offset X", category: .object, default: 6, control: stepper(-1000...1000, "pt"),
                                                     help: "path-effects")
    static let shadowOffsetY = PreferenceKey<Double>("tools.shadow.offsetY", "Offset Y", category: .object, default: 6, control: stepper(-1000...1000, "pt"),
                                                     help: "path-effects")

    /// Each tool's sheet: the keys it lists.
    @MainActor static let sheets: [ToolID: [AnyPreferenceKey]] = [
        RoughenTool.id: [roughenAmount.erased, roughenEdge.erased],
        FisheyeLensTool.id: [fisheyePerspective.erased],
        BendTool.id: [bendAmount.erased],
        SmudgeTool.id: [smudgeFill.erased, smudgeFillNone.erased, smudgeStroke.erased, smudgeStrokeNone.erased],
        ShadowTool.id: [shadowType.erased, shadowFill.erased, shadowPercent.erased, shadowColor.erased, shadowFadeTo.erased, shadowSoftEdge.erased,
                        shadowZoomStroke.erased, shadowZoomFill.erased, shadowScale.erased, shadowOffsetX.erased, shadowOffsetY.erased],
    ]
}
