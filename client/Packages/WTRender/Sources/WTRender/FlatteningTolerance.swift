// The one curve-flattening tolerance both renderers call (docs/spec/client.adoc, "The display
// list").  It is a distance in device pixels; at a given view scale that is a distance in
// pasteboard units, which is what a flattener working on display-list geometry needs.

/// How far a flattened polyline may stray from the true curve.
import WTGeometry

public struct FlatteningTolerance: Hashable, Sendable {
    /// A quarter device pixel: below the anti-aliasing noise floor, well under Core Graphics'
    /// default flatness of 0.6 so the two renderers do not disagree about a curve's edge.
    public static let standard = FlatteningTolerance(devicePixels: 0.25)

    /// The tolerance in device pixels.
    public let devicePixels: Double

    public init(devicePixels: Double) {
        self.devicePixels = max(devicePixels, 1e-6)
    }

    /// The tolerance in pasteboard units at `scale` device pixels per pasteboard unit.
    public func pasteboardUnits(atScale scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else {
            return devicePixels
        }
        return devicePixels / scale
    }

    /// The tolerance in pasteboard units for tiles of `geometry`.
    public func pasteboardUnits(for geometry: TileGeometry) -> Double {
        pasteboardUnits(atScale: geometry.zoomStep.scale)
    }

    /// The tolerance in pasteboard units for `viewport` on a display with `backingScale`
    /// device pixels per view point.
    public func pasteboardUnits(for viewport: Viewport, backingScale: Double) -> Double {
        pasteboardUnits(atScale: viewport.zoom * backingScale)
    }
}
