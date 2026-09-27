import Foundation
import WTGeometry

/// SVG path data (the `d` attribute): read with every command (absolute and relative moves,
/// lines, horizontal and vertical lines, cubic, smooth cubic, quadratic, smooth quadratic and
/// elliptical arcs, close), written as absolute M, L, C (or Q) and Z.
enum PathData {
    /// The contours `d` describes; arcs become cubics of at most a quarter turn each.
    static func parse(_ d: String) -> [Contour] {
        var tokens = Tokens(d)
        var contours: [Contour] = []
        var segments: [CubicBezier] = []
        var current = Point.zero, start = Point.zero
        var lastControl: Point?
        var lastQuad: Point?
        var command: Character = "M"
        func finish(closed: Bool) {
            if !segments.isEmpty { contours.append(Contour(segments: segments, closed: closed)) }
            segments = []
        }
        func line(to p: Point) {
            segments.append(Line(start: current, end: p).elevated())
            current = p
        }
        while !tokens.atEnd {
            if let next = tokens.command() { command = next }
            let relative = command.isLowercase
            func point() -> Point {
                let x = tokens.number(), y = tokens.number()
                return relative ? Point(x: current.x + x, y: current.y + y) : Point(x: x, y: y)
            }
            var control: Point?
            var quad: Point?
            switch command.uppercased().first! {
            case "M":
                finish(closed: false)
                current = point()
                start = current
                // Further pairs after a move are lines.
                command = relative ? "l" : "L"
            case "L": line(to: point())
            case "H":
                let x = tokens.number()
                line(to: Point(x: relative ? current.x + x : x, y: current.y))
            case "V":
                let y = tokens.number()
                line(to: Point(x: current.x, y: relative ? current.y + y : y))
            case "C":
                let c1 = point(), c2 = point(), end = point()
                segments.append(CubicBezier(current, c1, c2, end))
                control = c2
                current = end
            case "S":
                let c1 = lastControl.map { Point(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(), end = point()
                segments.append(CubicBezier(current, c1, c2, end))
                control = c2
                current = end
            case "Q":
                let c = point(), end = point()
                segments.append(CubicBezier(quadratic: QuadraticBezier(current, c, end)))
                quad = c
                current = end
            case "T":
                let c = lastQuad.map { Point(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let end = point()
                segments.append(CubicBezier(quadratic: QuadraticBezier(current, c, end)))
                quad = c
                current = end
            case "A":
                let rx = tokens.number(), ry = tokens.number(), rotation = tokens.number()
                let large = tokens.number() != 0, sweep = tokens.number() != 0
                let end = point()
                segments += arc(from: current, to: end, rx: rx, ry: ry, rotation: rotation * .pi / 180, large: large, sweep: sweep)
                current = end
            default:
                if current.distance(to: start) > 1e-9 { line(to: start) }
                finish(closed: true)
                current = start
            }
            lastControl = control
            lastQuad = quad
        }
        finish(closed: false)
        return contours
    }

    /// An SVG elliptical arc as cubics (the endpoint parameterization of the SVG spec, F.6).
    static func arc(from p0: Point, to p1: Point, rx: Double, ry: Double, rotation phi: Double, large: Bool, sweep: Bool) -> [CubicBezier] {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { return [Line(start: p0, end: p1).elevated()] }
        let (c, s) = (cos(phi), sin(phi))
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = max(rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1, 0)
        var factor = (numerator / (rx * rx * y1 * y1 + ry * ry * x1 * x1)).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let center = Point(x: c * cx1 - s * cy1 + (p0.x + p1.x) / 2, y: s * cx1 + c * cy1 + (p0.y + p1.y) / 2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(Int((abs(delta) / (.pi / 2)).rounded(.up)), 1)
        let step = delta / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> Point {
            Point(x: center.x + rx * cos(t) * c - ry * sin(t) * s, y: center.y + rx * cos(t) * s + ry * sin(t) * c)
        }
        func derivative(_ t: Double) -> Vector {
            Vector(dx: -rx * sin(t) * c - ry * cos(t) * s, dy: -rx * sin(t) * s + ry * cos(t) * c)
        }
        return (0..<pieces).map { index in
            let a = theta1 + Double(index) * step, b = a + step
            let start = index == 0 ? p0 : point(a), end = index == pieces - 1 ? p1 : point(b)
            return CubicBezier(start, start + derivative(a) * k, end - derivative(b) * k, end)
        }
    }

    /// Absolute path data for `contours` (three decimals); with `quadratic`, a cubic that is an
    /// elevated quadratic is written as Q.
    static func write(_ contours: [Contour], quadratic: Bool = false) -> String {
        func f(_ value: Double) -> String {
            let text = String(format: "%.3f", value)
            return text == "-0.000" ? "0.000" : text
        }
        func p(_ point: Point) -> String { "\(f(point.x)) \(f(point.y))" }
        var parts: [String] = []
        for contour in contours {
            guard let first = contour.startPoint else { continue }
            parts.append("M\(p(first))")
            for segment in contour.segments {
                if segment.isLinear(tolerance: 1e-9) {
                    parts.append("L\(p(segment.p3))")
                } else if quadratic, let control = quadraticControl(segment) {
                    parts.append("Q\(p(control)) \(p(segment.p3))")
                } else {
                    parts.append("C\(p(segment.p1)) \(p(segment.p2)) \(p(segment.p3))")
                }
            }
            if contour.isClosed { parts.append("Z") }
        }
        return parts.joined(separator: " ")
    }

    /// The control point of the quadratic `segment` was elevated from, if it was one.
    static func quadraticControl(_ segment: CubicBezier) -> Point? {
        let a = Point(x: (3 * segment.p1.x - segment.p0.x) / 2, y: (3 * segment.p1.y - segment.p0.y) / 2)
        let b = Point(x: (3 * segment.p2.x - segment.p3.x) / 2, y: (3 * segment.p2.y - segment.p3.y) / 2)
        return a.distance(to: b) < 1e-6 ? a : nil
    }

    /// Path data tokens: command letters and numbers (with exponents, and the flags run together
    /// as SVG allows).
    struct Tokens {
        let scalars: [Character]
        var index = 0

        init(_ string: String) { scalars = Array(string) }

        mutating func skip() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index] == "\n" || scalars[index] == "\t" { index += 1 }
        }

        var atEnd: Bool {
            mutating get {
                skip()
                return index >= scalars.count
            }
        }

        mutating func command() -> Character? {
            skip()
            guard index < scalars.count, scalars[index].isLetter, scalars[index] != "e", scalars[index] != "E" else { return nil }
            defer { index += 1 }
            return scalars[index]
        }

        mutating func number() -> Double {
            skip()
            let start = index
            if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
            var seenDot = false
            while index < scalars.count {
                let ch = scalars[index]
                if ch.isNumber { index += 1 } else if ch == ".", !seenDot { seenDot = true; index += 1 } else if ch == "e" || ch == "E" {
                    index += 1
                    if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
                } else { break }
            }
            return Double(String(scalars[start..<index])) ?? 0
        }
    }
}
