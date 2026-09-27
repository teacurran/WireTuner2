import CoreGraphics
import CoreText
import Foundation
import WTGeometry

/// A deterministic generator (SplitMix64), so a seed always makes the same set.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { uniform(0...1) < p }
    /// Log-uniform: sizes from a few points to a page.
    mutating func size(_ range: ClosedRange<Double>) -> Double { exp(uniform(log(range.lowerBound)...log(range.upperBound))) }
}

/// One labelled path: its class, where it came from, and its contours in pasteboard space.
struct Sample {
    enum Source: String { case tool, svg }
    var label: ShapeClass
    var source: Source
    var contours: [Contour]
}

/// The corpus: every modelled class drawn the way the tools draw it (rectangles, ellipses,
/// polygons and stars as the shape tools make them, freehand curves as the Pencil fits them,
/// letters as Create Outlines makes them) and written the way SVG files write it (arcs, relative
/// and shorthand commands, rounded coordinates), then placed at a random size, rotation and
/// position.
enum Corpus {
    static let kappa = 0.5522847498

    /// `perClass` samples of every modelled class, half from the tools and half from SVG.
    static func make(perClass: Int, seed: UInt64) -> [Sample] {
        var random = SeededRandom(seed: seed)
        var samples: [Sample] = []
        for label in ShapeClass.modelled {
            for index in 0..<perClass {
                let source: Sample.Source = index % 2 == 0 ? .tool : .svg
                samples.append(Sample(label: label, source: source, contours: sample(label, source: source, random: &random)))
            }
        }
        return samples
    }

    static func sample(_ label: ShapeClass, source: Sample.Source, random: inout SeededRandom) -> [Contour] {
        let local: [Contour]
        switch source {
        case .tool: local = toolShape(label, random: &random)
        case .svg: local = PathData.parse(svgShape(label, random: &random))
        }
        return place(local, random: &random, rounded: source == .svg)
    }

    /// A random rotation, size and position; SVG coordinates rounded to two decimals.
    static func place(_ contours: [Contour], random: inout SeededRandom, rounded: Bool) -> [Contour] {
        let bounds = contours.reduce(Rect.null) { $0.union($1.controlBounds) }
        let extent = max(bounds.width, bounds.height, 1e-9)
        let scale = random.size(8...600) / extent
        let angle = random.uniform(0...(2 * .pi))
        let transform = AffineTransform.translation(x: -bounds.midX, y: -bounds.midY)
            .concatenating(.scale(scale))
            .concatenating(.rotation(radians: angle))
            .concatenating(.translation(x: random.uniform(0...5000), y: random.uniform(0...5000)))
        return contours.map { contour in
            var placed = contour.applying(transform)
            if rounded {
                func round(_ p: Point) -> Point { Point(x: (p.x * 100).rounded() / 100, y: (p.y * 100).rounded() / 100) }
                placed.segments = placed.segments.map { CubicBezier(round($0.p0), round($0.p1), round($0.p2), round($0.p3)) }
            }
            return placed
        }
    }

    // MARK: The tools' geometry

    static func toolShape(_ label: ShapeClass, random: inout SeededRandom) -> [Contour] {
        switch label {
        case .circle: return [ellipse(rx: 1, ry: 1, arcs: random.chance(0.8) ? 4 : 8)]
        case .ellipse: return [ellipse(rx: 1, ry: 1 / random.uniform(1.3...4), arcs: 4)]
        case .rectangle: return [Contour(polygon: rectangle(random.uniform(1...6)), closed: true)]
        case .roundedRectangle:
            let aspect = random.uniform(1...5)
            return [roundedRectangle(width: aspect, height: 1, radius: random.uniform(0.12...0.5))]
        case .triangle: return [Contour(polygon: triangle(random: &random), closed: true)]
        case .polygon: return [Contour(polygon: polygon(random: &random), closed: true)]
        case .star: return [Contour(polygon: star(random: &random), closed: true)]
        case .arrow: return [Contour(polygon: arrow(random: &random), closed: true)]
        case .line: return [line(random: &random)]
        case .letterform: return Glyphs.letter(random: &random)
        default: return [blob(random: &random)]
        }
    }

    /// The Ellipse tool's outline: `arcs` cubic quarter (or eighth) arcs.
    static func ellipse(rx: Double, ry: Double, arcs: Int) -> Contour {
        let k = 4.0 / 3.0 * tan(.pi / (2 * Double(arcs)))
        var segments: [CubicBezier] = []
        for index in 0..<arcs {
            let a0 = Double(index) * 2 * .pi / Double(arcs), a1 = Double(index + 1) * 2 * .pi / Double(arcs)
            let p0 = Point(x: rx * cos(a0), y: ry * sin(a0)), p3 = Point(x: rx * cos(a1), y: ry * sin(a1))
            let p1 = Point(x: p0.x - k * rx * sin(a0), y: p0.y + k * ry * cos(a0))
            let p2 = Point(x: p3.x + k * rx * sin(a1), y: p3.y - k * ry * cos(a1))
            segments.append(CubicBezier(p0, p1, p2, p3))
        }
        return Contour(segments: segments, closed: true)
    }

    static func rectangle(_ aspect: Double) -> [Point] {
        [Point(x: 0, y: 0), Point(x: aspect, y: 0), Point(x: aspect, y: 1), Point(x: 0, y: 1)]
    }

    /// The Rectangle tool with corner radii: straight sides joined by quarter arcs (`radius` of the
    /// shorter side).
    static func roundedRectangle(width: Double, height: Double, radius fraction: Double) -> Contour {
        let r = fraction * min(width, height)
        let k = kappa * r
        var segments: [CubicBezier] = []
        func line(_ a: Point, _ b: Point) { if a.distance(to: b) > 1e-9 { segments.append(Line(start: a, end: b).elevated()) } }
        line(Point(x: r, y: 0), Point(x: width - r, y: 0))
        segments.append(CubicBezier(Point(x: width - r, y: 0), Point(x: width - r + k, y: 0), Point(x: width, y: r - k), Point(x: width, y: r)))
        line(Point(x: width, y: r), Point(x: width, y: height - r))
        segments.append(CubicBezier(Point(x: width, y: height - r), Point(x: width, y: height - r + k), Point(x: width - r + k, y: height),
                                    Point(x: width - r, y: height)))
        line(Point(x: width - r, y: height), Point(x: r, y: height))
        segments.append(CubicBezier(Point(x: r, y: height), Point(x: r - k, y: height), Point(x: 0, y: height - r + k), Point(x: 0, y: height - r)))
        line(Point(x: 0, y: height - r), Point(x: 0, y: r))
        segments.append(CubicBezier(Point(x: 0, y: r), Point(x: 0, y: r - k), Point(x: r - k, y: 0), Point(x: r, y: 0)))
        return Contour(segments: segments, closed: true)
    }

    /// Equilateral, isosceles, right or scalene, never a sliver (every angle over 15°).
    static func triangle(random: inout SeededRandom) -> [Point] {
        while true {
            let points: [Point]
            switch random.int(0...3) {
            case 0: points = (0..<3).map { Point(x: cos(Double($0) * 2 * .pi / 3 - .pi / 2), y: sin(Double($0) * 2 * .pi / 3 - .pi / 2)) }
            case 1: points = [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0.5, y: random.uniform(0.4...2))]
            case 2: points = [Point(x: 0, y: 0), Point(x: random.uniform(0.4...2), y: 0), Point(x: 0, y: 1)]
            default: points = (0..<3).map { _ in Point(x: random.uniform(0...1), y: random.uniform(0...1)) }
            }
            if minimumAngle(points) > 0.26 { return points }
        }
    }

    static func minimumAngle(_ points: [Point]) -> Double {
        (0..<points.count).map { i in
            let a = points[i], b = points[(i + 1) % points.count], c = points[(i + points.count - 1) % points.count]
            let u = b - a, v = c - a
            guard u.length > 0, v.length > 0 else { return 0 }
            return acos(max(-1, min(1, u.dot(v) / (u.length * v.length))))
        }.min() ?? 0
    }

    /// The Polygon tool's regular 5- to 12-gons, or a convex irregular one.
    static func polygon(random: inout SeededRandom) -> [Point] {
        let sides = random.int(5...12)
        if random.chance(0.6) {
            return (0..<sides).map { Point(x: cos(Double($0) * 2 * .pi / Double(sides) - .pi / 2), y: sin(Double($0) * 2 * .pi / Double(sides) - .pi / 2)) }
        }
        let angles = (0..<sides).map { Double($0) * 2 * .pi / Double(sides) + random.uniform(-0.25...0.25) * 2 * .pi / Double(sides) }.sorted()
        let stretch = random.uniform(1...1.8)
        return angles.map { Point(x: stretch * cos($0) * random.uniform(0.92...1), y: sin($0) * random.uniform(0.92...1)) }
    }

    /// The Star tool: 4 to 12 points, inner radius 25% to 70%.
    static func star(random: inout SeededRandom) -> [Point] {
        let points = random.int(4...12)
        let inner = random.uniform(0.25...0.7)
        return (0..<(2 * points)).map { index in
            let angle = Double(index) * .pi / Double(points) - .pi / 2
            let radius = index % 2 == 0 ? 1 : inner
            return Point(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    /// A block arrow drawn with the Pen: a shaft and a head, sometimes a notched tail or two heads.
    static func arrow(random: inout SeededRandom) -> [Point] {
        let length = random.uniform(1.5...5), shaft = random.uniform(0.2...0.6), head = random.uniform(0.7...1.6)
        let headLength = random.uniform(0.4...1.2) * min(length / 2, 1.2)
        let s = shaft / 2, h = head / 2, neck = length - headLength
        switch random.int(0...2) {
        case 0:
            return [Point(x: 0, y: -s), Point(x: neck, y: -s), Point(x: neck, y: -h), Point(x: length, y: 0), Point(x: neck, y: h), Point(x: neck, y: s),
                    Point(x: 0, y: s)]
        case 1:
            let notch = random.uniform(0.15...0.5) * headLength
            return [Point(x: 0, y: -s), Point(x: neck, y: -s), Point(x: neck, y: -h), Point(x: length, y: 0), Point(x: neck, y: h), Point(x: neck, y: s),
                    Point(x: 0, y: s), Point(x: notch, y: 0)]
        default:
            let back = headLength
            return [Point(x: 0, y: 0), Point(x: back, y: -h), Point(x: back, y: -s), Point(x: neck, y: -s), Point(x: neck, y: -h), Point(x: length, y: 0),
                    Point(x: neck, y: h), Point(x: neck, y: s), Point(x: back, y: s), Point(x: back, y: h)]
        }
    }

    /// The Line tool's segment, a Pen polyline that is nearly straight, or a Pencil stroke's gentle
    /// curve: open, long and thin.
    static func line(random: inout SeededRandom) -> Contour {
        switch random.int(0...2) {
        case 0: return Contour(polygon: [Point(x: 0, y: 0), Point(x: 1, y: 0)], closed: false)
        case 1:
            let count = random.int(3...5)
            return Contour(polygon: (0..<count).map { Point(x: Double($0), y: random.uniform(-0.08...0.08)) }, closed: false)
        default:
            let bend = random.uniform(-0.25...0.25)
            return Contour(segments: [CubicBezier(Point(x: 0, y: 0), Point(x: 0.33, y: bend), Point(x: 0.66, y: -bend * random.uniform(-1...1)),
                                                  Point(x: 1, y: random.uniform(-0.1...0.1)))], closed: false)
        }
    }

    /// A freehand closed curve as the Pencil fits it: a smooth loop whose radius wanders 25% or
    /// more, through 5 to 10 points (Catmull-Rom as cubics).
    static func blob(random: inout SeededRandom) -> Contour {
        let count = random.int(5...10)
        let wander = random.uniform(0.25...0.6)
        let stretch = random.uniform(1...2)
        let points = (0..<count).map { index -> Point in
            let angle = Double(index) * 2 * .pi / Double(count) + random.uniform(-0.2...0.2)
            let radius = 1 + random.uniform(-wander...wander)
            return Point(x: stretch * radius * cos(angle), y: radius * sin(angle))
        }
        return catmullRom(points)
    }

    static func catmullRom(_ points: [Point]) -> Contour {
        let n = points.count
        let segments = (0..<n).map { i -> CubicBezier in
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            return CubicBezier(p1, p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2)
        }
        return Contour(segments: segments, closed: true)
    }

    // MARK: SVG

    /// The path data an SVG file might hold for the class (before placement).
    static func svgShape(_ label: ShapeClass, random: inout SeededRandom) -> String {
        func f(_ value: Double) -> String { String(format: "%.3f", value) }
        func poly(_ points: [Point], relative: Bool, repeatStart: Bool) -> String {
            var d = "M\(f(points[0].x)) \(f(points[0].y))"
            var previous = points[0]
            for p in points.dropFirst() + (repeatStart ? [points[0]] : []) {
                d += relative ? " l\(f(p.x - previous.x)) \(f(p.y - previous.y))" : " L\(f(p.x)) \(f(p.y))"
                previous = p
            }
            return d + (relative ? " z" : " Z")
        }
        switch label {
        case .circle:
            let r = random.uniform(5...50)
            return "M\(f(r)) 0 A\(f(r)) \(f(r)) 0 1 0 \(f(-r)) 0 A\(f(r)) \(f(r)) 0 1 0 \(f(r)) 0 Z"
        case .ellipse:
            let rx = random.uniform(10...60), ry = rx / random.uniform(1.3...4)
            return "M\(f(rx)) 0 a\(f(rx)) \(f(ry)) 0 1 0 \(f(-2 * rx)) 0 a\(f(rx)) \(f(ry)) 0 1 0 \(f(2 * rx)) 0 z"
        case .rectangle:
            let w = random.uniform(10...120), h = w / random.uniform(1...6)
            return random.chance(0.5) ? "M0 0 H\(f(w)) V\(f(h)) H0 Z" : "M0 0 h\(f(w)) v\(f(h)) h\(f(-w)) z"
        case .roundedRectangle:
            let w = random.uniform(20...120), h = w / random.uniform(1...5), r = random.uniform(0.12...0.5) * min(w, h)
            return "M\(f(r)) 0 H\(f(w - r)) A\(f(r)) \(f(r)) 0 0 1 \(f(w)) \(f(r)) V\(f(h - r)) A\(f(r)) \(f(r)) 0 0 1 \(f(w - r)) \(f(h)) "
                + "H\(f(r)) A\(f(r)) \(f(r)) 0 0 1 0 \(f(h - r)) V\(f(r)) A\(f(r)) \(f(r)) 0 0 1 \(f(r)) 0 Z"
        case .triangle: return poly(triangle(random: &random).map { Point(x: $0.x * 50, y: $0.y * 50) }, relative: random.chance(0.5), repeatStart: random.chance(0.3))
        case .polygon: return poly(polygon(random: &random).map { Point(x: $0.x * 50, y: $0.y * 50) }, relative: random.chance(0.5), repeatStart: random.chance(0.3))
        case .star: return poly(star(random: &random).map { Point(x: $0.x * 50, y: $0.y * 50) }, relative: random.chance(0.5), repeatStart: random.chance(0.3))
        case .arrow: return poly(arrow(random: &random).map { Point(x: $0.x * 30, y: $0.y * 30) }, relative: random.chance(0.5), repeatStart: random.chance(0.3))
        case .line:
            let length = random.uniform(20...200)
            switch random.int(0...2) {
            case 0: return "M0 0 L\(f(length)) \(f(random.uniform(-2...2)))"
            case 1: return "M0 0 Q\(f(length / 2)) \(f(random.uniform(-0.2...0.2) * length)) \(f(length)) 0"
            default: return "M0 0 h\(f(length / 2)) l\(f(length / 2)) \(f(random.uniform(-0.05...0.05) * length))"
            }
        case .letterform: return PathData.write(Glyphs.letter(random: &random), quadratic: true)
        default: return PathData.write([blob(random: &random)].map { $0.applying(.scale(40)) }, quadratic: false)
        }
    }
}

/// Letters as Create Outlines makes them: glyph outlines of the system's text faces.  Letters that
/// are nothing but one primitive in some faces (I, l, the vertical bar) are left out.
enum Glyphs {
    static let faces = ["Helvetica", "Times New Roman", "Courier New", "Georgia", "Futura", "Avenir Next", "Gill Sans", "Palatino", "Baskerville",
                        "Menlo", "American Typewriter", "Didot", "Optima", "Verdana", "Trebuchet MS", "Hoefler Text"]
    static let letters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz023456789&?@%$#")

    static func letter(random: inout SeededRandom) -> [Contour] {
        while true {
            let face = faces[random.int(0...(faces.count - 1))]
            let letter = letters[random.int(0...(letters.count - 1))]
            let contours = outline(String(letter), face: face)
            if !contours.isEmpty { return contours }
        }
    }

    static func outline(_ string: String, face: String) -> [Contour] {
        let font = CTFontCreateWithName(face as CFString, 100, nil)
        var characters = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
            return []
        }
        return contours(of: path)
    }

    /// A Core Graphics path as contours (quadratic curves elevated to cubics).
    static func contours(of path: CGPath) -> [Contour] {
        var contours: [Contour] = []
        var segments: [CubicBezier] = []
        var start = Point.zero, current = Point.zero
        func finish(closed: Bool) {
            if !segments.isEmpty { contours.append(Contour(segments: segments, closed: closed)) }
            segments = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            func p(_ i: Int) -> Point { Point(x: Double(e.points[i].x), y: -Double(e.points[i].y)) }
            switch e.type {
            case .moveToPoint:
                finish(closed: false)
                start = p(0)
                current = start
            case .addLineToPoint:
                segments.append(Line(start: current, end: p(0)).elevated())
                current = p(0)
            case .addQuadCurveToPoint:
                segments.append(CubicBezier(quadratic: QuadraticBezier(current, p(0), p(1))))
                current = p(1)
            case .addCurveToPoint:
                segments.append(CubicBezier(current, p(0), p(1), p(2)))
                current = p(2)
            case .closeSubpath:
                if current.distance(to: start) > 1e-9 { segments.append(Line(start: current, end: start).elevated()) }
                finish(closed: true)
                current = start
            @unknown default:
                break
            }
        }
        finish(closed: false)
        return contours
    }
}
