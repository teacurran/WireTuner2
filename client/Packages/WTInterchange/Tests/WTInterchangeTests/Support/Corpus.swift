// The export corpus: display lists covering what the exporters must write -- fills and strokes of
// every basic kind, transparency, clips, gradients of every type and behaviour, sampled paints,
// lenses, live vector and raster effects, gradient masks, non-Basic strokes, live groups, text
// and images -- plus helpers to build scenes and compare renderings.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import WTGeometry
@testable import WTInterchange
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// Foundation, WTGeometry, WTRender and WTInterchange all name an `AffineTransform`; tests mean
/// the display list's.
typealias AffineTransform = WTGeometry.AffineTransform

enum Corpus {
    static let red = Color(red: 0.9, green: 0.1, blue: 0.1)
    static let blue = Color(red: 0.1, green: 0.3, blue: 0.9)
    static let green = Color(red: 0.1, green: 0.7, blue: 0.3)
    static let yellow = Color(red: 0.95, green: 0.85, blue: 0.1)

    static func fill(_ paint: Paint, rule: FillRule = .nonZero, overprint: Bool = false) -> AppearanceItem {
        .fill(FillPaint(paint: paint, rule: rule, overprint: overprint))
    }

    static func stroke(_ paint: Paint, width: Double, cap: LineCap = .butt, join: LineJoin = .miter, dash: [Double] = [], kind: StrokeKind = .basic, start: Arrowhead? = nil, end: Arrowhead? = nil) -> AppearanceItem {
        .stroke(StrokePaint(paint: paint, style: StrokeStyle(width: width, cap: cap, join: join, dash: dash), startArrowhead: start, endArrowhead: end, kind: kind))
    }

    static func path(_ path: DisplayPath, _ items: [AppearanceItem], effects: [EffectElement] = [], transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(items, effects: effects), transform: transform))
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DisplayPath {
        DisplayPath(rect: Rect(x: x, y: y, width: w, height: h))
    }

    static func ellipse(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DisplayPath {
        DisplayPath(ellipseIn: Rect(x: x, y: y, width: w, height: h))
    }

    static func wave(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DisplayPath {
        var path = DisplayPath()
        path.move(to: Point(x: x, y: y + h / 2))
        path.addCubicCurve(control1: Point(x: x + w / 3, y: y), control2: Point(x: x + 2 * w / 3, y: y + h), to: Point(x: x + w, y: y + h / 2))
        return path
    }

    static func page(_ items: [DisplayItem], width: Double = 200, height: Double = 150, nodes: [NodeID?] = [], background: Color? = nil, name: String? = nil) -> ExportPage {
        ExportPage(name: name, bounds: Rect(x: 0, y: 0, width: width, height: height), displayList: DisplayList(canvas: "page", items: items, nodeIDs: nodes), background: background)
    }

    static func scene(_ pages: [ExportPage], nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:], info: ExportDocumentInfo = ExportDocumentInfo(), ppi: Double = 144) -> ExportScene {
        ExportScene(name: "Corpus", pages: pages, info: info, nodes: nodes, assets: assets, rasterResolution: ppi)
    }

    static func node(_ counter: UInt64) -> NodeID {
        NodeID(counter: counter, replica: 1)
    }

    // MARK: Text

    /// A glyph run of `text` in `font` at `size`, laid out left to right from `origin`.
    static func run(_ text: String, font name: String = "Helvetica", size: Double = 18, origin: Point = Point(x: 10, y: 40), variations: [UInt32: Double] = [:], horizontalScale: Double = 1) -> GlyphRun {
        let glyphFont = GlyphFont(postScriptName: name, size: size, variations: variations, horizontalScale: horizontalScale)
        let font = GlyphFont(postScriptName: name, size: size, variations: variations).ctFont
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var x = origin.x
        var positioned: [PositionedGlyph] = []
        for (glyph, advance) in zip(glyphs, advances) {
            positioned.append(PositionedGlyph(glyph: glyph, position: Point(x: x, y: origin.y)))
            x += Double(advance.width) * horizontalScale
        }
        return GlyphRun(font: glyphFont, glyphs: positioned)
    }

    static func text(_ text: String, font: String = "Helvetica", size: Double = 18, origin: Point = Point(x: 10, y: 40), color: Color = .black, transform: AffineTransform = .identity, variations: [UInt32: Double] = [:]) -> DisplayItem {
        .text(TextRunItem(text: text, glyphRun: run(text, font: font, size: size, origin: origin, variations: variations), origin: origin, color: color, transform: transform))
    }

    // MARK: Images

    /// A small image: a colour ramp with a transparent corner when `alpha`.
    static func image(width: Int = 16, height: Int = 12, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let transparent = alpha && x < width / 3 && y < height / 3
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.5, alpha: transparent ? 0 : 1)
                context.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    static func jpeg(_ image: CGImage) -> Data {
        ImageEncoding.encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])!
    }

    // MARK: Pages

    /// Opaque basics: fills, strokes of every cap, join and dash, even-odd, quadratic curves.
    static var basics: [DisplayItem] {
        var quad = DisplayPath()
        quad.move(to: Point(x: 120, y: 120))
        quad.addQuadCurve(control: Point(x: 150, y: 80), to: Point(x: 180, y: 120))
        quad.close()
        var ring = ellipse(10, 90, 50, 50)
        ring.elements += ellipse(22, 102, 26, 26).elements
        return [
            path(rect(10, 10, 60, 40), [fill(.solid(red)), stroke(.solid(.black), width: 3, join: .round)]),
            path(ellipse(80, 10, 50, 40), [fill(.solid(blue)), stroke(.solid(yellow), width: 4, cap: .round, dash: [6, 3])]),
            path(wave(140, 10, 50, 40), [stroke(.solid(green), width: 5, cap: .square, join: .bevel)]),
            path(ring, [fill(.solid(green), rule: .evenOdd)]),
            path(quad, [fill(.solid(yellow)), stroke(.solid(.black), width: 0)]),
            path(rect(70, 70, 40, 40), [fill(.solid(red))], transform: AffineTransform(a: 1, b: 0.2, c: 0.3, d: 1, tx: 0, ty: 0)),
            path(rect(0, 0, 20, 20), [fill(.solid(blue)), stroke(.solid(.black), width: 2)], transform: AffineTransform.rotation(radians: 0.3).concatenating(.translation(x: 150, y: 60))),
        ]
    }

    /// Translucency: a translucent fill, a translucent group, a clip group, fill-level and
    /// object-level Basic transparency.
    static var transparency: [DisplayItem] {
        [
            path(rect(10, 10, 120, 80), [fill(.solid(blue))]),
            path(ellipse(60, 30, 100, 80), [fill(.solid(red.withAlpha(multipliedBy: 0.5)))]),
            .group(GroupItem(children: [
                path(rect(20, 60, 60, 60), [fill(.solid(green))]),
                path(rect(50, 80, 60, 60), [fill(.solid(yellow))]),
            ], opacity: 0.6)),
            .group(GroupItem(children: [
                path(rect(120, 90, 80, 60), [fill(.solid(red)), stroke(.solid(.black), width: 2)]),
            ], clip: ellipse(125, 95, 60, 45), clipRule: .nonZero)),
            path(rect(150, 10, 40, 40), [fill(.solid(green)), stroke(.solid(.black), width: 4)], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .basic, amount: 40)))]),
            path(rect(150, 50, 40, 30), [fill(.solid(blue)), stroke(.solid(.black), width: 4)], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .basic, amount: 50)), target: .element(0))]),
        ]
    }

    static func gradient(_ kind: Gradient.Kind, behavior: Gradient.Behavior = .normal, count: Int = 1, axis: Gradient.Axis? = nil, stops: [Gradient.Stop]? = nil) -> Paint {
        .gradient(Gradient(kind: kind, behavior: behavior, repeatCount: count, axis: axis, stops: stops ?? [
            Gradient.Stop(offset: 0, color: red), Gradient.Stop(offset: 0.5, color: yellow), Gradient.Stop(offset: 1, color: blue),
        ]))
    }

    /// Gradients: linear, logarithmic, radial (elliptical), repeat, reflect, a translucent ramp,
    /// a gradient stroke.
    static var gradients: [DisplayItem] {
        [
            path(rect(10, 10, 80, 40), [fill(gradient(.linear))]),
            path(rect(100, 10, 90, 40), [fill(gradient(.logarithmic, axis: Gradient.Axis(start: Point(x: 100, y: 10), end: Point(x: 190, y: 50))))]),
            path(ellipse(10, 60, 80, 40), [fill(gradient(.radial))]),
            path(rect(100, 60, 90, 20), [fill(gradient(.linear, behavior: .repeat, count: 3))]),
            path(rect(100, 85, 90, 20), [fill(gradient(.linear, behavior: .reflect, count: 2))]),
            path(rect(10, 110, 80, 30), [fill(gradient(.linear, stops: [Gradient.Stop(offset: 0, color: red), Gradient.Stop(offset: 1, color: blue.withAlpha(multipliedBy: 0.2))]))]),
            path(wave(100, 110, 90, 30), [stroke(gradient(.linear), width: 6)]),
        ]
    }

    /// What vector formats cannot express: sampled gradients, patterns, custom and textured fills,
    /// a lens over artwork.
    static var sampled: [DisplayItem] {
        [
            path(rect(10, 10, 60, 40), [fill(gradient(.cone))]),
            path(rect(80, 10, 50, 40), [fill(gradient(.rectangle))]),
            path(ellipse(140, 10, 50, 40), [fill(gradient(.contour))]),
            path(rect(10, 60, 60, 40), [fill(.pattern(PatternPaint(bitmap: .checker, color: blue)))]),
            path(rect(80, 60, 50, 40), [fill(.custom(CustomFill(pattern: .bricks, color: red, color2: yellow)))]),
            path(rect(140, 60, 50, 40), [fill(.textured(TexturedFill(texture: .sand, color: green)))]),
            path(rect(10, 110, 180, 30), [fill(.solid(yellow))]),
            path(ellipse(60, 105, 60, 40), [fill(.lens(LensFill(type: .transparency, color: blue, amount: 50)))]),
        ]
    }

    /// Live effects: a vector effect, a gradient mask, blur, drop shadow, glow, and raster effects
    /// SVG has no filter for.
    static var effects: [DisplayItem] {
        let mask = Gradient(.linear, from: .black, to: .white)
        return [
            path(ellipse(10, 10, 50, 40), [fill(.solid(blue))], effects: [EffectElement(.ragged(LiveEffect.Ragged(size: 4, frequency: 8, seed: 3)))]),
            path(rect(70, 10, 60, 40), [fill(.solid(red))], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .gradientMask, mask: mask)))]),
            path(rect(140, 10, 50, 40), [fill(.solid(green))], effects: [EffectElement(.blur(LiveEffect.Blur(radius: 2)))]),
            path(rect(10, 70, 50, 40), [fill(.solid(yellow))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .dropShadow, color: .black, offset: 4, opacity: 60, softness: 6, angle: -45)))]),
            path(ellipse(75, 70, 45, 40), [fill(.solid(blue))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .glow, color: yellow, offset: 3, opacity: 80, softness: 3)))]),
            path(rect(135, 70, 50, 40), [fill(.solid(red))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .innerShadow, color: .black, offset: 3, opacity: 70, softness: 3)))]),
            path(rect(10, 120, 50, 25), [fill(.solid(green))], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .feather, radius: 5, softness: 50)))]),
            path(rect(70, 120, 50, 25), [fill(.solid(blue))], effects: [EffectElement(.bevelEmboss(LiveEffect.BevelEmboss(width: 4, contrast: 50)))]),
        ]
    }

    /// Strokes WTRender derives: arrowheads, calligraphic, custom and brush strokes.
    static var derivedStrokes: [DisplayItem] {
        let symbol = BrushSymbol(items: [.path(PathItem(path: DisplayPath(polygon: [Point(x: 0, y: -3), Point(x: 8, y: 0), Point(x: 0, y: 3)]), appearance: Appearance([.fill(FillPaint(paint: .solid(red)))])))])
        let brush = Brush(mode: .paint, symbols: [symbol], orientOnPath: true, foldCorners: false, spacing: .fixed(100), angle: .fixed(0), offset: .fixed(0), scaling: .fixed(100))
        return [
            path(wave(10, 10, 80, 30), [stroke(.solid(.black), width: 2, start: .circle, end: .triangle)]),
            path(wave(100, 10, 90, 30), [stroke(.solid(blue), width: 1, kind: .calligraphic(CalligraphicNib(width: 8, height: 2, angle: 30)))]),
            path(wave(10, 60, 80, 30), [stroke(.solid(green), width: 8, kind: .custom(CustomStroke(pattern: .twoWaves)))]),
            path(wave(100, 60, 90, 30), [stroke(.solid(.black), width: 1, kind: .brush(BrushStroke(brush: brush)))]),
        ]
    }

    /// A live group: a two-step blend.
    static var liveGroup: [DisplayItem] {
        [
            .group(GroupItem(children: [
                path(rect(10, 10, 30, 30), [fill(.solid(red))]),
                path(ellipse(150, 100, 30, 30), [fill(.solid(blue))]),
            ], live: .blend(BlendSpec(steps: 2)))),
            .group(GroupItem(children: [path(rect(60, 40, 60, 40), [fill(.solid(green))])], appearance: Appearance([], effects: [EffectElement(.transparency(LiveEffect.Transparency(style: .basic, amount: 30)))]))),
        ]
    }

    static func fixture(_ name: String) -> ExportPage {
        let items: [DisplayItem]
        switch name {
        case "basics": items = basics
        case "transparency": items = transparency
        case "gradients": items = gradients
        case "sampled": items = sampled
        case "effects": items = effects
        case "strokes": items = derivedStrokes
        case "live": items = liveGroup
        default: items = [text("Export 123"), text("Scaled", size: 12, origin: Point(x: 10, y: 80), color: red, transform: AffineTransform.scale(1.5))]
        }
        return page(items)
    }

    static let fixtures = ["basics", "transparency", "gradients", "sampled", "effects", "strokes", "live", "text"]

    // MARK: Pixels

    /// Premultiplied sRGB RGBA bytes of `image` drawn over `background` (or transparent).
    static func pixels(_ image: CGImage, background: Color? = nil) -> (width: Int, height: Int, bytes: [UInt8]) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if let background {
                context.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, bytes)
    }

    /// How two renderings differ: the fraction of pixels whose largest channel difference
    /// exceeds `tolerance`, after both are composited on white.
    static func difference(_ a: CGImage, _ b: CGImage, tolerance: Int) -> Double {
        let pa = pixels(a, background: .white), pb = pixels(b, background: .white)
        guard pa.width == pb.width, pa.height == pb.height else {
            return 1
        }
        var failing = 0
        for index in stride(from: 0, to: pa.bytes.count, by: 4) {
            let delta = (0..<3).map { abs(Int(pa.bytes[index + $0]) - Int(pb.bytes[index + $0])) }.max()!
            if delta > tolerance {
                failing += 1
            }
        }
        return Double(failing) / Double(pa.width * pa.height)
    }

    /// The live rendering of `page` at `scale` over white: the Core Graphics reference renderer.
    static func reference(_ page: ExportPage, scale: Double) -> CGImage {
        var renderer = CoreGraphicsRenderer(background: .white)
        renderer.rasterPreview = .document
        let viewport = Viewport(scrollOrigin: page.bounds.origin, zoom: 1, size: Size(width: page.bounds.width, height: page.bounds.height))
        return renderer.renderBitmap(page.displayList, viewport: viewport, scale: scale)!
    }

    /// A temporary directory for files a test writes.
    static func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WTInterchangeTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `image` as PNG to `$TMPDIR/WTInterchangeFailures/<name>.png` for inspection.
    static func dump(_ image: CGImage, _ name: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WTInterchangeFailures")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ImageEncoding.encode(image, type: .png)?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
