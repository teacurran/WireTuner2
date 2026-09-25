// Placed SVG animations for web output (web/svg-animation.adoc, "SVG animations in output";
// WEB-008 with WEB-024's `svg_animation` node): the file's bytes, its placement and its *On the
// web* settings, carried by the export snapshot.  The display list draws the node's poster; the
// HTML publisher replaces that poster with the animation itself unless *Poster only* is chosen.

import Foundation
import WTGeometry

/// One placed SVG animation.
public struct ExportSVGAnimation: Hashable, Sendable {
    /// `SvgAnimationWebProps.loop`.
    public enum Loop: Hashable, Sendable {
        case asFile
        case loop
        case once
    }

    /// The SVG file, uncompressed (a `.svgz` is inflated by the caller).
    public var data: Data
    /// The natural size in points (`natural_size`).
    public var width: Double
    public var height: Double
    /// Natural-size points → pasteboard (`CommonProps.transform`).
    public var transform: AffineTransform
    /// `SvgAnimationKinds.script`: the file holds `<script>` or event attributes.
    public var script: Bool
    /// Plays when the page loads (`!no_autoplay`).
    public var autoplay: Bool
    public var loop: Loop
    /// Starts when the pointer enters.
    public var playOnHover: Bool

    public init(data: Data, width: Double, height: Double, transform: AffineTransform = .identity, script: Bool = false, autoplay: Bool = true,
                loop: Loop = .asFile, playOnHover: Bool = false) {
        self.data = data
        self.width = width
        self.height = height
        self.transform = transform
        self.script = script
        self.autoplay = autoplay
        self.loop = loop
        self.playOnHover = playOnHover
    }
}
