import Foundation
import WTCRDT
import WTInterchange
import WTProto

/// The Object panel's poster scrubber (WEB-027): the frame at `timeMs`, rendered by the app, becomes
/// the poster -- a new asset for the PNG and `poster_time_ms` with `poster` in the same change, one
/// undo step ("Poster Frame").  A frame whose PNG an asset already holds reuses that asset.
public struct SetSvgAnimationPosterFrame: Command {
    public var node: OpID
    public var timeMs: UInt64
    public var png: ImportedBlob
    public var label: String { "Poster Frame" }

    public init(_ node: OpID, timeMs: UInt64, png: ImportedBlob) {
        self.node = node
        self.timeMs = timeMs
        self.png = png
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(node), state.store.kind(node) == SvgAnimationFields.kind else { throw SvgAnimationError.notAnAnimation(node) }
        let existing = state.liveChildren(WellKnown.assets).first { state.props($0).asset.sha256 == png.sha256 }
        var writer = ImportWriter(state: state, link: nil, poster: nil)
        let asset = try existing ?? writer.asset(png, name: "Poster", link: nil, builder: &builder)
        let values = SvgAnimationFields.values {
            $0.posterTimeMs = timeMs
            $0.poster.id = asset.proto
        }
        builder.append(Ops.set(node, [SvgAnimationFields.posterTimeMs, SvgAnimationFields.poster], values: values))
    }
}
