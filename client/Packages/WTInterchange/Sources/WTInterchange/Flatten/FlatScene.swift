// The flattened scene (export-vector.adoc, "How effects and transparency export"; IO-017): what
// the `Flattener` hands a vector writer.  It holds only primitives a target format can carry --
// paths filled or stroked with a colour or a linear/radial gradient, glyph runs, images, and
// groups with a clip, an opacity, a gradient soft mask or a blur/shadow/glow filter -- each
// optionally tagged with the document node it came from (ids, links, accessibility).  Everything
// else has been expanded to paths or rendered to images before it gets here.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// What a target format can carry; the flattener reduces everything else.
public struct FlattenTarget: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Group opacity and translucent colours are kept (otherwise composited to opaque pieces).
    public static let transparency = FlattenTarget(rawValue: 1 << 0)
    /// Gradient soft masks (Transparency's Gradient Mask) are kept.
    public static let softMasks = FlattenTarget(rawValue: 1 << 1)
    /// Linear and radial gradients are kept as gradients.
    public static let gradients = FlattenTarget(rawValue: 1 << 2)
    /// Blur, drop shadow and glow are kept as filters.
    public static let filters = FlattenTarget(rawValue: 1 << 3)
    /// Glyph runs are kept as text.
    public static let text = FlattenTarget(rawValue: 1 << 4)
    /// Placed EPS files are passed through as their PostScript (EPS): the flattener tags the
    /// node's group with `FlatGroup.postScript` around its preview drawing.
    public static let postScript = FlattenTarget(rawValue: 1 << 6)
    /// Basic strokes are kept as strokes (otherwise the writer receives them as strokes anyway;
    /// without this flag they are expanded to filled outlines).
    public static let strokes = FlattenTarget(rawValue: 1 << 5)

    /// SVG: everything but nothing CSS cannot draw.
    public static let svg: FlattenTarget = [.transparency, .softMasks, .gradients, .filters, .text, .strokes]
    /// PDF 1.4 and later.
    public static let pdf: FlattenTarget = [.transparency, .softMasks, .gradients, .text, .strokes]
    /// An opaque vector target (EPS, PDF/X-1a): no transparency of any kind.
    public static let opaque: FlattenTarget = [.gradients, .text, .strokes]
}

/// A gradient with its geometry resolved in the painted item's local space.
public struct FlatGradient: Hashable, Sendable {
    public enum Shape: Hashable, Sendable {
        /// Linear and Logarithmic: `t` runs from `start` (0) to `end` (1).
        case axial(start: Point, end: Point)
        /// Radial: `t` is the distance from the centre in the space `frame` maps the unit circle
        /// from (centre, first end, second end).
        case radial(frame: AffineTransform)
    }

    public var shape: Shape
    /// The source gradient: stops, behaviour, repeat count, logarithmic curve.
    public var gradient: Gradient
    let ramp: Ramp

    public static func == (lhs: FlatGradient, rhs: FlatGradient) -> Bool {
        lhs.shape == rhs.shape && lhs.gradient == rhs.gradient
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(shape)
        hasher.combine(gradient)
    }

    /// The gradient of `gradient` on a path whose local control bounds are `bounds`: linear,
    /// logarithmic and radial kinds only (nil for the others and for a gradient without stops).
    public init?(_ gradient: Gradient, bounds: Rect) {
        let stops = gradient.sortedStops
        guard !stops.isEmpty else {
            return nil
        }
        let axis = FlatGradient.resolvedAxis(gradient, bounds: bounds)
        switch gradient.kind {
        case .linear, .logarithmic:
            shape = .axial(start: axis.start, end: axis.end)
        case .radial:
            let e1 = axis.end - axis.start
            // Resolved axes always carry a second end.
            var e2 = axis.end2! - axis.start
            if abs(e1.cross(e2)) < 1e-12 {
                e2 = e1.perpendicular
            }
            shape = .radial(frame: AffineTransform(a: e1.dx, b: e1.dy, c: e2.dx, d: e2.dy, tx: axis.start.x, ty: axis.start.y))
        case .rectangle, .contour, .cone:
            return nil
        }
        self.gradient = gradient
        ramp = Ramp(stops: stops)
    }

    /// WTRender's handle resolution: Auto size geometry from `bounds` when the axis is unset or
    /// the behaviour is Auto size; a coincident end reads as a 1 pt axis; a missing second end
    /// reads as the first rotated 90°.
    static func resolvedAxis(_ gradient: Gradient, bounds: Rect) -> Gradient.Axis {
        guard let axis = gradient.axis, gradient.behavior != .autoSize else {
            let center = Point(x: bounds.midX, y: bounds.midY)
            switch gradient.kind {
            case .linear, .logarithmic:
                let start = Point(x: bounds.minX, y: bounds.midY)
                let end = Point(x: bounds.maxX, y: bounds.midY)
                return Gradient.Axis(start: start, end: end == start ? start + Vector(1, 0) : end)
            default:
                return Gradient.Axis(start: center, end: center + Vector(max(bounds.width / 2, 0.5), 0), end2: center + Vector(0, max(bounds.height / 2, 0.5)))
            }
        }
        let end = axis.end == axis.start || !axis.end.isFinite ? axis.start + Vector(1, 0) : axis.end
        let end2 = axis.end2 ?? (axis.start + (end - axis.start).perpendicular)
        return Gradient.Axis(start: axis.start, end: end, end2: end2)
    }

    /// Where on the ramp a geometry parameter `t` lands: clamped, then the behaviour (Repeat:
    /// the fraction of `t × count`; Reflect: its triangle wave), then the logarithmic curve.
    func rampPosition(_ t: Double) -> Double {
        let clamped = min(max(t.isFinite ? t : 0, 0), 1)
        let count = Double(gradient.effectiveRepeatCount)
        var u: Double
        switch gradient.behavior {
        case .normal, .autoSize:
            u = clamped
        case .repeat:
            u = clamped >= 1 ? 1 : (clamped * count).truncatingRemainder(dividingBy: 1)
        case .reflect:
            let phase = clamped >= 1 ? 0 : (clamped * count).truncatingRemainder(dividingBy: 1)
            u = 1 - abs(2 * phase - 1)
        }
        if gradient.kind == .logarithmic {
            u = log(1 + 9 * u) / log(10)
        }
        return u
    }

    /// The straight-alpha sRGB colour at geometry parameter `t` (0 ... 1).
    public func color(at t: Double) -> Color {
        let value = ramp.color(at: rampPosition(t))
        return Color(red: value.x, green: value.y, blue: value.z, alpha: value.w)
    }

    /// Whether any part of the ramp is translucent.
    public var hasAlpha: Bool {
        gradient.stops.contains { $0.color.alpha < 1 }
    }

    /// Stops for a format whose gradients interpolate linearly in sRGB (SVG): the ramp sampled
    /// finely enough that the linear interpolation between samples stays within a quarter of an
    /// 8-bit step of WTRender's OKLab ramp, with the Repeat and Reflect periods and the
    /// logarithmic curve unrolled.  Offsets never decrease; a repeat seam is two stops at one
    /// offset.
    public func linearStops(samplesPerSegment: Int = 16) -> [(offset: Double, color: Color)] {
        let sorted = gradient.sortedStops
        var grid: [Double] = [0]
        let boundaries = [0.0] + sorted.map(\.offset) + [1.0]
        let curved = gradient.kind == .logarithmic
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
            let count = curved ? samplesPerSegment * 4 : samplesPerSegment
            let singleColor = sorted.count == 1 || lower >= sorted.last!.offset || upper <= sorted.first!.offset
            let steps = singleColor && !curved ? 1 : count
            for step in 1...steps {
                grid.append(lower + (upper - lower) * Double(step) / Double(steps))
            }
        }
        var result: [(offset: Double, color: Color)] = []
        let periods = gradient.behavior == .repeat || gradient.behavior == .reflect ? gradient.effectiveRepeatCount : 1
        for period in 0..<periods {
            let base = Double(period) / Double(periods)
            let span = 1 / Double(periods)
            if gradient.behavior == .reflect {
                for u in grid {
                    result.append((base + span * u / 2, colorOnRamp(u)))
                }
                for u in grid.reversed() {
                    result.append((base + span * (1 - u / 2), colorOnRamp(u)))
                }
            } else {
                for u in grid {
                    result.append((base + span * u, colorOnRamp(u)))
                }
            }
        }
        return result
    }

    /// The colour at ramp position `u` before the curve (the linear stops unroll the curve).
    private func colorOnRamp(_ u: Double) -> Color {
        let position = gradient.kind == .logarithmic ? log(1 + 9 * u) / log(10) : u
        let value = ramp.color(at: position)
        return Color(red: value.x, green: value.y, blue: value.z, alpha: value.w)
    }
}

/// How a flat path is painted.
public enum FlatPaint: Hashable, Sendable {
    case color(Color)
    case gradient(FlatGradient)
}

/// A path filled or stroked with one paint.
public struct FlatPath: Hashable, Sendable {
    public enum Style: Hashable, Sendable {
        case fill(FillRule)
        /// A Basic stroke; width 0 is a hairline (one device pixel on screen, one point in PDF).
        case stroke(StrokeStyle)
    }

    public var path: DisplayPath
    /// Local → pasteboard.
    public var transform: AffineTransform
    public var paint: FlatPaint
    public var style: Style
    public var overprint: Bool
    public var node: NodeID?
    /// The characters when the path is a glyph run written as outlines: what SVG accessibility
    /// reads in place of the text (IO-031).
    public var readAs: String?

    public init(path: DisplayPath, transform: AffineTransform = .identity, paint: FlatPaint, style: Style = .fill(.nonZero), overprint: Bool = false, node: NodeID? = nil,
                readAs: String? = nil) {
        self.path = path
        self.transform = transform
        self.paint = paint
        self.style = style
        self.overprint = overprint
        self.node = node
        self.readAs = readAs
    }
}

/// A run of glyphs kept as text.
public struct FlatText: Hashable, Sendable {
    public var text: String
    public var run: GlyphRun
    public var color: Color
    /// Local → pasteboard.
    public var transform: AffineTransform
    public var node: NodeID?

    public init(text: String, run: GlyphRun, color: Color, transform: AffineTransform = .identity, node: NodeID? = nil) {
        self.text = text
        self.run = run
        self.color = color
        self.transform = transform
        self.node = node
    }
}

/// An image placed over a rectangle.
public struct FlatImage: @unchecked Sendable {
    public var image: CGImage
    /// The frame in local space; row 0 of the image is at `rect.minY` (y down).
    public var rect: Rect
    /// Local → pasteboard.
    public var transform: AffineTransform
    /// The original JPEG bytes, when the image is a placed JPEG drawn unchanged.
    public var jpegData: Data?
    /// Rendered by the flattener (a region it could not express), not a placed image.
    public var rasterized: Bool
    public var node: NodeID?

    public init(image: CGImage, rect: Rect, transform: AffineTransform = .identity, jpegData: Data? = nil, rasterized: Bool = false, node: NodeID? = nil) {
        self.image = image
        self.rect = rect
        self.transform = transform
        self.jpegData = jpegData
        self.rasterized = rasterized
        self.node = node
    }
}

/// A clipping path.
public struct FlatClip: Hashable, Sendable {
    public var path: DisplayPath
    public var rule: FillRule
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(path: DisplayPath, rule: FillRule = .nonZero, transform: AffineTransform = .identity) {
        self.path = path
        self.rule = rule
        self.transform = transform
    }
}

/// Transparency's Gradient Mask: the content multiplied by `1 − L × a` of the gradient (L the
/// Rec. 709 luminance of the ramp's colour, a its alpha).
public struct FlatSoftMask: Hashable, Sendable {
    public var gradient: FlatGradient
    /// The gradient's space → pasteboard.
    public var frame: AffineTransform
    /// Where the mask applies, in pasteboard space (the content's bounds).
    public var bounds: Rect

    public init(gradient: FlatGradient, frame: AffineTransform, bounds: Rect) {
        self.gradient = gradient
        self.frame = frame
        self.bounds = bounds
    }

    /// The mask factor at geometry parameter `t`.
    public func value(at t: Double) -> Double {
        let color = gradient.color(at: t)
        return 1 - ColorMath.luminance(red: color.red, green: color.green, blue: color.blue) * min(max(color.alpha, 0), 1)
    }
}

/// A raster effect kept live as a filter (SVG).  Distances are pasteboard points.
public enum FlatFilter: Hashable, Sendable {
    /// Gaussian blur with standard deviation `sigma`.
    case blur(sigma: Double)
    /// The content's alpha offset by (`dx`, `dy`), blurred and tinted, under the content.
    case dropShadow(dx: Double, dy: Double, sigma: Double, color: Color)
    /// The content's alpha dilated by `radius`, blurred and tinted, under the content.
    case glow(radius: Double, sigma: Double, color: Color)

    /// How far the filter reaches beyond the content.
    public var spread: Double {
        switch self {
        case .blur(let sigma): return 3 * sigma
        case .dropShadow(let dx, let dy, let sigma, _): return max(abs(dx), abs(dy)) + 3 * sigma
        case .glow(let radius, let sigma, _): return radius + 3 * sigma
        }
    }
}

/// Children drawn together.
public struct FlatGroup: Sendable {
    public var children: [FlatNode]
    public var clip: FlatClip?
    /// 0 ... 1; below 1 the children composite as one transparency group.
    public var opacity: Double
    public var softMask: FlatSoftMask?
    public var filter: FlatFilter?
    public var node: NodeID?
    /// A placed EPS file: a PostScript writer writes this verbatim instead of the children (its
    /// preview); every other writer draws the children.
    public var postScript: ExportPostScript?

    public init(children: [FlatNode], clip: FlatClip? = nil, opacity: Double = 1, softMask: FlatSoftMask? = nil, filter: FlatFilter? = nil, node: NodeID? = nil, postScript: ExportPostScript? = nil) {
        self.children = children
        self.clip = clip
        self.opacity = opacity
        self.softMask = softMask
        self.filter = filter
        self.node = node
        self.postScript = postScript
    }

    /// Whether the group changes how its children look (anything but a plain grouping).
    public var isEffective: Bool {
        clip != nil || opacity < 1 || softMask != nil || filter != nil
    }
}

/// One element of a flattened scene.
public indirect enum FlatNode: Sendable {
    case path(FlatPath)
    case text(FlatText)
    case image(FlatImage)
    case group(FlatGroup)

    /// The document node the element stands for.
    public var node: NodeID? {
        switch self {
        case .path(let path): return path.node
        case .text(let text): return text.node
        case .image(let image): return image.node
        case .group(let group): return group.node
        }
    }

    /// The element tagged with `node`.
    func tagged(_ node: NodeID) -> FlatNode {
        switch self {
        case .path(var path):
            path.node = node
            return .path(path)
        case .text(var text):
            text.node = node
            return .text(text)
        case .image(var image):
            image.node = node
            return .image(image)
        case .group(var group):
            group.node = node
            return .group(group)
        }
    }

    /// A conservative pasteboard bound on what the element paints; nil for nothing.
    public var bounds: Rect? {
        switch self {
        case .path(let path):
            guard let control = path.path.controlBounds else {
                return nil
            }
            if case .stroke(let style) = path.style {
                let outset = max(style.width, 1) * max(style.miterLimit, 2.0.squareRoot()) / 2
                return control.expanded(by: outset).applying(path.transform)
            }
            return control.applying(path.transform)
        case .text(let text):
            return text.run.inkBounds?.applying(text.transform)
        case .image(let image):
            return image.rect.applying(image.transform)
        case .group(let group):
            guard var content = FlatNode.union(group.children.compactMap(\.bounds)) else {
                return nil
            }
            if let filter = group.filter {
                content = content.expanded(by: filter.spread)
            }
            if let clip = group.clip {
                guard let clipBounds = clip.path.controlBounds?.applying(clip.transform) else {
                    return nil
                }
                return content.intersection(clipBounds).nonEmpty
            }
            return content
        }
    }

    static func union(_ rects: [Rect]) -> Rect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }
}

/// A flattened page.
public struct FlatPage: Sendable {
    /// The exported area, pasteboard coordinates.
    public var bounds: Rect
    public var background: Color?
    /// Back to front.
    public var nodes: [FlatNode]

    public init(bounds: Rect, background: Color? = nil, nodes: [FlatNode]) {
        self.bounds = bounds
        self.background = background
        self.nodes = nodes
    }
}

extension Rect {
    /// Nil for an empty or null rectangle.
    var nonEmpty: Rect? {
        isEmpty ? nil : self
    }
}
