import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// IMG-028: the document half of menu:Object[Image > Remove Background…] and
// menu:Object[Image > Select Subject] (bitmaps.adoc, "Removing a background", "Data model" and
// "Client").  The segmentation itself is WTRender's `SubjectMask` (IMG-027); these commands write
// its results: *Transparent image* replaces the image's pixels with the alpha PNG, *Clipping path*
// pastes the untouched image inside a path traced around the subject.

/// Which images the two commands take (bitmaps.adoc, "Removing a background"): exactly one
/// selected image, RGB, CMYK or grayscale, with its pixels on this Mac.
public enum SubjectImages {
    /// Why the commands are refused for `nodes`, or nil when they apply; `isCached` says whether an
    /// image's pixels (by asset id) are on this Mac.
    public static func refusal(_ nodes: [OpID], in state: EngineState, isCached: (String) -> Bool) -> String? {
        let images = nodes.filter { state.isLive($0) && state.nodeKind($0) == .image }
        guard !images.isEmpty else { return "Select an image" }
        guard images.count == 1, nodes.count == 1 else { return "Select one image" }
        guard !Objects.editable(images, in: state).isEmpty else { return "The image is locked" }
        let props = state.props(images[0]).image
        switch ImageNodes.mode(props.pixels.mode) {
        case .bilevel: return "Bilevel images have no subject to find"
        case .indexed: return "Indexed-color images have no subject to find"
        default: break
        }
        let asset = ImageNodes.assetID(props.pixels)
        guard !asset.isEmpty, isCached(asset) else { return "The image has not finished downloading" }
        return nil
    }

    /// The name the image shows (its source name, else its object name).
    public static func name(of node: OpID, in state: EngineState) -> String {
        let props = state.props(node).image
        return props.sourceName.isEmpty ? props.common.name : props.sourceName
    }
}

/// *Remove Background…* with *Transparent image*: the image's `pixels` replaced by `pixels` (the
/// alpha PNG, of the same dimensions, `has_alpha` set), *Display alpha channel* turned on and
/// " (background removed)" added to the source name, in one `SetFields` -- so a concurrent crop,
/// tint or transform still applies, and a concurrent pixel replacement competes by LWW.  One
/// change "Remove background from <name>", which undoes to the prior pixels.
public struct RemoveImageBackground: Command {
    public var node: OpID
    public var pixels: Wiretuner_Doc_V1_PixelSource
    public var name: String
    public var label: String { "Remove background from \(name)" }

    public static let suffix = " (background removed)"

    public init(_ node: OpID, pixels: Wiretuner_Doc_V1_PixelSource, name: String) {
        self.node = node
        self.pixels = pixels
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ImageNodes.editable([node], in: state)
        try ImageNodes.check(pixels)
        let current = SubjectImages.name(of: node, in: state)
        let renamed = current.hasSuffix(Self.suffix) ? current : current + Self.suffix
        var stored = pixels
        stored.hasAlpha_p = true
        builder.append(Ops.set(node, [ImageFields.pixels, ImageFields.displayAlpha, ImageFields.sourceName], values: ImageFields.values { image in
            image.pixels = stored
            image.displayAlpha = true
            image.sourceName = String(renamed.prefix(256))
        }))
    }
}

/// *Remove Background…* with *Clipping path*: a clip group at the image's place holding a path
/// traced around the subject (`contours`, in the image's local space, so it follows the image's
/// transform) as its clip path and the untouched image, as Paste Contents makes one (OBJ-027).
/// New nodes and one move, so it never collides with a concurrent edit of the image.  One change
/// "Clip <name> to subject".
public struct ClipImageToSubject: Command {
    public var node: OpID
    public var contours: [Contour]
    public var name: String
    public var label: String { "Clip \(name) to subject" }

    public init(_ node: OpID, contours: [Contour], name: String) {
        self.node = node
        self.contours = contours
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ImageNodes.editable([node], in: state)
        let closed = contours.filter { $0.isClosed && !$0.segments.isEmpty }
        guard !closed.isEmpty, let parent = Objects.parent(of: node, in: state) else { throw ImageEditError.invalidValue("contours") }
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.kind = .clip
        group.group.common.name = "Clipped \(name)"
        let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
        let clipGroup = builder.append(Ops.create(parent: parent, position: key, props: group))
        let keys = try PathEditing.keys(between: nil, and: nil, count: 2)
        var writer = ImportWriter(state: state, link: nil, poster: nil)
        let imported = closed.map { contour in
            ImportedContour(start: contour.segments[0].p0, segments: contour.segments.map { .cubic(control1: $0.p1, control2: $0.p2, to: $0.p3) },
                            closed: true)
        }
        let path = try writer.create(.path(ImportedPath(contours: imported, fillRule: .evenOdd, name: "Subject of \(name)")), parent: clipGroup,
                                     position: keys[0], placement: Objects.transform(of: node, in: state), builder: &builder)
        builder.append(Ops.move(node, parent: clipGroup, position: keys[1]))
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.clipPath.id = path.proto
        builder.append(Ops.set(clipGroup, [ClipGroups.clipPathField], values: clip))
    }
}
