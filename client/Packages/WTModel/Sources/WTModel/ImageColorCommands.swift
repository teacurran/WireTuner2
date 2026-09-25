import WTCRDT
import WTGeometry
import WTProto
import WTRender

// CMS-013: an image's colour interpretation (image-color.adoc): its source profile and intent,
// assigned -- never converted -- from the Object panel's Image section.  `source_profile`,
// `intent` and `use_embedded` are separate registers, so an assignment and an intent change, or a
// switch back to the embedded profile and an assignment, both survive a merge.

/// The registers of `ImageProps.color` (field 11).
public enum ImageColorFields {
    public static let sourceProfile = RegisterPath([ImageFields.kind, 11, 1])
    public static let intent = RegisterPath([ImageFields.kind, 11, 2])
    public static let useEmbedded = RegisterPath([ImageFields.kind, 11, 3])

    static func values(_ build: (inout Wiretuner_Doc_V1_ImageColorSettings) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        ImageFields.values { build(&$0.color) }
    }
}

/// What an image's *Source profile* menu chooses.
public enum ImageSourceChoice: Hashable, Sendable {
    /// The profile inside the file (only when it has one).
    case embedded
    /// The document default for the image's model.
    case documentDefault
    /// A bundled, document or installed profile.
    case profile(WTColor.ProfileRef)
}

/// How an image's colour reads now: its model, the embedded profile, the effective source choice
/// and the intent (nil: the document's), with the read-time normalizations applied.
public struct ImageColorInfo: Hashable, Sendable {
    public var mode: ImageMode
    public var embedded: WTColor.ProfileRef?
    public var source: ImageSourceChoice
    public var intent: WTColor.RenderingIntent?

    public init?(_ node: OpID, in state: EngineState, registry: WTColor.ProfileRegistry = .shared) {
        guard state.nodeKind(node) == .image, case .image(let image)? = state.props(node).kind else { return nil }
        let color = image.color
        mode = ImageNodes.mode(image.pixels.mode)
        embedded = color.hasEmbeddedProfile ? ColorSettings.profile(color.embeddedProfile, registry: registry) : nil
        if color.useEmbedded, embedded != nil {
            source = .embedded
        } else if color.hasSourceProfile, let profile = ColorSettings.profile(color.sourceProfile, registry: registry) {
            source = .profile(profile)
        } else {
            source = .documentDefault
        }
        intent = color.intent == .unspecified ? nil : ColorSettings.intent(color.intent)
    }

    /// The profile space the image's pixels are in (gray for bilevel and grayscale, CMYK, else RGB).
    public var space: WTColor.ProfileSpace {
        switch mode {
        case .cmyk: .cmyk
        case .grayscale, .bilevel: .gray
        default: .rgb
        }
    }
}

/// Assigns images' source profile: the embedded one (`use_embedded` only, so a profile assigned
/// before is kept for later), the document default (`source_profile` unset) or a named one (each
/// turning `use_embedded` off where it is on).  One change over every image, "Assign Image
/// Profile".
public struct SetImageSourceProfile: Command {
    public var nodes: [OpID]
    public var choice: ImageSourceChoice

    public init(_ nodes: [OpID], _ choice: ImageSourceChoice) {
        self.nodes = nodes
        self.choice = choice
    }

    public var label: String { ImageNodes.label("Assign Image Profile", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in try ImageNodes.editable(nodes, in: state) {
            switch choice {
            case .embedded:
                builder.append(Ops.set(node, [ImageColorFields.useEmbedded], values: ImageColorFields.values { $0.useEmbedded = true }))
            case .documentDefault, .profile:
                // `use_embedded` is written (false) only when it is on: a concurrent switch back to
                // the embedded profile then wins with this assignment retained beneath it.
                let embedded = state.props(node).image.color.useEmbedded
                let paths = embedded ? [ImageColorFields.sourceProfile, ImageColorFields.useEmbedded] : [ImageColorFields.sourceProfile]
                builder.append(Ops.set(node, paths, values: ImageColorFields.values {
                    if case .profile(let profile) = choice { $0.sourceProfile = ColorSettings.stored(profile) }
                }))
            }
        }
    }
}

/// Images' rendering intent (nil: the document's).  One change, "Change Image Intent".
public struct SetImageIntent: Command {
    public var nodes: [OpID]
    public var intent: WTColor.RenderingIntent?

    public init(_ nodes: [OpID], intent: WTColor.RenderingIntent?) {
        self.nodes = nodes
        self.intent = intent
    }

    public var label: String { ImageNodes.label("Change Image Intent", count: nodes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in try ImageNodes.editable(nodes, in: state) {
            builder.append(Ops.set(node, [ImageColorFields.intent], values: ImageColorFields.values {
                if let intent { $0.intent = ColorSettings.stored(intent) }
            }))
        }
    }
}
