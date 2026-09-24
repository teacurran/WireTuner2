import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto

/// The Trace tool's result (IMG-023; tracing.adoc, "Tracing an area"): the traced paths as one
/// named group placed directly above the traced object, in its container -- or, when nothing was
/// under the marquee, at the top of the current layer -- in one change ("Trace").  The group's
/// paths are in pasteboard points; they are expressed in the container's space on the way in.
public struct PlaceTrace: Command {
    public var group: ImportedGroup
    /// The traced object the group goes directly above; nil places it on `layer`.
    public var above: OpID?
    /// The current layer (the drawing layer when nil or unusable).
    public var layer: OpID?
    public var label: String { "Trace" }

    public init(_ group: ImportedGroup, above: OpID? = nil, layer: OpID? = nil) {
        self.group = group
        self.above = above
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !group.children.isEmpty else { throw TraceError.nothingTraced }
        var writer = ImportWriter(state: state, link: nil, poster: nil)
        let parent: OpID
        let key: [UInt8]
        if let above, state.isLive(above), let placement = state.store.placement(above) {
            parent = placement.parent
            let siblings = state.store.children(parent)
            let next = siblings.firstIndex(of: above).flatMap { index in index + 1 < siblings.count ? siblings[index + 1] : nil }
            key = try PathEditing.keys(between: placement.position, and: next.flatMap { state.store.placement($0)?.position }, count: 1)[0]
        } else {
            let target = ImportTarget.resolve(preferred: layer, in: state)
            parent = try target.layer ?? writer.createLayer(name: "Foreground", above: nil, builder: &builder)
            key = try PathEditing.topPosition(in: parent, state: state)
        }
        let toParent = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        try writer.create(.group(group), parent: parent, position: key, placement: toParent, builder: &builder)
    }
}

/// Why a trace placed nothing.
public enum TraceError: Error, Hashable, Sendable {
    /// The trace found no paths.
    case nothingTraced
}
