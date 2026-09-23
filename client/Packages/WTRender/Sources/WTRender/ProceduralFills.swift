// Page-anchored procedural paints (ATTR-014, ATTR-018; docs/_includes/appearance/
// fill-attributes.adoc and stroke-attributes.adoc, "Client").  Pattern bitmaps repeat a 2 × 2 pt
// cell (8 × 0.25 pt pixels) anchored to the canvas origin, so adjacent objects tile seamlessly
// and the pattern never scales with the object.  The regular Custom
// fills (Bricks, Circles, Hatch, Squares) are patterns in canvas space rotated by their angle;
// Tiger Teeth, Grass and Leaves are marks laid over the object's bounds (Grass and Leaves from
// PCG32 seeded with `seed`); the noise fills and the eight textures are sampled from hashed
// canvas-coordinate noise, so they are stable across redraws, tiles and collaborators.

import WTGeometry
import CoreGraphics
import Foundation

enum ProceduralFills {
    // MARK: Pattern bitmaps

    /// On screen and in bitmaps, the bitmap's coverage of each device pixel from 4 × 4
    /// samples, drawn pixel for pixel: exact at 4 device pixels per point, area-averaged below
    /// it, and the same in a tile and in the Metal renderer's offscreen.  (A Core Graphics
    /// pattern or a sampled image would be the natural choice, but Core Graphics resamples
    /// either in a way that depends on where the drawing starts, which moved quarter-point
    /// pixels between a tile and an offscreen of the same pixels under rotation.)  PDF output
    /// keeps the pattern vector: a Core Graphics pattern with a 2 × 2 pt cell.
    static func fill(_ pattern: PatternPaint, in context: CGContext, environment: PaintEnvironment) {
        guard !pattern.bitmap.isEmpty else {
            return
        }
        let bitmap = pattern.bitmap
        let pixel = PatternPaint.pixelSize
        guard environment.rasterScale <= 1 else {
            let color = pattern.color.cg
            var rects: [CGRect] = []
            for y in 0..<8 {
                for x in 0..<8 where bitmap.isPainted(x: x, y: y) {
                    rects.append(CGRect(x: Double(x) * pixel, y: Double(y) * pixel, width: pixel, height: pixel))
                }
            }
            PaintDrawing.fillPattern(in: context, bounds: CGRect(x: 0, y: 0, width: 8 * pixel, height: 8 * pixel), matrix: environment.canvasToBase, step: CGSize(width: 8 * pixel, height: 8 * pixel)) { cell in
                cell.setFillColor(color)
                cell.fill(rects)
            }
            return
        }
        let color = SIMD4(pattern.color.red, pattern.color.green, pattern.color.blue, pattern.color.alpha)
        let clear = SIMD4<Double>(0, 0, 0, 0)
        let space = PaintDrawing.canvasToUser(context, environment: environment)
        RasterPaint.fillDevice(context, space: space, supersample: 4) { point in
            let x = Int(floor(point.x / pixel)) & 7
            let y = Int(floor(point.y / pixel)) & 7
            return bitmap.isPainted(x: x, y: y) ? color : clear
        }
    }

    // MARK: Custom fills

    /// A length, or the default when it is not positive.
    static func length(_ value: Double, default fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }

    static func fill(_ custom: CustomFill, bounds: Rect, in context: CGContext, environment: PaintEnvironment) {
        let angle = (custom.angle.isFinite ? custom.angle : 0) * Double.pi / 180
        switch custom.pattern {
        case .blackWhiteNoise:
            sampled(in: context, environment: environment, interpolation: .none) { point in
                let value = NoiseHash.value(Int(floor(point.x * 2)), Int(floor(point.y * 2)), salt: 1) < 0.5 ? 0.0 : 1.0
                return SIMD4(value, value, value, 1)
            }
        case .noise:
            let whiteness = min(max(custom.whiteness.isFinite ? custom.whiteness : 0, 0), 100) / 100
            sampled(in: context, environment: environment, interpolation: .none) { point in
                let value = whiteness * NoiseHash.value(Int(floor(point.x * 2)), Int(floor(point.y * 2)), salt: 2)
                return SIMD4(value, value, value, 1)
            }
        case .topNoise:
            let gray = min(max(custom.whiteness.isFinite ? custom.whiteness : 0, 0), 100) / 100
            sampled(in: context, environment: environment, interpolation: .none) { point in
                let hit = NoiseHash.value(Int(floor(point.x * 2)), Int(floor(point.y * 2)), salt: 3) < 0.3
                return hit ? SIMD4(gray, gray, gray, 1) : SIMD4(0, 0, 0, 0)
            }
        case .bricks:
            let width = length(custom.width, default: 16)
            let height = length(custom.height, default: 8)
            let mortar = max(0.5, 0.12 * min(width, height))
            let brick = custom.color.cg
            let joint = custom.color2.cg
            canvasPattern(in: context, environment: environment, angle: angle, cell: CGSize(width: width, height: 2 * height)) { cell in
                cell.setFillColor(joint)
                cell.fill(CGRect(x: 0, y: 0, width: width, height: 2 * height))
                cell.setFillColor(brick)
                let inset = mortar / 2
                cell.fill([
                    CGRect(x: inset, y: inset, width: width - mortar, height: height - mortar),
                    CGRect(x: -width / 2 + inset, y: height + inset, width: width - mortar, height: height - mortar),
                    CGRect(x: width / 2 + inset, y: height + inset, width: width - mortar, height: height - mortar),
                ])
            }
        case .circles:
            let radius = length(custom.radius, default: 3)
            let spacing = length(custom.spacing, default: 10)
            let color = custom.color.cg
            canvasPattern(in: context, environment: environment, angle: angle, cell: CGSize(width: spacing, height: spacing)) { cell in
                cell.setFillColor(color)
                // Circles wider than the spacing overlap the neighbouring cells: draw the
                // neighbours' too.
                for dx in -1...1 {
                    for dy in -1...1 {
                        cell.fillEllipse(in: CGRect(x: spacing / 2 + Double(dx) * spacing - radius, y: spacing / 2 + Double(dy) * spacing - radius, width: 2 * radius, height: 2 * radius))
                    }
                }
            }
        case .hatch:
            let spacing = length(custom.spacing, default: 6)
            let line = min(length(custom.width, default: 1), spacing)
            let color = custom.color.cg
            for set in [angle, (custom.angle2.isFinite ? custom.angle2 : 0) * Double.pi / 180] {
                canvasPattern(in: context, environment: environment, angle: set, cell: CGSize(width: spacing, height: spacing)) { cell in
                    cell.setFillColor(color)
                    cell.fill(CGRect(x: 0, y: (spacing - line) / 2, width: spacing, height: line))
                }
            }
        case .squares:
            let side = length(custom.side, default: 5)
            let spacing = length(custom.spacing, default: 10)
            let outline = custom.width.isFinite ? max(custom.width, 0) : 0
            let color = custom.color.cg
            canvasPattern(in: context, environment: environment, angle: angle, cell: CGSize(width: spacing, height: spacing)) { cell in
                let square = CGRect(x: (spacing - side) / 2, y: (spacing - side) / 2, width: side, height: side)
                if outline > 0 {
                    cell.setStrokeColor(color)
                    cell.setLineWidth(outline)
                    cell.setLineJoin(.miter)
                    cell.stroke(square)
                } else {
                    cell.setFillColor(color)
                    cell.fill(square)
                }
            }
        case .tigerTeeth:
            tigerTeeth(custom, bounds: bounds, angle: angle, in: context)
        case .randomGrass:
            marks(custom, bounds: bounds, leaves: false, in: context)
        case .randomLeaves:
            marks(custom, bounds: bounds, leaves: true, in: context)
        }
    }

    /// A pattern of `cell` (drawn in cell coordinates) in canvas space rotated by `angle`.
    static func canvasPattern(in context: CGContext, environment: PaintEnvironment, angle: Double, cell: CGSize, draw: @escaping (CGContext) -> Void) {
        let matrix = CGAffineTransform(rotationAngle: angle).concatenating(environment.canvasToBase)
        PaintDrawing.fillPattern(in: context, bounds: CGRect(origin: .zero, size: cell), matrix: matrix, step: cell, draw: draw)
    }

    /// Tiger Teeth: the object's bounds (rotated by the angle) in the background colour with
    /// `count` interlocking teeth hanging from the top edge, each reaching three quarters of
    /// the way down.
    static func tigerTeeth(_ custom: CustomFill, bounds: Rect, angle: Double, in context: CGContext) {
        let count = min(max(custom.count, 1), 700)
        context.saveGState()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        // The rotated frame must still cover the bounds: use the circumscribed square.
        let half = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() / 2 + 1
        context.setFillColor(custom.color2.cg)
        context.fill(CGRect(x: -half, y: -half, width: 2 * half, height: 2 * half))
        context.setFillColor(custom.color.cg)
        let tooth = 2 * half / Double(count)
        let path = CGMutablePath()
        for index in 0..<count {
            let x = -half + Double(index) * tooth
            path.move(to: CGPoint(x: x, y: -half))
            path.addLine(to: CGPoint(x: x + tooth, y: -half))
            path.addLine(to: CGPoint(x: x + tooth / 2, y: half / 2))
            path.closeSubpath()
        }
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// Random Grass and Random Leaves: `count` marks placed once per fill over the object's
    /// bounds from PCG32 seeded with `seed`, each a fixed size on the page.
    static func marks(_ custom: CustomFill, bounds: Rect, leaves: Bool, in context: CGContext) {
        let count = min(max(custom.count, 1), 32_000)
        var random = PCG32(seed: custom.seed)
        let grass = [Color(red: 0.24, green: 0.52, blue: 0.16), Color(red: 0.36, green: 0.62, blue: 0.2), Color(red: 0.18, green: 0.42, blue: 0.12)]
        let foliage = [Color(red: 0.3, green: 0.55, blue: 0.15), Color(red: 0.62, green: 0.6, blue: 0.12), Color(red: 0.55, green: 0.33, blue: 0.1)]
        for _ in 0..<count {
            let x = bounds.minX + random.nextUnit() * bounds.width
            let y = bounds.minY + random.nextUnit() * bounds.height
            let size = 4 + random.nextUnit() * 6
            let turn = (random.nextUnit() - 0.5) * (leaves ? 2 * Double.pi : 0.8)
            let shade = Int(random.nextUnit() * 3) % 3
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: turn)
            let path = CGMutablePath()
            if leaves {
                path.move(to: CGPoint(x: -size / 2, y: 0))
                path.addQuadCurve(to: CGPoint(x: size / 2, y: 0), control: CGPoint(x: 0, y: -size / 2.5))
                path.addQuadCurve(to: CGPoint(x: -size / 2, y: 0), control: CGPoint(x: 0, y: size / 2.5))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(foliage[shade].cg)
                context.setStrokeColor(Color(red: 0.15, green: 0.2, blue: 0.05).cg)
                context.setLineWidth(0.3)
                context.drawPath(using: .fillStroke)
            } else {
                path.move(to: CGPoint(x: -0.6, y: 0))
                path.addQuadCurve(to: CGPoint(x: 1.5, y: -size * 1.4), control: CGPoint(x: -0.2, y: -size))
                path.addQuadCurve(to: CGPoint(x: 0.6, y: 0), control: CGPoint(x: 0.4, y: -size * 0.9))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(grass[shade].cg)
                context.fillPath()
            }
            context.restoreGState()
        }
    }

    // MARK: Textures

    static func fill(_ textured: TexturedFill, in context: CGContext, environment: PaintEnvironment) {
        let color = textured.color
        let texture = textured.texture
        sampled(in: context, environment: environment, interpolation: .low) { point in
            let shade = ProceduralFills.shade(texture, at: point)
            // Dark to light around the colour: 55% of it at 0, a third of the way to white at 1.
            func channel(_ c: Double) -> Double {
                shade < 0.5 ? c * (0.55 + 0.9 * shade) : c + (1 - c) * (shade - 0.5) * 0.66
            }
            return SIMD4(channel(color.red), channel(color.green), channel(color.blue), color.alpha)
        }
    }

    /// The texture's lightness at a canvas point, 0 ... 1.
    static func shade(_ texture: Texture, at point: Point) -> Double {
        let x = point.x
        let y = point.y
        switch texture {
        case .burlap:
            let weave = 0.5 + 0.25 * (sin(2 * Double.pi * x / 1.6) * sin(2 * Double.pi * y / 1.6))
            return min(max(weave + 0.35 * (NoiseHash.fractal(x / 1.5, y / 1.5, salt: 11) - 0.5), 0), 1)
        case .denim:
            let twill = 0.5 + 0.3 * sin(2 * Double.pi * (x + y) / 0.9)
            return min(max(twill + 0.4 * (NoiseHash.fractal(x / 0.8, y / 6, salt: 12) - 0.5), 0), 1)
        case .gravel:
            // Distance to the nearest jittered point in 2.5 pt cells: pebbles.
            let cell = 2.5
            let cx = Int(floor(x / cell))
            let cy = Int(floor(y / cell))
            var nearest = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    let px = (Double(cx + dx) + NoiseHash.value(cx + dx, cy + dy, salt: 13)) * cell
                    let py = (Double(cy + dy) + NoiseHash.value(cx + dx, cy + dy, salt: 14)) * cell
                    nearest = min(nearest, ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot())
                }
            }
            return min(max(1 - nearest / cell, 0), 1)
        case .marble:
            return 0.5 + 0.5 * sin(x / 3 + 6 * NoiseHash.fractal(x / 10, y / 10, salt: 15))
        case .mesh:
            let u = x / 3 - floor(x / 3)
            let v = y / 3 - floor(y / 3)
            return (u < 0.18 || v < 0.18) ? 0.95 : 0.3
        case .oak:
            let grain = y / 2.5 + 3 * NoiseHash.fractal(x / 24, y / 6, salt: 16)
            return 0.35 + 0.5 * (grain - floor(grain))
        case .sand:
            return 0.35 + 0.65 * NoiseHash.value(Int(floor(x * 2)), Int(floor(y * 2)), salt: 17)
        case .stucco:
            let blotch = NoiseHash.fractal(x / 4, y / 4, salt: 18)
            return blotch > 0.55 ? 0.85 : 0.35 + blotch
        }
    }

    /// A paint sampled in canvas space.
    static func sampled(in context: CGContext, environment: PaintEnvironment, interpolation: CGInterpolationQuality, sample: (Point) -> SIMD4<Double>) {
        let space = PaintDrawing.canvasToUser(context, environment: environment)
        RasterPaint.fill(context, space: space, rasterScale: environment.rasterScale, interpolation: interpolation, sample: sample)
    }
}
