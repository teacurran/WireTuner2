import WTCRDT
import WTGeometry
import WTProto
import WTRender

// IMG-025: the Crop tool's arithmetic and commands (cropping-bitmaps.adoc).  The crop is
// `ImageProps.crop`, a rectangle in unit image space (0...1 of the natural size each way, y down);
// the tool drags its edges through the inverse of the image's transform, slides the picture behind
// it, and the Object panel shows it in pixels of the current picture.

/// The crop rectangle's geometry.
public enum ImageCropping {
    /// A crop handle: the corners and edge midpoints of the visible rectangle.
    public enum Handle: CaseIterable, Hashable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// The handle's place on the unit square (y down).
        public var unit: (x: Double, y: Double) {
            switch self {
            case .topLeft: (0, 0)
            case .top: (0.5, 0)
            case .topRight: (1, 0)
            case .right: (1, 0.5)
            case .bottomRight: (1, 1)
            case .bottom: (0.5, 1)
            case .bottomLeft: (0, 1)
            case .left: (0, 0.5)
            }
        }

        public var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
    }

    /// The whole picture.
    public static let full = Rect(x: 0, y: 0, width: 1, height: 1)
    /// The smallest crop edge, unit space (a crop never collapses to nothing).
    public static let minimum = 0.001

    /// The crop that shows: the stored one under the read-time rule, else the whole picture.
    public static func crop(of props: Wiretuner_Doc_V1_ImageProps) -> Rect {
        ImageNodes.item(props, transform: .identity).effectiveCrop ?? full
    }

    /// The crop of image `node`; nil when it is not an image.
    public static func crop(of node: OpID, in state: EngineState) -> Rect? {
        guard case .image(let props)? = state.props(node).kind else { return nil }
        return crop(of: props)
    }

    /// Whether image `node` is cropped (a crop that applies).
    public static func isCropped(_ node: OpID, in state: EngineState) -> Bool {
        guard case .image(let props)? = state.props(node).kind else { return false }
        return ImageNodes.item(props, transform: .identity).effectiveCrop != nil
    }

    /// A pasteboard `delta` at the image as a unit-space delta: through the inverse of the
    /// image's pasteboard `transform`, over its natural size.
    public static func unitDelta(_ delta: Vector, transform: WTGeometry.AffineTransform, natural: Rect) -> Vector {
        guard natural.width > 0, natural.height > 0, let inverse = transform.inverted() else { return Vector(dx: 0, dy: 0) }
        let origin = inverse.apply(Point.zero)
        let moved = inverse.apply(Point(x: delta.dx, y: delta.dy))
        return Vector(dx: (moved.x - origin.x) / natural.width, dy: (moved.y - origin.y) / natural.height)
    }

    /// `crop` with `handle` dragged by `delta` (unit space): the handle's edges move, never past
    /// the picture's edge or through the opposite edge.  `proportional` (kbd:[Shift], corners)
    /// keeps the crop's proportions; `symmetric` (kbd:[Option]) moves the opposite edge the same
    /// amount the other way.
    public static func resize(_ crop: Rect, handle: Handle, by delta: Vector, proportional: Bool, symmetric: Bool) -> Rect {
        if proportional && handle.isCorner { return proportionalResize(crop, handle: handle, by: delta, symmetric: symmetric) }
        let (minX, maxX) = edges(crop.minX, crop.maxX, handle: handle.unit.x, delta: delta.dx, symmetric: symmetric)
        let (minY, maxY) = edges(crop.minY, crop.maxY, handle: handle.unit.y, delta: delta.dy, symmetric: symmetric)
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// One axis of a resize: the low edge (`handle` 0), the high one (1) or neither (0.5).
    static func edges(_ low: Double, _ high: Double, handle: Double, delta: Double, symmetric: Bool) -> (Double, Double) {
        guard handle != 0.5 else { return (low, high) }
        if symmetric {
            // The inward distance moved by both edges.
            let inward = handle == 0 ? delta : -delta
            let t = min(max(inward, max(-low, -(1 - high))), (high - low - minimum) / 2)
            return (low + t, high - t)
        }
        if handle == 0 { return (min(max(low + delta, 0), high - minimum), high) }
        return (low, max(min(high + delta, 1), low + minimum))
    }

    static func proportionalResize(_ crop: Rect, handle: Handle, by delta: Vector, symmetric: Bool) -> Rect {
        let (hx, hy) = handle.unit
        let corner = Point(x: hx == 0 ? crop.minX : crop.maxX, y: hy == 0 ? crop.minY : crop.maxY)
        let anchor = symmetric ? Point(x: crop.midX, y: crop.midY) : Point(x: hx == 0 ? crop.maxX : crop.minX, y: hy == 0 ? crop.maxY : crop.minY)
        let reachX = abs(corner.x - anchor.x), reachY = abs(corner.y - anchor.y)
        guard reachX > 0, reachY > 0 else { return crop }
        let dragged = Point(x: corner.x + delta.dx, y: corner.y + delta.dy)
        var scale = max((dragged.x - anchor.x) / (corner.x - anchor.x), (dragged.y - anchor.y) / (corner.y - anchor.y))
        // Room from the anchor to the picture's edges, each way the crop grows.
        let roomX = symmetric ? min(anchor.x, 1 - anchor.x) : (hx == 0 ? anchor.x : 1 - anchor.x)
        let roomY = symmetric ? min(anchor.y, 1 - anchor.y) : (hy == 0 ? anchor.y : 1 - anchor.y)
        scale = min(scale, roomX / reachX, roomY / reachY)
        scale = max(scale, minimum / min(crop.width, crop.height))
        let width = crop.width * scale, height = crop.height * scale
        let x = symmetric ? anchor.x - width / 2 : (hx == 0 ? anchor.x - width : anchor.x)
        let y = symmetric ? anchor.y - height / 2 : (hy == 0 ? anchor.y - height : anchor.y)
        return Rect(x: x, y: y, width: width, height: height)
    }

    /// `crop` moved by `delta` (unit space), kept inside the picture.
    public static func slide(_ crop: Rect, by delta: Vector) -> Rect {
        let x = min(max(crop.minX + delta.dx, 0), 1 - crop.width)
        let y = min(max(crop.minY + delta.dy, 0), 1 - crop.height)
        return Rect(x: x, y: y, width: crop.width, height: crop.height)
    }

    /// `crop` in pixels of a `width` × `height` picture: left, top, width, height.
    public static func pixels(_ crop: Rect, width: Int, height: Int) -> Rect {
        Rect(x: crop.minX * Double(width), y: crop.minY * Double(height), width: crop.width * Double(width), height: crop.height * Double(height))
    }

    /// A crop typed in pixels as unit space: clamped to the picture; nil for a picture with no
    /// size or a rectangle with no area inside it.
    public static func unit(fromPixels rect: Rect, width: Int, height: Int) -> Rect? {
        guard width > 0, height > 0 else { return nil }
        let w = Double(width), h = Double(height)
        let minX = min(max(rect.minX, 0), w), maxX = min(max(rect.maxX, 0), w)
        let minY = min(max(rect.minY, 0), h), maxY = min(max(rect.maxY, 0), h)
        guard maxX - minX > 0, maxY - minY > 0 else { return nil }
        return Rect(x: minX / w, y: minY / h, width: (maxX - minX) / w, height: (maxY - minY) / h)
    }

    /// A crop as stored: nil for the whole picture (uncropped), else `crop`.
    public static func stored(_ crop: Rect) -> Rect? {
        let tolerance = 1e-9
        let whole = abs(crop.minX) < tolerance && abs(crop.minY) < tolerance && abs(crop.width - 1) < tolerance && abs(crop.height - 1) < tolerance
        return whole ? nil : crop
    }

    /// The pixel rectangle *Trim to crop* keeps: the crop in pixels, rounded out to whole pixels.
    public static func trimRect(_ crop: Rect, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let px = pixels(crop, width: width, height: height)
        // A hair of tolerance, so a crop on whole pixels is not rounded out by float error.
        let slack = 1e-6
        let x = max(Int((px.minX + slack).rounded(.down)), 0), y = max(Int((px.minY + slack).rounded(.down)), 0)
        let maxX = min(Int((px.maxX - slack).rounded(.up)), width), maxY = min(Int((px.maxY - slack).rounded(.up)), height)
        return (x, y, max(maxX - x, 1), max(maxY - y, 1))
    }
}

/// Sets (or with nil removes) the crop of each image, "Crop <name>" / "Remove Crop"; with
/// `slide` the picture moves by that local delta at the same time so the visible part stays
/// where it is on the page (the Crop tool's drag inside the crop).  One change.
public struct CropImage: Command {
    public var nodes: [OpID]
    public var crop: Rect?
    /// A local-space translation applied under the transform with the crop (sliding).
    public var slide: Vector?
    /// The image's name for the label ("" leaves it out).
    public var name: String

    public init(_ nodes: [OpID], crop: Rect?, slide: Vector? = nil, name: String = "") {
        self.nodes = nodes
        self.crop = crop.flatMap(ImageCropping.stored)
        self.slide = slide
        self.name = name
    }

    public var label: String {
        guard crop != nil || slide != nil else { return ImageNodes.label("Remove Crop", count: nodes.count) }
        return name.isEmpty || nodes.count != 1 ? ImageNodes.label("Crop", count: nodes.count) : "Crop \(name)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try SetImageSetting(nodes, .crop(crop)).execute(&builder, state: state)
        guard let slide, slide.dx != 0 || slide.dy != 0 else { return }
        for node in nodes {
            let current = Objects.transform(of: node, in: state)
            let moved = WTGeometry.AffineTransform.translation(slide).concatenating(current)
            builder.append(Ops.set(node, [ImageFields.transform], values: ImageFields.values { $0.common.transform = PathEditing.proto(moved) }))
        }
    }
}

/// *Trim to crop* (Optimize Image, IMG-020): the image's pixels replaced by the visible part
/// (`pixels`, already cut to `ImageCropping.trimRect` of the crop by the caller, and possibly
/// resampled by Optimize Image), the crop reset, the stored resolution set so the new pixels cover
/// exactly the kept part's natural size (the old resolution when they were not resampled) and the
/// transform moved so the visible part does not move on the page.  One change, "Trim to Crop".
public struct TrimImageToCrop: Command {
    public var node: OpID
    public var pixels: Wiretuner_Doc_V1_PixelSource
    public var label: String { "Trim to Crop" }

    public init(_ node: OpID, pixels: Wiretuner_Doc_V1_PixelSource) {
        self.node = node
        self.pixels = pixels
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ImageNodes.editable([node], in: state)
        try ImageNodes.check(pixels)
        let props = state.props(node).image
        let natural = ImageNodes.naturalRect(props)
        let crop = ImageCropping.crop(of: props)
        let kept = ImageCropping.trimRect(crop, width: Int(props.pixels.pixelWidth), height: Int(props.pixels.pixelHeight))
        // The kept pixels' top-left in local space: the new natural frame starts there.
        let offset = Vector(dx: Double(kept.x) / max(Double(props.pixels.pixelWidth), 1) * natural.width,
                            dy: Double(kept.y) / max(Double(props.pixels.pixelHeight), 1) * natural.height)
        let moved = WTGeometry.AffineTransform.translation(offset).concatenating(Objects.transform(of: node, in: state))
        // The kept part's natural size, which the new pixels cover whatever their count.
        let keptWidth = Double(kept.width) / max(Double(props.pixels.pixelWidth), 1) * natural.width
        let keptHeight = Double(kept.height) / max(Double(props.pixels.pixelHeight), 1) * natural.height
        let values = ImageFields.values { image in
            image.pixels = pixels
            image.common.transform = PathEditing.proto(moved)
            image.dpiX = keptWidth > 0 ? Double(pixels.pixelWidth) / keptWidth * 72 : props.dpiX
            image.dpiY = keptHeight > 0 ? Double(pixels.pixelHeight) / keptHeight * 72 : props.dpiY
        }
        builder.append(Ops.set(node, [ImageFields.pixels, ImageFields.crop, ImageFields.transform, ImageFields.dpiX, ImageFields.dpiY], values: values))
    }
}
