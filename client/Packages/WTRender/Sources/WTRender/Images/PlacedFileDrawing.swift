// Drawing a placed file (IMG-011; docs/_includes/imported/import-formats.adoc, "EPS" and
// "Read-time normalizations").  A placed EPS shows its preview -- a PNG blob drawn like an
// image, scaled into the file's bounding box -- and, when it has no preview or the preview's
// pixels are not in the blob cache, a gray box of the bounding box's size with the file's name.
// The box is the image item's fallback, so both renderers switch to it by themselves whenever
// the pixels cannot draw (missing, downloading, decoding or unreadable), and PDF output draws
// the preview too: the PostScript itself only reaches a PostScript printer, which WireTuner
// never drives directly (output-devices.adoc).

import WTGeometry

/// A `placed_file` node as the renderers need it: `PlacedFileContent` and the node's transform.
public struct PlacedFile: Hashable, Sendable {
    /// The file's bounding box in points (its natural size and origin, local space).
    public var bounds: Rect
    /// The preview blob (hex SHA-256), nil when the file carries none.
    public var previewAssetID: String?
    /// The preview's pixel size (`preview_width`, `preview_height`); informational only, since
    /// the preview is always drawn scaled into `bounds`.
    public var previewWidth: Int
    public var previewHeight: Int
    /// `source_name`: the gray box's label.
    public var name: String
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(bounds: Rect, previewAssetID: String? = nil, previewWidth: Int = 0, previewHeight: Int = 0, name: String = "", transform: AffineTransform = .identity) {
        self.bounds = bounds
        self.previewAssetID = previewAssetID
        self.previewWidth = previewWidth
        self.previewHeight = previewHeight
        self.name = name
        self.transform = transform
    }

    /// The bounds as drawn: a box of zero (or not finite) area reads as 1 × 1 inch at its
    /// origin so the node stays selectable (import-formats.adoc, "Read-time normalizations").
    public var effectiveBounds: Rect {
        let finite = [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
        guard finite, bounds.width > 0, bounds.height > 0 else {
            return Rect(x: finite ? bounds.minX : 0, y: finite ? bounds.minY : 0, width: 72, height: 72)
        }
        return bounds
    }
}

public enum PlacedFileDrawing {
    /// The gray box's fill, its 1 pt border (drawn inside the box) and its label.
    public static let boxFill = Color(white: 0.85)
    public static let boxBorder = Color(white: 0.5)
    public static let labelColor = Color(white: 0.3)
    /// The label's inset from the box's top-left corner.
    public static let labelInset = 4.0
    /// Helvetica 10 pt, shaped once per name.
    public static let labels: LabelTypesetter = CoreTextLabels(font: GlyphFont(postScriptName: "Helvetica", size: 10))

    /// The node's display item: the preview as an image over the (normalized) bounds with the
    /// gray box as its fallback, or the gray box alone when the file has no preview.
    public static func item(_ placed: PlacedFile, typesetter: LabelTypesetter = labels) -> DisplayItem {
        let bounds = placed.effectiveBounds
        let box = grayBox(bounds, name: placed.name, typesetter: typesetter)
        guard let preview = placed.previewAssetID, !preview.isEmpty else {
            return box.transformed(by: placed.transform)
        }
        return .image(ImageItem(assetID: preview, rect: bounds, transform: placed.transform, mode: .rgb, hasAlpha: true, name: placed.name, fallback: box))
    }

    /// The gray box over `rect` (local space): the fill, a 1 pt border inside the edge and the
    /// name in one line from the top-left corner, clipped to the box.  One atomic group, so it
    /// is hit tested and selected as its rectangle.
    public static func grayBox(_ rect: Rect, name: String, typesetter: LabelTypesetter = labels) -> DisplayItem {
        let outline = DisplayPath(rect: rect)
        var children: [DisplayItem] = [.path(PathItem(path: outline, appearance: Appearance([.fill(FillPaint(paint: .solid(boxFill)))])))]
        // The border is a 1 pt ring -- the inner edge wound against the outer, so either fill
        // rule leaves the hole -- and nothing paints outside the box.
        let inset = min(1, rect.width / 2, rect.height / 2)
        let inner = Rect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - 2 * inset, height: rect.height - 2 * inset)
        var ring = outline
        ring.elements += DisplayPath(polygon: [
            Point(x: inner.minX, y: inner.minY), Point(x: inner.minX, y: inner.maxY), Point(x: inner.maxX, y: inner.maxY), Point(x: inner.maxX, y: inner.minY),
        ]).elements
        children.append(.path(PathItem(path: ring, appearance: Appearance([.fill(FillPaint(paint: .solid(boxBorder)))]))))
        let baseline = Point(x: rect.minX + labelInset, y: rect.minY + labelInset + typesetter.ascent)
        let label = typesetter.label(name, at: baseline, alignment: .leading, color: labelColor)
        if !label.isEmpty {
            children.append(.group(GroupItem(children: label, clip: outline)))
        }
        var group = GroupItem(children: children)
        group.atomic = true
        return .group(group)
    }
}
