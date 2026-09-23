// The barcode object (DATA-018; docs/_includes/automation/data-merge.adoc, "Barcodes"):
// drawn from its value as vector rectangles -- one per dark module (QR) or bar (Code 128) --
// so PDF and print carry rectangles, never an image.  Natural size is one module = 1 pt (QR)
// or one narrow bar = 1 pt (Code 128) including the quiet zone, then the object's transform.
// The bars take the node's first fill; the background is clear.  Hit testing is the bounds
// rectangle.  A value the symbology cannot encode draws the hatched placeholder.

import WTGeometry

/// `BarcodeSymbology`.
public enum BarcodeSymbology: Hashable, Sendable {
    case qr
    case code128
}

/// A barcode as WTModel reads it (`BarcodeProps`, with a bound field's value substituted).
public struct BarcodeSpec: Hashable, Sendable {
    public var symbology: BarcodeSymbology
    public var value: String
    public var errorCorrection: QRErrorCorrection
    /// Modules (QR, default 4) or points (Code 128, default 10); negative reads as the default.
    public var quietZone: Double?
    /// Code 128: the value in `textFont` under the bars.
    public var showText: Bool
    /// The first fill's paint.
    public var paint: Paint
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(symbology: BarcodeSymbology = .qr, value: String, errorCorrection: QRErrorCorrection = .medium, quietZone: Double? = nil, showText: Bool = false, paint: Paint = .solid(.black), transform: AffineTransform = .identity) {
        self.symbology = symbology
        self.value = value
        self.errorCorrection = errorCorrection
        self.quietZone = quietZone
        self.showText = showText
        self.paint = paint
        self.transform = transform
    }

    /// The quiet zone in local units.
    public var effectiveQuietZone: Double {
        let fallback = symbology == .qr ? 4.0 : 10.0
        guard let quietZone, quietZone.isFinite, quietZone >= 0 else {
            return fallback
        }
        return quietZone
    }
}

/// A barcode's vector geometry in local units.
public struct BarcodeGeometry: Hashable, Sendable {
    /// Every dark module or bar, merged along rows for QR (each rectangle is still whole
    /// modules).
    public var rectangles: [Rect]
    /// The symbol and its quiet zone: the hit rectangle.
    public var bounds: Rect
    /// Code 128 with *Show text*: where the text's baseline centre is.
    public var textAnchor: Point?
}

public enum BarcodeRendering {
    /// Code 128 bars are this tall: 15% of the symbol's width, at least a quarter inch.
    public static func barHeight(forWidth width: Double) -> Double {
        max(18, (width * 0.15).rounded())
    }

    /// The gap between the bars and the human-readable line.
    public static let textGap = 2.0

    /// The geometry of `spec`, or the reason it cannot be encoded.
    public static func geometry(_ spec: BarcodeSpec, typesetter: LabelTypesetter? = nil) -> Result<BarcodeGeometry, Error> {
        let quiet = spec.effectiveQuietZone
        switch spec.symbology {
        case .qr:
            do {
                let code = try QRCode.encode(spec.value, level: spec.errorCorrection)
                var rectangles: [Rect] = []
                for y in 0..<code.size {
                    var x = 0
                    while x < code.size {
                        guard code.isDark(x: x, y: y) else {
                            x += 1
                            continue
                        }
                        let start = x
                        while x < code.size && code.isDark(x: x, y: y) {
                            x += 1
                        }
                        rectangles.append(Rect(x: quiet + Double(start), y: quiet + Double(y), width: Double(x - start), height: 1))
                    }
                }
                let edge = Double(code.size) + 2 * quiet
                return .success(BarcodeGeometry(rectangles: rectangles, bounds: Rect(x: 0, y: 0, width: edge, height: edge), textAnchor: nil))
            } catch {
                return .failure(error)
            }
        case .code128:
            do {
                let code = try Code128(spec.value)
                let symbolWidth = Double(code.moduleWidth)
                let height = barHeight(forWidth: symbolWidth)
                let rectangles = code.bars.map { Rect(x: quiet + Double($0.start), y: 0, width: Double($0.width), height: height) }
                var bounds = Rect(x: 0, y: 0, width: symbolWidth + 2 * quiet, height: height)
                var anchor: Point?
                if spec.showText, let typesetter {
                    anchor = Point(x: bounds.midX, y: height + textGap + typesetter.ascent)
                    bounds = Rect(x: 0, y: 0, width: bounds.width, height: height + textGap + typesetter.lineHeight)
                }
                return .success(BarcodeGeometry(rectangles: rectangles, bounds: bounds, textAnchor: anchor))
            } catch {
                return .failure(error)
            }
        }
    }

    /// The barcode as one atomic group: a clear hit rectangle over its bounds, the bars as one
    /// path of rectangles in its paint, and the human-readable line; or the placeholder.
    public static func item(_ spec: BarcodeSpec, typesetter: LabelTypesetter = CoreTextLabels(font: GlyphFont(postScriptName: "Helvetica", size: 8))) -> DisplayItem {
        switch geometry(spec, typesetter: typesetter) {
        case .failure:
            let edge = spec.symbology == .qr ? 29.0 : 60.0
            return HatchedPlaceholder.item(rect: Rect(x: 0, y: 0, width: edge, height: spec.symbology == .qr ? edge : 30), name: "", transform: spec.transform)
        case .success(let geometry):
            var bars = DisplayPath()
            for rect in geometry.rectangles {
                bars.elements += DisplayPath(rect: rect).elements
            }
            var children: [DisplayItem] = [
                .path(PathItem(path: DisplayPath(rect: geometry.bounds), appearance: Appearance([.fill(FillPaint(paint: .solid(.clear)))]), transform: spec.transform)),
                .path(PathItem(path: bars, appearance: Appearance([.fill(FillPaint(paint: spec.paint))]), transform: spec.transform)),
            ]
            if let anchor = geometry.textAnchor {
                children += typesetter.label(spec.value, at: anchor, alignment: .center, color: spec.paint.color ?? .black).map { $0.transformed(by: spec.transform) }
            }
            var group = GroupItem(children: children)
            group.atomic = true
            return .group(group)
        }
    }

    /// *Convert to Paths*: the bars as rectangles in pasteboard space (WTModel writes them as a
    /// `path` group).
    public static func paths(_ spec: BarcodeSpec) -> [DisplayPath] {
        guard case .success(let geometry) = geometry(spec) else {
            return []
        }
        return geometry.rectangles.map { DisplayPath(rect: $0).applying(spec.transform) }
    }
}
