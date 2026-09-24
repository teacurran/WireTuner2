import WTCRDT
import WTProto

/// The Animation panel's *Background* (animation.adoc, "Animation settings and preview"): the
/// colour behind every frame in exported files.  An unset register reads as *Page color*.
public enum AnimationFrameBackground: Hashable, Sendable, CaseIterable {
    case pageColor, white, transparent

    public init(_ stored: Wiretuner_Doc_V1_AnimationBackground) {
        switch stored {
        case .white: self = .white
        case .transparent: self = .transparent
        default: self = .pageColor
        }
    }

    var stored: Wiretuner_Doc_V1_AnimationBackground {
        switch self {
        case .pageColor: .pageColor
        case .white: .white
        case .transparent: .transparent
        }
    }

    /// The document's choice.
    public static func current(in state: EngineState) -> AnimationFrameBackground {
        AnimationFrameBackground(state.props(WellKnown.settings).settings.animation.background)
    }
}

/// Writes the animation *Background* (one register, "Animation Settings").  Like
/// `SetAnimationSettings`, the first write of the settings message also writes `loop = true`, so an
/// untouched document's looping survives the message becoming written.
public struct SetAnimationBackground: Command {
    public var background: AnimationFrameBackground
    public var label: String { "Animation Settings" }

    public init(_ background: AnimationFrameBackground) {
        self.background = background
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.settings.animation.background = background.stored
        var paths = [AnimationFields.background]
        if !state.props(WellKnown.settings).settings.hasAnimation {
            props.settings.animation.loop = true
            paths.append(AnimationFields.loop)
        }
        builder.append(Ops.set(WellKnown.settings, paths, values: props))
    }
}
