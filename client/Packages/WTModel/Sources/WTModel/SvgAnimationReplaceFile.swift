import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender

// WEB-027: the SVG Animation section's btn:[Replace…] and btn:[Edit With…] (svg-animation.adoc,
// "SVG animation attributes in the Object panel"): another file -- chosen, or saved by the external
// editor -- takes the animation's place keeping its position, size and settings.

/// Replaces an SVG animation's file: the file's asset (reused when the document already holds the
/// same bytes), its natural size, duration, mechanisms and poster (a PNG asset, when one was
/// rendered), and the transform scaled so the animation keeps its size on the pasteboard.  The web
/// settings stay.  Labelled "Replace SVG animation".
public struct ReplaceSvgAnimationFile: Command {
    public var node: OpID
    public var file: ImportedPlacedFile
    public var poster: ImportedPoster?
    public var label: String { "Replace SVG animation" }

    public init(_ node: OpID, file: ImportedPlacedFile, poster: ImportedPoster? = nil) {
        self.node = node
        self.file = file
        self.poster = poster
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.isLive(node), state.store.kind(node) == SvgAnimationFields.kind, let info = SvgAnimationInfo(node, in: state) else {
            throw SvgAnimationError.notAnAnimation(node)
        }
        guard case .svgAnimation(let css, let smil, let script, let durationMs) = file.kind, file.bounds.width > 0, file.bounds.height > 0 else {
            throw SvgAnimationError.notAnAnimation(node)
        }
        func asset(_ blob: ImportedBlob, name: String) throws -> OpID {
            if let existing = state.liveChildren(WellKnown.assets).first(where: { state.props($0).asset.sha256 == blob.sha256 }) { return existing }
            var writer = ImportWriter(state: state, link: nil, poster: nil)
            return try writer.asset(blob, name: name, link: nil, builder: &builder)
        }
        let svg = try asset(file.blob, name: file.name ?? "Animation")
        let posterAsset = try poster.map { try asset($0.blob, name: "Poster") }
        let natural = Size(width: file.bounds.width, height: file.bounds.height)
        let replacement = SvgAnimationFile(asset: svg, naturalSize: natural, durationMs: durationMs, kinds: SvgAnimationKinds(css: css, smil: smil, script: script),
                                           posterTimeMs: poster?.timeMs ?? 0, poster: posterAsset)
        // Keep the placed size: scale the transform by the old natural size over the new.
        let old = info.naturalSize
        let transform = AffineTransform.scale(x: old.width / natural.width, y: old.height / natural.height).concatenating(info.transform)
        var paths = [SvgAnimationFields.asset, SvgAnimationFields.naturalSize, SvgAnimationFields.durationMs, SvgAnimationFields.kinds,
                     SvgAnimationFields.posterTimeMs, SvgAnimationFields.poster]
        paths.append(SvgAnimationFields.transform)
        builder.append(Ops.set(node, paths, values: SvgAnimationFields.values { props in
            replacement.write(into: &props)
            props.common.transform = PathEditing.proto(transform)
        }))
    }
}
