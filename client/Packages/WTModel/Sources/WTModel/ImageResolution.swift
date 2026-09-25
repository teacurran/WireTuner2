import Foundation
import WTCRDT
import WTGeometry
import WTProto

/// Resolution of placed images and kbd:[Option]-drag resizing in printer-resolution steps (the
/// remainder of IMG-004 that IMG-017 names; bitmaps.adoc "Resizing and transforming").  The
/// effective resolution of an image is its pixel width over its placed width in inches; a resize
/// with kbd:[Option] held snaps the scale so the effective resolution stays in step with the
/// document's printer resolution, avoiding the moiré and softness of an uneven scale on halftoned
/// output.
///
/// The steps: s₀ is the largest scale not above 100% (of the image's natural size, its pixels at
/// its own dpi) at which the effective resolution is a whole-number fraction of the printer
/// resolution (printer / m); the steps are s₀ divided or multiplied by whole numbers.  A 300 ppi
/// image on a 600 dpi document has s₀ = 100% (300 = 600 / 2) and snaps to 100%, 50%, 33.3%, 25%
/// ... and 200%, 300% ...  This is pure: the Pointer tool asks it for the snapped scale of each
/// drag event and writes the transform as any resize does.
public enum ImageResolution {
    /// The image node's natural resolution (its `dpi_x`; 0 reads as 72).
    public static func naturalPPI(of node: OpID, in state: EngineState) -> Double? {
        guard case .image(let props)? = state.props(node).kind else { return nil }
        return props.dpiX > 0 && props.dpiX.isFinite ? props.dpiX : 72
    }

    /// The image's current scale relative to its natural size along its x axis (through its
    /// transform chain, so a scaled group counts).
    public static func scale(of node: OpID, in state: EngineState) -> Double? {
        guard case .image? = state.props(node).kind else { return nil }
        let transform = Objects.pasteboardTransform(of: node, in: state)
        return (transform.a * transform.a + transform.b * transform.b).squareRoot()
    }

    /// The effective resolution as placed: natural ppi over scale.
    public static func effectivePPI(of node: OpID, in state: EngineState) -> Double? {
        guard let ppi = naturalPPI(of: node, in: state), let scale = scale(of: node, in: state), scale > 0 else { return nil }
        return ppi / scale
    }

    /// s₀: the largest scale ≤ 1 at which `ppi / scale` equals `printer / m` for a whole m (100%
    /// for an image finer than the printer, where no such scale exists).
    public static func baseScale(ppi: Double, printer: Double) -> Double {
        guard ppi > 0, printer > 0, ppi.isFinite, printer.isFinite else { return 1 }
        // scale = m · ppi / printer ≤ 1  →  m = ⌊printer / ppi⌋ (at least 1).
        let m = max(1, (printer / ppi).rounded(.down))
        let scale = m * ppi / printer
        return scale <= 1 ? scale : 1
    }

    /// The printer-resolution step nearest `proposed` (a scale relative to natural size), for an
    /// image of `ppi` on a document printing at `printer` dpi.  Non-positive or non-finite
    /// proposals answer the base step.
    public static func snapped(_ proposed: Double, ppi: Double, printer: Double) -> Double {
        let base = baseScale(ppi: ppi, printer: printer)
        guard proposed > 0, proposed.isFinite else { return base }
        if proposed >= base {
            let k = max(1, (proposed / base).rounded())
            return base * k
        }
        // Between base/(k+1) and base/k: the nearer of the two.
        let k = max(1, (base / proposed).rounded(.down))
        let upper = base / k, lower = base / (k + 1)
        return proposed - lower < upper - proposed ? lower : upper
    }

    /// The snapped scale for `node` in `state` (its natural ppi and the document's printer
    /// resolution); nil when `node` is not an image.
    public static func snapped(_ proposed: Double, for node: OpID, in state: EngineState) -> Double? {
        guard let ppi = naturalPPI(of: node, in: state) else { return nil }
        return snapped(proposed, ppi: ppi, printer: Double(DocumentSettings(state).printerResolution))
    }
}
