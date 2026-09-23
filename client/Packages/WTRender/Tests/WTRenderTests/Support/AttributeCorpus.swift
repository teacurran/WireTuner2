// The ATTR golden corpus: the stack kinds of ATTR-004, dashes and arrowheads through GEO-003
// outlines (ATTR-007), brush, calligraphic, custom and pattern strokes (ATTR-010 ... ATTR-014),
// custom, textured, lens and tiled fills (ATTR-018, ATTR-019, ATTR-021) and every gradient type
// and behaviour (ATTR-027).  Each case joins `ReferenceCorpus.cases`, so it has goldens at 1× and
// 4× and runs through REND-007's Metal/Core Graphics parity.

import WTGeometry
import CoreGraphics
import Foundation
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

enum AttributeCorpus {
    typealias C = ReferenceCorpus

    /// The cell `column`, `row` of a grid of `width` × `height` cells, inset by `inset`.
    static func cell(_ column: Int, _ row: Int, width: Double, height: Double, inset: Double = 6) -> Rect {
        Rect(x: Double(column) * width + inset, y: Double(row) * height + inset, width: width - 2 * inset, height: height - 2 * inset)
    }

    static func fill(_ paint: Paint, rule: FillRule = .nonZero, overprint: Bool = false) -> AppearanceItem {
        .fill(FillPaint(paint: paint, rule: rule, overprint: overprint))
    }

    static func stroke(_ paint: Paint, width: Double, kind: StrokeKind = .basic, cap: LineCap = .butt, join: LineJoin = .miter) -> AppearanceItem {
        .stroke(StrokePaint(paint: paint, style: StrokeStyle(width: width, cap: cap, join: join), kind: kind))
    }

    static func wave(in rect: Rect) -> DisplayPath {
        var path = DisplayPath()
        path.move(to: Point(x: rect.minX, y: rect.midY))
        path.addCubicCurve(control1: Point(x: rect.minX + rect.width / 3, y: rect.minY), control2: Point(x: rect.minX + 2 * rect.width / 3, y: rect.maxY), to: Point(x: rect.maxX, y: rect.midY))
        return path
    }

    /// Artwork beneath the lenses: stripes and shapes in several colours with page between.
    static let backdrop: [DisplayItem] = [
        C.path(DisplayPath(rect: Rect(x: 8, y: 10, width: 300, height: 14)), [C.fill(C.orange)]),
        C.path(DisplayPath(rect: Rect(x: 8, y: 40, width: 300, height: 14)), [C.fill(C.cyan)]),
        C.path(DisplayPath(rect: Rect(x: 8, y: 70, width: 300, height: 14)), [C.fill(C.magenta)]),
        C.path(DisplayPath(ellipseIn: Rect(x: 20, y: 96, width: 60, height: 40)), [C.fill(C.yellow), C.stroke(.black, width: 2)]),
        C.path(DisplayPath(ellipseIn: Rect(x: 130, y: 96, width: 60, height: 40)), [C.fill(blue), C.stroke(.black, width: 2)]),
        C.path(DisplayPath(ellipseIn: Rect(x: 240, y: 96, width: 60, height: 40)), [C.fill(green), C.stroke(.black, width: 2)]),
    ]

    static let brushSymbol = BrushSymbol(items: [
        .path(PathItem(path: DisplayPath(polygon: [Point(x: 0, y: -4), Point(x: 10, y: 0), Point(x: 0, y: 4)]), appearance: Appearance([.fill(FillPaint(paint: .solid(blue)))]))),
        .path(PathItem(path: DisplayPath(ellipseIn: Rect(x: -2, y: -2, width: 4, height: 4)), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))]))),
    ])

    static func brush(_ mode: BrushMode, variation: VariationMode, orient: Bool = true) -> Brush {
        let varied = BrushVariation(mode: variation, value: 100, min: 50, max: 150)
        switch mode {
        case .spray:
            return Brush(
                mode: .spray,
                symbols: [brushSymbol],
                orientOnPath: orient,
                spacing: variation == .flare ? .fixed(120) : BrushVariation(mode: variation, value: 120, min: 80, max: 200),
                angle: variation == .flare ? .fixed(0) : BrushVariation(mode: variation, value: 0, min: -30, max: 30),
                offset: variation == .fixed ? .fixed(0) : BrushVariation(mode: variation, value: 0, min: -60, max: 60),
                scaling: variation == .flare ? BrushVariation(mode: .variable, value: 100, min: 60, max: 140) : varied
            )
        case .paint:
            return Brush(mode: .paint, count: 6, symbols: [brushSymbol], orientOnPath: orient, scaling: varied)
        }
    }

    static func brushRows(_ mode: BrushMode) -> [DisplayItem] {
        let modes: [VariationMode] = [.fixed, .random, .variable, .flare]
        return modes.enumerated().map { row, variation in
            let rect = Rect(x: 12, y: 12 + Double(row) * 44, width: 232, height: 30)
            let stroke = BrushStroke(brush: brush(mode, variation: variation), widthPercent: 120, seed: 0xB0B0 + UInt64(row))
            return C.path(wave(in: rect), [.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 1), kind: .brush(stroke)))])
        }
    }

    static let starNib = DisplayPath(polygon: [Point(x: 0.5, y: 0), Point(x: -0.35, y: 0.35), Point(x: -0.1, y: 0), Point(x: -0.35, y: -0.35)])

    static let zigzagPath = C.zigzag(x: 20, y: 110, width: 210, height: 60)

    static let calligraphy = C.list([
        C.path(wave(in: Rect(x: 20, y: 14, width: 210, height: 40)), [stroke(.solid(.black), width: 1, kind: .calligraphic(CalligraphicNib(width: 12, height: 4, angle: 30)))]),
        C.path(wave(in: Rect(x: 20, y: 64, width: 210, height: 40)), [stroke(.solid(blue), width: 1, kind: .calligraphic(CalligraphicNib(width: 14, height: 1, angle: -45)))]),
        C.path(zigzagPath, [stroke(.solid(red.withAlpha(multipliedBy: 0.7)), width: 1, kind: .calligraphic(CalligraphicNib(width: 12, height: 12, angle: 15, shape: starNib)))]),
    ])

    /// The 23 custom strokes on `shape` paths laid out in a grid of five columns.
    static func customStrokes(_ shape: (Rect) -> DisplayPath) -> DisplayList {
        C.list(CustomStrokePattern.allCases.enumerated().map { index, pattern in
            let rect = cell(index % 5, index / 5, width: 64, height: 48, inset: 8)
            let stroke = StrokePaint(paint: .solid(index.isMultiple(of: 2) ? .black : blue), style: StrokeStyle(width: 8), kind: .custom(CustomStroke(pattern: pattern, length: 10, spacing: 2)))
            return C.path(shape(rect), [.stroke(stroke)])
        })
    }

    static let customFillsVector: [CustomFill] = [
        CustomFill(pattern: .bricks, color: Color(red: 0.7, green: 0.25, blue: 0.15), color2: Color(white: 0.85), width: 14, height: 7, angle: 0),
        CustomFill(pattern: .circles, color: blue, radius: 3, spacing: 9, angle: 20),
        CustomFill(pattern: .hatch, color: .black, width: 1, spacing: 6, angle: 45, angle2: -45),
        CustomFill(pattern: .squares, color: green, width: 1, side: 5, spacing: 10, angle: 15),
        CustomFill(pattern: .tigerTeeth, color: C.orange, color2: .black, angle: 10, count: 7),
        CustomFill(pattern: .randomGrass, count: 60, seed: 7),
        CustomFill(pattern: .randomLeaves, count: 40, seed: 11),
        CustomFill(pattern: .squares, color: red, width: 0, side: 3, spacing: 6),
    ]

    static let customFillsNoise: [CustomFill] = [
        CustomFill(pattern: .blackWhiteNoise),
        CustomFill(pattern: .noise, whiteness: 80),
        CustomFill(pattern: .topNoise, whiteness: 30),
    ]

    static func fillGrid(_ paints: [Paint], columns: Int, width: Double = 64, height: Double = 64, backdrop: Bool = true) -> DisplayList {
        var items: [DisplayItem] = []
        if backdrop {
            // A diagonal band beneath shows which fills are opaque.
            items.append(C.path(DisplayPath(polygon: [Point(x: 0, y: 40), Point(x: 40, y: 0), Point(x: 400, y: 360), Point(x: 360, y: 400)]), [C.fill(C.yellow)]))
        }
        for (index, paint) in paints.enumerated() {
            let rect = cell(index % columns, index / columns, width: width, height: height)
            items.append(C.path(DisplayPath(ellipseIn: rect), [fill(paint), C.stroke(.black, width: 1)]))
        }
        return C.list(items)
    }

    static let tile: [DisplayItem] = [
        C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 12, height: 12)), [C.fill(C.yellow)]),
        C.path(DisplayPath(ellipseIn: Rect(x: 2, y: 2, width: 8, height: 8)), [C.fill(C.magenta), C.stroke(.black, width: 1)]),
        C.path(C.line(0, 12, 12, 0), [C.stroke(blue, width: 1.5)]),
    ]

    /// A simple (not self-intersecting) five-point star.
    static func concaveStar(center: Point, outer: Double, inner: Double) -> DisplayPath {
        DisplayPath(polygon: (0..<10).map { index in
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
            return Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        })
    }

    static func gradientGrid() -> DisplayList {
        var items: [DisplayItem] = []
        let behaviors: [Gradient.Behavior] = [.normal, .repeat, .reflect, .autoSize]
        for (row, behavior) in behaviors.enumerated() {
            for (column, kind) in Gradient.Kind.allCases.enumerated() {
                let rect = cell(column, row, width: 64, height: 56, inset: 4)
                let center = Point(x: rect.midX, y: rect.midY)
                let axis: Gradient.Axis
                switch kind {
                case .linear, .logarithmic:
                    axis = Gradient.Axis(start: Point(x: rect.minX + 6, y: rect.minY + 6), end: Point(x: rect.maxX - 10, y: rect.maxY - 12))
                case .radial, .rectangle:
                    axis = Gradient.Axis(start: center, end: center + Vector(24, 6), end2: center + Vector(-4, 16))
                case .contour:
                    axis = Gradient.Axis(start: center, end: center + Vector(22, 0))
                case .cone:
                    axis = Gradient.Axis(start: center, end: center + Vector(10, -10))
                }
                let gradient = Gradient(kind: kind, behavior: behavior, repeatCount: 3, axis: axis, stops: [
                    Gradient.Stop(offset: 0, color: red),
                    Gradient.Stop(offset: 0.5, color: C.yellow),
                    Gradient.Stop(offset: 1, color: blue),
                ])
                let shape = kind == .contour ? concaveStar(center: center, outer: 26, inner: 13) : DisplayPath(rect: rect)
                items.append(C.path(shape, [fill(.gradient(gradient))]))
            }
        }
        return C.list(items)
    }

    static let cases: [ReferenceCase] = [
        // ATTR-004
        ReferenceCase(name: "hiddenMiddleElement", list: C.list([
            .path(PathItem(path: DisplayPath(ellipseIn: Rect(x: 14, y: 14, width: 100, height: 68)), appearance: Appearance(stack: [
                StackElement(C.fill(C.orange)),
                StackElement(C.stroke(.black, width: 14), hidden: true),
                StackElement(C.stroke(.white, width: 4)),
            ]))),
        ])),
        ReferenceCase(name: "noneFillNoneStrokeStack", list: C.list([
            C.path(DisplayPath(rect: Rect(x: 20, y: 16, width: 88, height: 64)), [C.stroke(.black, width: 12), .fill(FillPaint(paint: .none)), C.stroke(C.yellow, width: 6), fill(.solid(blue.withAlpha(multipliedBy: 0.4)))]),
        ])),
        // ATTR-007
        ReferenceCase(name: "dashPresets", list: C.list(DashPreset.builtIns.enumerated().flatMap { row, preset in
            [1.0, 2, 4].enumerated().map { column, width in
                C.path(C.line(8 + Double(column) * 84, 12 + Double(row) * 24, 80 + Double(column) * 84, 12 + Double(row) * 24), [C.stroke(.black, width: width, dash: preset.lengths.map { $0 * width })])
            }
        }), viewSize: Size(width: 256, height: 176)),
        ReferenceCase(name: "arrowheadPresets", list: C.list(Arrowhead.builtIns.enumerated().flatMap { row, head in
            [1.0, 2, 4].enumerated().map { column, width in
                C.path(C.line(20 + Double(column) * 84, 14 + Double(row) * 34, 70 + Double(column) * 84, 14 + Double(row) * 34), [C.stroke(.black, width: width, start: head, end: head)])
            }
        }), viewSize: Size(width: 256, height: 176)),
        ReferenceCase(name: "arrowheadEdgeCases", list: C.list([
            // One segment: both heads, the trimmed body between them.
            C.path(C.line(20, 20, 60, 20), [C.stroke(.black, width: 4, start: .triangle, end: .triangle)]),
            // A closed path ignores its heads.
            C.path(DisplayPath(rect: Rect(x: 76, y: 10, width: 40, height: 22)), [C.stroke(blue, width: 3, start: .triangle, end: .triangle)]),
            // Round caps and joins under open heads on a dashed curve.
            C.path(wave(in: Rect(x: 16, y: 44, width: 96, height: 40)), [C.stroke(red, width: 3, cap: .round, join: .round, dash: [6, 3], start: .open, end: .bar)]),
        ])),
        // ATTR-010
        ReferenceCase(name: "brushSpray", list: C.list(brushRows(.spray)), viewSize: Size(width: 256, height: 184)),
        ReferenceCase(name: "brushPaint", list: C.list(brushRows(.paint)), viewSize: Size(width: 256, height: 184)),
        ReferenceCase(name: "brushFolded", list: C.list([
            C.path(zigzagPath.applying(.translation(x: 0, y: -96)), [.stroke(StrokePaint(paint: .solid(.black), kind: .brush(BrushStroke(brush: Brush(mode: .paint, count: 3, symbols: [brushSymbol], foldCorners: true), seed: 3))))]),
            C.path(DisplayPath(rect: Rect(x: 20, y: 96, width: 90, height: 40)), [.stroke(StrokePaint(paint: .solid(.black), kind: .brush(BrushStroke(brush: brush(.spray, variation: .fixed, orient: false), widthPercent: 80, seed: 4))))]),
            // The brush is gone: the cached Basic stroke draws.
            C.path(DisplayPath(rect: Rect(x: 140, y: 96, width: 90, height: 40)), [.stroke(StrokePaint(paint: .solid(red), style: StrokeStyle(width: 3), kind: .brush(BrushStroke(brush: nil))))]),
        ]), viewSize: Size(width: 256, height: 160)),
        // ATTR-011
        ReferenceCase(name: "calligraphic", list: calligraphy, viewSize: Size(width: 256, height: 184)),
        // ATTR-012
        ReferenceCase(name: "customStrokesStraight", list: customStrokes { rect in C.line(rect.minX, rect.midY, rect.maxX, rect.midY) }, viewSize: Size(width: 320, height: 240)),
        ReferenceCase(name: "customStrokesCurved", list: customStrokes { rect in wave(in: rect) }, viewSize: Size(width: 320, height: 240)),
        ReferenceCase(name: "customStrokesClosed", list: customStrokes { rect in DisplayPath(ellipseIn: rect) }, viewSize: Size(width: 320, height: 240)),
        // ATTR-014
        ReferenceCase(name: "patterns", list: C.list([
            C.path(DisplayPath(rect: Rect(x: 8, y: 8, width: 56, height: 40)), [fill(.pattern(PatternPaint(bitmap: .checker, color: .black)))]),
            C.path(DisplayPath(rect: Rect(x: 64, y: 8, width: 56, height: 40)), [fill(.pattern(PatternPaint(bitmap: .diagonal, color: blue)))]),
            C.path(DisplayPath(rect: Rect(x: 8, y: 48, width: 56, height: 40)), [fill(.pattern(PatternPaint(bitmap: .horizontal, color: red)))]),
            C.path(DisplayPath(ellipseIn: Rect(x: 64, y: 48, width: 56, height: 40)), [fill(.pattern(PatternPaint(bitmap: .dots, color: green)))]),
            C.path(C.zigzag(x: 14, y: 20, width: 100, height: 56), [.stroke(StrokePaint(paint: .pattern(PatternPaint(bitmap: .checker, color: C.magenta)), style: StrokeStyle(width: 10, cap: .round, join: .round)))]),
        ]), comparesPDF: false),
        // ATTR-018
        ReferenceCase(name: "customFills", list: fillGrid(customFillsVector.map { .custom($0) }, columns: 4), viewSize: Size(width: 256, height: 128)),
        ReferenceCase(name: "customFillsNoise", list: fillGrid(customFillsNoise.map { .custom($0) }, columns: 3), viewSize: Size(width: 192, height: 64), comparesPDF: false),
        ReferenceCase(name: "textures", list: fillGrid(Texture.allCases.map { .textured(TexturedFill(texture: $0, color: Color(red: 0.55, green: 0.4, blue: 0.25))) }, columns: 4, backdrop: false), viewSize: Size(width: 256, height: 128), comparesPDF: false),
        // ATTR-019
        ReferenceCase(name: "lenses", list: C.list(backdrop + LensType.allCases.enumerated().map { index, type in
            let rect = Rect(x: 12 + Double(index % 3) * 100, y: 18 + Double(index / 3) * 70, width: 84, height: 56)
            let lens = LensFill(type: type, color: type == .monochrome ? blue : C.magenta, amount: 60, magnification: 2.5)
            return C.path(DisplayPath(ellipseIn: rect), [fill(.lens(lens)), C.stroke(.black, width: 1)])
        }), viewSize: Size(width: 320, height: 150), comparesPDF: false),
        ReferenceCase(name: "lensOptions", list: C.list(backdrop + [
            // Objects only: an invert lens leaves the page white.
            C.path(DisplayPath(rect: Rect(x: 20, y: 30, width: 80, height: 100)), [fill(.lens(LensFill(type: .invert, objectsOnly: true))), C.stroke(.black, width: 1)]),
            // Centerpoint away from the middle.
            C.path(DisplayPath(ellipseIn: Rect(x: 120, y: 20, width: 80, height: 80)), [fill(.lens(LensFill(type: .magnify, magnification: 3, centerpoint: Point(x: 140, y: 47)))), C.stroke(.black, width: 1)]),
            // A snapshot shows the captured items wherever the lens is.
            C.path(DisplayPath(ellipseIn: Rect(x: 220, y: 30, width: 80, height: 80)), [fill(.lens(LensFill(type: .darken, amount: 30, snapshot: [
                C.path(DisplayPath(rect: Rect(x: 220, y: 30, width: 80, height: 40)), [C.fill(green)]),
            ]))), C.stroke(.black, width: 1)]),
        ]), viewSize: Size(width: 320, height: 150), comparesPDF: false),
        // ATTR-021
        ReferenceCase(name: "tiledFills", list: C.list([
            C.path(DisplayPath(rect: Rect(x: 8, y: 8, width: 70, height: 60)), [fill(.tiled(TiledFill(tile: tile))), C.stroke(.black, width: 1)]),
            C.path(DisplayPath(ellipseIn: Rect(x: 88, y: 8, width: 70, height: 60)), [fill(.tiled(TiledFill(tile: tile, angle: 30))), C.stroke(.black, width: 1)]),
            C.path(DisplayPath(rect: Rect(x: 168, y: 8, width: 70, height: 60)), [fill(.tiled(TiledFill(tile: tile, scaleX: 150, scaleY: 75))), C.stroke(.black, width: 1)]),
            C.path(DisplayPath(rect: Rect(x: 8, y: 78, width: 70, height: 60)), [fill(.tiled(TiledFill(tile: tile, offset: Point(x: 5, y: -3)))), C.stroke(.black, width: 1)]),
            .path(PathItem(path: DisplayPath(rect: Rect(x: -35, y: -30, width: 70, height: 60)), appearance: Appearance([fill(.tiled(TiledFill(tile: tile, angle: -15, scaleX: 80, scaleY: 80)))]), transform: AffineTransform.rotation(degrees: 20).concatenating(.translation(x: 128, y: 108)))),
        ]), viewSize: Size(width: 256, height: 150)),
        // ATTR-027
        ReferenceCase(name: "gradients", list: gradientGrid(), viewSize: Size(width: 384, height: 224), comparesPDF: false),
        ReferenceCase(name: "gradientsOKLab", list: C.list([
            C.path(DisplayPath(rect: Rect(x: 8, y: 8, width: 112, height: 24)), [fill(.gradient(Gradient(.linear, from: red, to: blue, axis: Gradient.Axis(start: Point(x: 8, y: 0), end: Point(x: 120, y: 0)))))]),
            C.path(DisplayPath(rect: Rect(x: 8, y: 36, width: 112, height: 24)), [fill(.gradient(Gradient(.logarithmic, from: .black, to: .white, axis: Gradient.Axis(start: Point(x: 8, y: 0), end: Point(x: 120, y: 0)))))]),
            C.path(DisplayPath(ellipseIn: Rect(x: 8, y: 64, width: 112, height: 28)), [fill(.gradient(Gradient(.radial, from: C.yellow, to: C.magenta.withAlpha(multipliedBy: 0.2))))]),
        ])),
    ]
}
