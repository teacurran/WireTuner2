// Conversions from the renderer-agnostic value types to Core Graphics.  Kept in one file so
// nothing else in the display list or tile maths imports CoreGraphics.

import WTGeometry
import CoreGraphics

extension Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension Rect {
    var cg: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }
}

extension AffineTransform {
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

extension DisplayPath {
    /// The path as a `CGPath`.
    var cgPath: CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point.cg)
            case .line(let point):
                path.addLine(to: point.cg)
            case .quadCurve(let control, let end):
                path.addQuadCurve(to: end.cg, control: control.cg)
            case .cubicCurve(let control1, let control2, let end):
                path.addCurve(to: end.cg, control1: control1.cg, control2: control2.cg)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

extension DisplayPath {
    /// The elements of `cgPath` (glyph outlines, Core Graphics strokes).
    init(cgPath: CGPath) {
        var elements: [Element] = []
        cgPath.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            func point(_ index: Int) -> Point {
                Point(x: Double(points[index].x), y: Double(points[index].y))
            }
            switch element.type {
            case .moveToPoint:
                elements.append(.move(to: point(0)))
            case .addLineToPoint:
                elements.append(.line(to: point(0)))
            case .addQuadCurveToPoint:
                elements.append(.quadCurve(control: point(0), end: point(1)))
            case .addCurveToPoint:
                elements.append(.cubicCurve(control1: point(0), control2: point(1), end: point(2)))
            default:
                elements.append(.close)
            }
        }
        self.init(elements: elements)
    }
}

extension Color {
    /// The colour in the sRGB colour space (`CoreGraphicsRenderer.colorSpace`).
    var cg: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension FillRule {
    var cg: CGPathFillRule {
        switch self {
        case .nonZero: return .winding
        case .evenOdd: return .evenOdd
        }
    }
}

extension LineCap {
    var cg: CGLineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

extension LineJoin {
    var cg: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}
