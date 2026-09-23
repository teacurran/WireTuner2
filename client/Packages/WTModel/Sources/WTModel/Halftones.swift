import WTCRDT
import WTProto
import WTRender

/// Effective object screens for the in-app screener (halftones.adoc, "Client"; PRINT-009 model
/// half): each top-level object's own `CommonProps.halftone`, with *Default* parts inherited from
/// the plate's screen -- an unset shape takes the plate's shape, a frequency of 0 or outside
/// 1...600 the plate's frequency -- and a screen whose shape and frequency are both inherited
/// read as no object screen.  With *Ignore object screens* there are none.
///
/// The screener assigns screens per top-level item, so a group's screen covers its members; a
/// member's own screen inside a group is not separable (WTRender's `ScreenAssignment` would need
/// member-level spans).
public enum Halftones {
    public static func objectScreens(_ scene: DocumentScene, in state: EngineState, plate: HalftoneScreen,
                                     ignoreObjectHalftones: Bool = false) -> [NodeID: HalftoneScreen] {
        guard !ignoreObjectHalftones else { return [:] }
        var result: [NodeID: HalftoneScreen] = [:]
        for node in scene.topLevel {
            guard let common = NodeValues.common(state.props(OpID(node))), common.hasHalftone,
                  let screen = screen(common.halftone, plate: plate) else { continue }
            result[node] = screen
        }
        return result
    }

    /// `halftone` resolved against `plate`; nil when it inherits everything.
    public static func screen(_ halftone: Wiretuner_Doc_V1_Halftone, plate: HalftoneScreen) -> HalftoneScreen? {
        let shapes: [Wiretuner_Doc_V1_HalftoneShape: HalftoneShape] = [
            .round: .round, .ellipse: .ellipse, .line: .line, .diamond: .diamond, .square: .square, .cross: .cross,
        ]
        let shape = shapes[halftone.shape]
        let frequency = halftone.frequency.isFinite && (1...600).contains(halftone.frequency) ? halftone.frequency : nil
        guard shape != nil || frequency != nil else { return nil }
        return HalftoneScreen(shape: shape ?? plate.shape, angle: halftone.angle, frequency: frequency ?? plate.frequency)
    }
}
