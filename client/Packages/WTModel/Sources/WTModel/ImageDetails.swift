import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// IMG-016: what the Object panel's image section shows for one image (bitmaps.adoc, "Image
// properties in the Object panel"), read from the document on every render.  The section itself
// is WTApp's; the readings and the scale arithmetic are here.

/// One image as the Object panel's image section reads it.
public struct ImageDetails: Equatable, Sendable {
    public var node: OpID
    public var mode: ImageMode
    public var hasAlpha: Bool
    public var bitsPerChannel: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The file the image came from, or "Pasted" when it names none.
    public var file: String
    /// *Stored* resolution, ppi (0 reads as 72).
    public var dpiX: Double
    public var dpiY: Double
    /// The image's current scale relative to its natural size, each axis (through its transform
    /// chain).
    public var scaleX: Double
    public var scaleY: Double
    /// The natural frame, local space.
    public var natural: Rect
    public var displayAlpha: Bool
    public var transparent: Bool
    public var ramp: GrayRamp
    public var tint: Wiretuner_Doc_V1_ColorRef?
    /// The crop that applies, unit space (the whole picture when uncropped).
    public var crop: Rect
    public var isCropped: Bool
    /// Whether the blob names a picture yet (a placeholder being edited has none).
    public var hasPixels: Bool

    public init?(_ node: OpID, in state: EngineState) {
        guard case .image(let props)? = state.props(node).kind else { return nil }
        let pixels = props.pixels
        self.node = node
        mode = ImageNodes.mode(pixels.mode)
        hasAlpha = pixels.hasAlpha_p
        bitsPerChannel = Int(pixels.bitsPerChannel)
        pixelWidth = Int(pixels.pixelWidth)
        pixelHeight = Int(pixels.pixelHeight)
        file = props.sourceName.isEmpty ? "Pasted" : props.sourceName
        dpiX = props.dpiX > 0 && props.dpiX.isFinite ? props.dpiX : 72
        dpiY = props.dpiY > 0 && props.dpiY.isFinite ? props.dpiY : 72
        let transform = Objects.pasteboardTransform(of: node, in: state)
        scaleX = (transform.a * transform.a + transform.b * transform.b).squareRoot()
        scaleY = (transform.c * transform.c + transform.d * transform.d).squareRoot()
        natural = ImageNodes.naturalRect(props)
        displayAlpha = props.displayAlpha
        transparent = props.transparentBackground
        ramp = ImageNodes.ramp(props.ramp)
        tint = props.hasTint ? props.tint : nil
        let effective = ImageNodes.item(props, transform: .identity).effectiveCrop
        crop = effective ?? ImageCropping.full
        isCropped = effective != nil
        hasPixels = pixels.blobSha256.count == 32
    }

    /// The name of a colour mode.
    public static func name(_ mode: ImageMode) -> String {
        switch mode {
        case .bilevel: "Bilevel"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "RGB"
        case .cmyk: "CMYK"
        }
    }

    /// "Image (Grayscale)".
    public var kindLabel: String { "Image (\(Self.name(mode)))" }

    /// "1500 × 1000, 8-bit".
    public var pixelsText: String { "\(pixelWidth) × \(pixelHeight), \(bitsPerChannel)-bit" }

    /// *Color mode*: "RGB", "Grayscale, alpha".
    public var modeText: String { Self.name(mode) + (hasAlpha ? ", alpha" : "") }

    /// Whether the mode-gated settings (*Transparent*, the ramp, the tint) apply.
    public var isGray: Bool { mode == .bilevel || mode == .grayscale }

    /// *Effective* resolution: stored over scale, per axis; the lower of the two is the one that
    /// matters for print.
    public var effectivePPI: Double {
        let x = scaleX > 0 ? dpiX / scaleX : dpiX
        let y = scaleY > 0 ? dpiY / scaleY : dpiY
        return min(x, y)
    }

    /// Whether the effective resolution falls below `threshold` ppi (the amber warning).
    public func isBelow(_ threshold: Double) -> Bool { effectivePPI < threshold }

    /// The placed size of the visible part, points (natural × crop × scale).
    public var placedSize: Size {
        Size(width: natural.width * crop.width * scaleX, height: natural.height * crop.height * scaleY)
    }

    /// The crop in pixels of the current picture: left, top, width, height.
    public var cropPixels: Rect { ImageCropping.pixels(crop, width: pixelWidth, height: pixelHeight) }

    /// The factors that take the image to `percent` of its natural size on the axes asked for
    /// (both with the lock on): relative to its current scale, 1 on an axis left alone.  Nil for
    /// a non-positive percentage or an image with no scale.
    public func scaleFactors(toPercent percent: Double, horizontal: Bool, vertical: Bool) -> (x: Double, y: Double)? {
        guard percent > 0, percent.isFinite, scaleX > 0, scaleY > 0 else { return nil }
        let target = percent / 100
        return (horizontal ? target / scaleX : 1, vertical ? target / scaleY : 1)
    }

    /// The factors that make the placed width (or height) `points`, the other axis following
    /// when `locked`.
    public func scaleFactors(toSize points: Double, width: Bool, locked: Bool) -> (x: Double, y: Double)? {
        let current = width ? placedSize.width : placedSize.height
        guard points > 0, points.isFinite, current > 0 else { return nil }
        let factor = points / current
        if locked { return (factor, factor) }
        return width ? (factor, 1) : (1, factor)
    }
}

/// The *Image Info…* popover's lines (bitmaps.adoc, "Image information"): label and value.
public enum ImageInfoLines {
    public static func lines(_ details: ImageDetails, format: String, profile: String?, fileSize: Int?, placedBy: String?) -> [(String, String)] {
        var lines: [(String, String)] = [
            ("File", details.file),
            ("Format", format.isEmpty ? "Unknown" : format),
            ("Pixels", "\(details.pixelWidth) × \(details.pixelHeight)"),
            ("Stored resolution", ppi(details.dpiX, details.dpiY)),
            ("Effective resolution", "\(Int(details.effectivePPI.rounded())) ppi"),
            ("Color mode", "\(ImageDetails.name(details.mode)), \(details.bitsPerChannel)-bit"),
            ("Alpha", details.hasAlpha ? "Yes" : "No"),
            ("Color profile", profile ?? "None embedded"),
        ]
        if let fileSize { lines.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))) }
        lines.append(("Placed by", placedBy ?? "You"))
        return lines
    }

    static func ppi(_ x: Double, _ y: Double) -> String {
        let rx = Int(x.rounded()), ry = Int(y.rounded())
        return rx == ry ? "\(rx) ppi" : "\(rx) × \(ry) ppi"
    }
}
