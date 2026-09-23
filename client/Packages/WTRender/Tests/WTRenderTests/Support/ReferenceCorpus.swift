// The REND-002 golden corpus: small display lists of attribute-stack paths exercising fill
// rules, every cap and join, the miter limit, dashes with phase, arrowheads, stacks with a fill
// above a stroke, transparency groups, overprint preview, hairlines and the view modes, each
// with the renderer settings it is drawn with.  Goldens live in Tests/WTRenderTests/Goldens.

import WTGeometry
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WTRender
// GEO-003 added stroke types of the same names to WTGeometry; the display list's are WTRender's.
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// One reference render: a list and how it is drawn.
struct ReferenceCase: Sendable {
    let name: String
    let list: DisplayList
    var viewMode: ViewMode = .preview
    var overprintPreview = false

    /// Whether the render contains one-device-pixel hairlines (hairline strokes, Keyline, the
    /// fast modes' image boxes).  A hairline is one device pixel in a bitmap but one point in a
    /// PDF page, so the bitmap/PDF comparison of these runs at 1× only.
    var hasHairlines: Bool {
        viewMode != .preview || name == "hairlines"
    }

    var renderer: CoreGraphicsRenderer {
        CoreGraphicsRenderer(background: .white, viewMode: viewMode, overprintPreview: overprintPreview)
    }
}

enum ReferenceCorpus {
    static let viewSize = Size(width: 128, height: 96)
    static let scales: [Double] = [1, 4]

    static func list(_ items: [DisplayItem]) -> DisplayList {
        DisplayList(canvas: "reference", items: items)
    }

    static func path(_ path: DisplayPath, _ items: [AppearanceItem], transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(items), transform: transform))
    }

    static func fill(_ color: Color, rule: FillRule = .nonZero, overprint: Bool = false) -> AppearanceItem {
        .fill(FillPaint(paint: .solid(color), rule: rule, overprint: overprint))
    }

    static func stroke(
        _ color: Color,
        width: Double,
        cap: LineCap = .butt,
        join: LineJoin = .miter,
        miterLimit: Double = 10,
        dash: [Double] = [],
        phase: Double = 0,
        start: Arrowhead? = nil,
        end: Arrowhead? = nil,
        overprint: Bool = false
    ) -> AppearanceItem {
        .stroke(StrokePaint(
            paint: .solid(color),
            style: StrokeStyle(width: width, cap: cap, join: join, miterLimit: miterLimit, dash: dash, dashPhase: phase),
            startArrowhead: start,
            endArrowhead: end,
            overprint: overprint
        ))
    }

    static func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> DisplayPath {
        DisplayPath(polygon: [Point(x: x0, y: y0), Point(x: x1, y: y1)], closed: false)
    }

    static func zigzag(x: Double, y: Double, width: Double, height: Double) -> DisplayPath {
        DisplayPath(polygon: [
            Point(x: x, y: y + height), Point(x: x + width / 3, y: y),
            Point(x: x + 2 * width / 3, y: y + height), Point(x: x + width, y: y),
        ], closed: false)
    }

    /// A rectangle with a smaller rectangle inside it wound the same way.
    static func frame(_ outer: Rect, _ inner: Rect) -> DisplayPath {
        var path = DisplayPath(rect: outer)
        path.elements += DisplayPath(rect: inner).elements
        return path
    }

    static let orange = Color(red: 0.95, green: 0.55, blue: 0.1)
    static let cyan = Color(red: 0, green: 0.68, blue: 0.94)
    static let magenta = Color(red: 0.93, green: 0, blue: 0.55)
    static let yellow = Color(red: 1, green: 0.95, blue: 0)

    static let mixed = list([
        path(DisplayPath(ellipseIn: Rect(x: 8, y: 8, width: 56, height: 44)), [fill(orange), stroke(.black, width: 3)]),
        .group(GroupItem(
            children: [
                path(DisplayPath(rect: Rect(x: 40, y: 30, width: 50, height: 40)), [fill(cyan)]),
                path(DisplayPath(rect: Rect(x: 60, y: 44, width: 50, height: 40)), [fill(magenta)]),
            ],
            opacity: 0.5,
            highlightColor: Color(red: 0.9, green: 0.1, blue: 0.1)
        )),
        path(line(8, 86, 70, 70), [stroke(blue, width: 3, end: .triangle)]),
        .image(ImageItem(assetID: "blob", rect: Rect(x: 92, y: 6, width: 30, height: 22))),
        .text(TextRunItem(text: "Label", origin: Point(x: 76, y: 92), bounds: Rect(x: 76, y: 82, width: 44, height: 12), color: .black)),
    ])

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "fillRules", list: list([
            path(star(center: Point(x: 34, y: 50), radius: 30), [fill(blue, rule: .nonZero)]),
            path(star(center: Point(x: 94, y: 50), radius: 30), [fill(blue, rule: .evenOdd)]),
        ])),
        ReferenceCase(name: "multiContourRules", list: list([
            path(frame(Rect(x: 6, y: 14, width: 54, height: 68), Rect(x: 20, y: 28, width: 26, height: 40)), [fill(green, rule: .nonZero)]),
            path(frame(Rect(x: 68, y: 14, width: 54, height: 68), Rect(x: 82, y: 28, width: 26, height: 40)), [fill(green, rule: .evenOdd)]),
        ])),
        ReferenceCase(name: "openPathFill", list: list([
            path({
                var open = DisplayPath()
                open.move(to: Point(x: 10, y: 80))
                open.addQuadCurve(control: Point(x: 64, y: -20), to: Point(x: 118, y: 80))
                return open
            }(), [fill(yellow), stroke(red, width: 2)]),
        ])),
        ReferenceCase(name: "caps", list: list([
            path(line(24, 20, 104, 20), [stroke(.black, width: 12, cap: .butt)]),
            path(line(24, 48, 104, 48), [stroke(.black, width: 12, cap: .round)]),
            path(line(24, 76, 104, 76), [stroke(.black, width: 12, cap: .square)]),
            path(line(24, 8, 24, 88), [stroke(red, width: 1)]),
            path(line(104, 8, 104, 88), [stroke(red, width: 1)]),
        ])),
        ReferenceCase(name: "joins", list: list([
            path(zigzag(x: 8, y: 12, width: 34, height: 24), [stroke(.black, width: 7, join: .miter)]),
            path(zigzag(x: 48, y: 12, width: 34, height: 24), [stroke(.black, width: 7, join: .round)]),
            path(zigzag(x: 88, y: 12, width: 34, height: 24), [stroke(.black, width: 7, join: .bevel)]),
            path(DisplayPath(rect: Rect(x: 14, y: 54, width: 24, height: 30)), [stroke(blue, width: 8, join: .miter)]),
            path(DisplayPath(rect: Rect(x: 54, y: 54, width: 24, height: 30)), [stroke(blue, width: 8, join: .round)]),
            path(DisplayPath(rect: Rect(x: 94, y: 54, width: 24, height: 30)), [stroke(blue, width: 8, join: .bevel)]),
        ])),
        ReferenceCase(name: "miterLimit", list: list([
            path(DisplayPath(polygon: [Point(x: 8, y: 80), Point(x: 34, y: 20), Point(x: 60, y: 80)], closed: false), [stroke(.black, width: 6, miterLimit: 10)]),
            path(DisplayPath(polygon: [Point(x: 68, y: 80), Point(x: 94, y: 20), Point(x: 120, y: 80)], closed: false), [stroke(.black, width: 6, miterLimit: 1.5)]),
        ])),
        ReferenceCase(name: "dashes", list: list([
            path(line(8, 14, 120, 14), [stroke(.black, width: 4, dash: [12, 4])]),
            path(line(8, 30, 120, 30), [stroke(.black, width: 4, dash: [12, 4, 2, 4])]),
            path(line(8, 46, 120, 46), [stroke(.black, width: 4, dash: [9])]),
            path(line(8, 62, 120, 62), [stroke(.black, width: 5, cap: .round, dash: [0, 10])]),
            path(DisplayPath(ellipseIn: Rect(x: 40, y: 70, width: 48, height: 22)), [stroke(blue, width: 2, dash: [6, 3])]),
        ])),
        ReferenceCase(name: "dashPhase", list: list([
            path(line(8, 20, 120, 20), [stroke(.black, width: 6, dash: [16, 8], phase: 0)]),
            path(line(8, 48, 120, 48), [stroke(.black, width: 6, dash: [16, 8], phase: 6)]),
            path(line(8, 76, 120, 76), [stroke(.black, width: 6, cap: .square, dash: [16, 8], phase: 12)]),
        ])),
        ReferenceCase(name: "arrowheads", list: list([
            path(line(20, 12, 108, 12), [stroke(.black, width: 2, start: .triangle, end: .triangle)]),
            path(line(20, 30, 108, 30), [stroke(.black, width: 2, start: .open, end: .open)]),
            path(line(20, 48, 108, 48), [stroke(.black, width: 2, start: .circle, end: .circle)]),
            path(line(20, 66, 108, 66), [stroke(.black, width: 2, start: .square, end: .square)]),
            path(line(20, 84, 108, 84), [stroke(.black, width: 2, start: .bar, end: .triangle)]),
        ])),
        ReferenceCase(name: "arrowheadsOnCurves", list: list([
            path({
                var curve = DisplayPath()
                curve.move(to: Point(x: 14, y: 80))
                curve.addCubicCurve(control1: Point(x: 30, y: 0), control2: Point(x: 98, y: 110), to: Point(x: 114, y: 20))
                return curve
            }(), [stroke(red, width: 4, cap: .round, start: .circle, end: .triangle)]),
            path(DisplayPath(ellipseIn: Rect(x: 44, y: 34, width: 40, height: 28)), [stroke(blue, width: 3, start: .triangle, end: .triangle)]),
        ])),
        ReferenceCase(name: "fillAboveStroke", list: list([
            path(DisplayPath(ellipseIn: Rect(x: 14, y: 14, width: 100, height: 68)), [stroke(.black, width: 14), fill(orange)]),
        ])),
        ReferenceCase(name: "strokeAboveFill", list: list([
            path(DisplayPath(ellipseIn: Rect(x: 14, y: 14, width: 100, height: 68)), [fill(orange), stroke(.black, width: 14)]),
        ])),
        ReferenceCase(name: "strokeStack", list: list([
            path(zigzag(x: 14, y: 20, width: 100, height: 56), [
                stroke(.black, width: 16, cap: .round, join: .round),
                stroke(.white, width: 10, cap: .round, join: .round),
                stroke(red, width: 3, cap: .round, join: .round, dash: [8, 5]),
            ]),
        ])),
        ReferenceCase(name: "translucentStack", list: list([
            path(DisplayPath(rect: Rect(x: 10, y: 10, width: 70, height: 60)), [fill(blue)]),
            path(DisplayPath(ellipseIn: Rect(x: 40, y: 26, width: 80, height: 60)), [fill(yellow.withAlpha(multipliedBy: 0.6)), stroke(red.withAlpha(multipliedBy: 0.5), width: 6)]),
        ])),
        ReferenceCase(name: "transparencyGroup", list: list([
            path(DisplayPath(rect: Rect(x: 4, y: 40, width: 120, height: 16)), [fill(.black)]),
            .group(GroupItem(children: [
                path(DisplayPath(ellipseIn: Rect(x: 14, y: 10, width: 60, height: 60)), [fill(red)]),
                path(DisplayPath(ellipseIn: Rect(x: 54, y: 26, width: 60, height: 60)), [fill(green), stroke(.black, width: 2)]),
            ], opacity: 0.5)),
        ])),
        ReferenceCase(name: "overprintPreview", list: list([
            path(DisplayPath(rect: Rect(x: 10, y: 10, width: 70, height: 60)), [fill(cyan)]),
            path(DisplayPath(rect: Rect(x: 48, y: 30, width: 70, height: 56)), [fill(magenta, overprint: true)]),
            path(line(10, 88, 118, 88), [stroke(yellow, width: 10, overprint: true)]),
            path(line(10, 80, 118, 80), [stroke(yellow, width: 6)]),
        ]), overprintPreview: true),
        ReferenceCase(name: "hairlines", list: list([
            path(line(8, 10, 120, 86), [stroke(.black, width: 0)]),
            path(DisplayPath(ellipseIn: Rect(x: 20, y: 20, width: 88, height: 56)), [stroke(blue, width: 0, dash: [4, 4])]),
            path(line(8, 86, 120, 10), [stroke(red, width: 0, end: .triangle)]),
        ])),
        ReferenceCase(name: "noneFill", list: list([
            path(DisplayPath(rect: Rect(x: 20, y: 16, width: 88, height: 64)), [.fill(FillPaint(paint: .none)), stroke(green, width: 5), .stroke(StrokePaint(paint: .none))]),
        ])),
        ReferenceCase(name: "transformedStack", list: list([
            path(
                DisplayPath(rect: Rect(x: -30, y: -15, width: 60, height: 30)),
                [fill(cyan), stroke(.black, width: 3, join: .round, dash: [10, 4], phase: 2)],
                transform: AffineTransform.scale(x: 1.3, y: 1).concatenating(.rotation(degrees: -20)).concatenating(.translation(x: 64, y: 48))
            ),
        ])),
        ReferenceCase(name: "glyphRuns", list: glyphRuns),
        ReferenceCase(name: "glyphRunsKeyline", list: glyphRuns, viewMode: .keyline),
        ReferenceCase(name: "keyline", list: mixed, viewMode: .keyline),
        ReferenceCase(name: "fastPreview", list: mixed, viewMode: .fastPreview),
        ReferenceCase(name: "fastKeyline", list: mixed, viewMode: .fastKeyline),
    ]
}

extension ReferenceCorpus {
    /// TXT-001's glyph runs: a plain line, a horizontally scaled one in a variable font's
    /// bold instance, and glyphs placed by per-glyph transforms (rotated and skewed, as on a
    /// path).
    static let glyphRuns = list([
        .text(TextRunItem(text: "Type 12", glyphRun: makeGlyphRun("Type 12", font: GlyphFont(postScriptName: "Helvetica", size: 22), at: Point(x: 6, y: 28)), origin: Point(x: 6, y: 28), color: .black)),
        .text(TextRunItem(text: "Wide", glyphRun: makeGlyphRun("Wide", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 18, horizontalScale: 1.4), at: Point(x: 6, y: 56)), origin: Point(x: 6, y: 56), color: blue)),
        .text(TextRunItem(text: "path", glyphRun: GlyphRun(font: GlyphFont(postScriptName: "Times-Roman", size: 20), glyphs: {
            let base = makeGlyphRun("path", font: GlyphFont(postScriptName: "Times-Roman", size: 20), at: .zero).glyphs
            return base.enumerated().map { index, glyph in
                let angle = Double(index - 1) * 0.25
                let place = AffineTransform.rotation(radians: angle).concatenating(.translation(x: 70 + Double(index) * 13, y: 82 - Double(index) * 4))
                let skew = AffineTransform(a: 1, b: 0, c: -0.3, d: 1, tx: 0, ty: 0)
                return PositionedGlyph(glyph: glyph.glyph, position: glyph.position, transform: index.isMultiple(of: 2) ? place : skew.concatenating(place))
            }
        }()), origin: Point(x: 70, y: 82), color: red)),
    ])

    /// `string`'s glyphs in `font` from `origin` by nominal advances.
    static func makeGlyphRun(_ string: String, font: GlyphFont, at origin: Point) -> GlyphRun {
        let ctFont = font.ctFont
        let characters = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
        var x = origin.x
        var placed: [PositionedGlyph] = []
        for (glyph, advance) in zip(glyphs, advances) {
            placed.append(PositionedGlyph(glyph: glyph, position: Point(x: x, y: origin.y)))
            x += Double(advance.width)
        }
        return GlyphRun(font: font, glyphs: placed)
    }
}

/// Golden PNGs on disk next to this test target.
enum GoldenStore {
    static let recordEnvironmentKey = "WTRENDER_RECORD_GOLDENS"

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment[recordEnvironmentKey] == "1"
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // WTRenderTests
        .appendingPathComponent("Goldens", isDirectory: true)

    static func url(for name: String, scale: Double) -> URL {
        directory.appendingPathComponent("\(name)@\(Int(scale))x.png")
    }

    static func write(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func read(_ url: URL) -> BitmapSurface? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return BitmapSurface(drawing: image)
    }
}
