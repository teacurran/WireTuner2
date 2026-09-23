// Drawing a flattened scene with Core Graphics (IO-017's "debug view that renders the flattened
// scene").  The same drawing composites translucent regions for opaque targets and lets tests
// hold a flattened page to WTRender's rendering of the live display list.  Filters (SVG-only
// blur, shadow and glow) are not drawn: a scene carries them only for targets that keep them.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// Renders flat nodes.
public struct FlatRenderer: Sendable {
    public init() {}

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The page rendered at `scale` pixels per point over its background (or `background`, or
    /// transparent), as premultiplied sRGB RGBA.
    public func render(_ page: FlatPage, scale: Double, background: Color? = nil) -> CGImage? {
        render(page.nodes, region: page.bounds, scale: scale, background: background ?? page.background)
    }

    /// `nodes` rendered over `region` (pasteboard) at `scale`.
    public func render(_ nodes: [FlatNode], region: Rect, scale: Double, background: Color?) -> CGImage? {
        let width = Int((region.width * scale).rounded())
        let height = Int((region.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: FlatRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        if let background {
            context.setFillColor(background.flatCG)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Pasteboard (y down) → pixels (Core Graphics y up).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        context.translateBy(x: CGFloat(-region.minX), y: CGFloat(-region.minY))
        draw(nodes, in: context)
        return context.makeImage()
    }

    /// Draws `nodes` into `context`, whose user space is pasteboard space.
    public func draw(_ nodes: [FlatNode], in context: CGContext) {
        for node in nodes {
            draw(node, in: context)
        }
    }

    private func draw(_ node: FlatNode, in context: CGContext) {
        switch node {
        case .path(let path):
            drawPath(path, in: context)
        case .text(let text):
            context.saveGState()
            context.concatenate(text.transform.flatCG)
            context.addPath(text.run.outline.flatCGPath)
            context.setFillColor(text.color.flatCG)
            context.fillPath(using: .winding)
            context.restoreGState()
        case .image(let image):
            context.saveGState()
            context.concatenate(image.transform.flatCG)
            context.translateBy(x: 0, y: CGFloat(image.rect.minY + image.rect.maxY))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = image.rasterized ? .none : .default
            context.draw(image.image, in: image.rect.flatCG)
            context.restoreGState()
        case .group(let group):
            drawGroup(group, in: context)
        }
    }

    private func drawGroup(_ group: FlatGroup, in context: CGContext) {
        context.saveGState()
        if let clip = group.clip {
            context.addPath(clip.path.applying(clip.transform).flatCGPath)
            context.clip(using: clip.rule.flatCG)
        }
        if let mask = group.softMask, let image = FlatRenderer.maskImage(mask, pixelsPerPoint: FlatRenderer.deviceScale(of: context)) {
            context.clip(to: image.rect.flatCG, mask: image.picture)
        }
        let layered = group.opacity < 1
        if layered {
            context.setAlpha(CGFloat(group.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        draw(group.children, in: context)
        if layered {
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    private func drawPath(_ item: FlatPath, in context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.flatCG)
        context.addPath(item.path.flatCGPath)
        let rule: CGPathFillRule
        switch item.style {
        case .fill(let fillRule):
            rule = fillRule.flatCG
        case .stroke(let style):
            FlatRenderer.apply(style, to: context)
            context.replacePathWithStrokedPath()
            rule = .winding
        }
        switch item.paint {
        case .color(let color):
            context.setFillColor(color.flatCG)
            context.fillPath(using: rule)
        case .gradient(let gradient):
            context.clip(using: rule)
            FlatRenderer.drawShading(gradient, in: context)
        }
        context.restoreGState()
    }

    /// Stroke parameters in the context's current (local) space; a hairline is one device pixel.
    static func apply(_ style: StrokeStyle, to context: CGContext) {
        let width = style.isHairline ? 1 / deviceScale(of: context) : style.width
        context.setLineWidth(CGFloat(width))
        context.setLineCap(style.cap.flatCG)
        context.setLineJoin(style.join.flatCG)
        context.setMiterLimit(CGFloat(style.miterLimit))
        let dash = style.effectiveDash
        if !dash.isEmpty {
            context.setLineDash(phase: CGFloat(style.dashPhase), lengths: dash.map { CGFloat($0) })
        }
    }

    /// Device pixels per user unit.
    static func deviceScale(of context: CGContext) -> Double {
        let ctm = context.ctm
        return max(abs(Double(ctm.a * ctm.d - ctm.b * ctm.c)).squareRoot(), 1e-9)
    }

    /// Fills the clip with `gradient` (user space = the gradient's local space).
    static func drawShading(_ gradient: FlatGradient, in context: CGContext) {
        let function = ShadingFunction.make(components: 4) { t in
            let color = gradient.color(at: t)
            return [color.red, color.green, color.blue, color.alpha]
        }
        switch gradient.shape {
        case .axial(let start, let end):
            let shading = CGShading(axialSpace: colorSpace, start: start.flatCG, end: end.flatCG, function: function, extendStart: true, extendEnd: true)!
            context.drawShading(shading)
        case .radial(let frame):
            let shading = CGShading(radialSpace: colorSpace, start: .zero, startRadius: 0, end: .zero, endRadius: 1, function: function, extendStart: true, extendEnd: true)!
            context.concatenate(frame.flatCG)
            context.drawShading(shading)
        }
    }

    /// The mask's factors over its bounds at `pixelsPerPoint`, as a grey image and the pasteboard
    /// rectangle it covers (Core Graphics masks read white as paint, black as masked).
    static func maskImage(_ mask: FlatSoftMask, pixelsPerPoint: Double) -> (picture: CGImage, rect: Rect)? {
        let scale = min(pixelsPerPoint, 4096 / max(mask.bounds.width, mask.bounds.height, 1))
        let left = (mask.bounds.minX * scale).rounded(.down)
        let top = (mask.bounds.minY * scale).rounded(.down)
        let width = Int(max((mask.bounds.maxX * scale).rounded(.up) - left, 1))
        let height = Int(max((mask.bounds.maxY * scale).rounded(.up) - top, 1))
        guard let inverse = mask.frame.inverted() else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let point = Point(x: (left + Double(column) + 0.5) / scale, y: (top + Double(row) + 0.5) / scale)
                let t = mask.gradient.parameter(at: inverse.apply(point))
                // Core Graphics draws the mask's row 0 at the rectangle's largest y.
                bytes[(height - 1 - row) * width + column] = UInt8((min(max(mask.value(at: t), 0), 1) * 255).rounded())
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let picture = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return (picture, Rect(x: left / scale, y: top / scale, width: Double(width) / scale, height: Double(height) / scale))
    }
}

extension FlatGradient {
    /// The geometry parameter `t` at a point of the gradient's local space.
    func parameter(at point: Point) -> Double {
        switch shape {
        case .axial(let start, let end):
            let axis = end - start
            return (point - start).dot(axis) / axis.lengthSquared
        case .radial(let frame):
            // The frame is invertible by construction (its axes are never parallel).
            let uv = frame.inverted()!.apply(point)
            return (uv.x * uv.x + uv.y * uv.y).squareRoot()
        }
    }
}

/// A Core Graphics function of one input over 0 ... 1.
enum ShadingFunction {
    private final class Box {
        let evaluate: (Double) -> [Double]
        let components: Int

        init(components: Int, evaluate: @escaping (Double) -> [Double]) {
            self.components = components
            self.evaluate = evaluate
        }
    }

    static func make(components: Int, evaluate: @escaping (Double) -> [Double]) -> CGFunction {
        var callbacks = CGFunctionCallbacks(
            version: 0,
            evaluate: { info, input, output in
                let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
                let values = box.evaluate(Double(input[0]))
                for index in 0..<box.components {
                    output[index] = CGFloat(values[index])
                }
            },
            releaseInfo: { info in
                Unmanaged<Box>.fromOpaque(info!).release()
            }
        )
        let domain: [CGFloat] = [0, 1]
        let range = [CGFloat](repeating: 0, count: components * 2).enumerated().map { $0.offset % 2 == 0 ? 0 : 1 } as [CGFloat]
        let box = Box(components: components, evaluate: evaluate)
        return CGFunction(info: Unmanaged.passRetained(box).toOpaque(), domainDimension: 1, domain: domain, rangeDimension: components, range: range, callbacks: &callbacks)!
    }
}

// MARK: - Core Graphics conversions (WTRender keeps its own internal)

extension Point {
    var flatCG: CGPoint { CGPoint(x: x, y: y) }
}

extension Rect {
    var flatCG: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

extension AffineTransform {
    var flatCG: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension Color {
    /// The colour tagged in its own space (CMYK through Working CMYK), as vector output carries
    /// it; the sRGB drawing surface converts it.
    var flatCG: CGColor { ColorManagement.standard.taggedCGColor(self) }
}

extension FillRule {
    var flatCG: CGPathFillRule { self == .evenOdd ? .evenOdd : .winding }
}

extension LineCap {
    var flatCG: CGLineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

extension LineJoin {
    var flatCG: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

extension DisplayPath {
    var flatCGPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point): path.move(to: point.flatCG)
            case .line(let point): path.addLine(to: point.flatCG)
            case .quadCurve(let control, let end): path.addQuadCurve(to: end.flatCG, control: control.flatCG)
            case .cubicCurve(let control1, let control2, let end): path.addCurve(to: end.flatCG, control1: control1.flatCG, control2: control2.flatCG)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
