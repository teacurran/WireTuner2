// The type render cases (TYPE-021, TYPE-036): what WTText emits around glyph runs -- text effects
// in groups Keyline never draws, synthesized slants and emboldening, overprinting glyphs -- and
// greeking by device pixel size.  Each case joins `ReferenceCorpus.cases`, so it has goldens at 1×
// and 4× and runs through REND-007's Metal/Core Graphics parity.

import WTGeometry
import CoreGraphics
import Foundation
@testable import WTRender
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

enum TextCorpus {
    typealias C = ReferenceCorpus

    static let blue = Color(red: 0.1, green: 0.3, blue: 0.85)
    static let red = Color(red: 0.85, green: 0.15, blue: 0.1)
    static let yellow = Color(red: 1, green: 0.88, blue: 0.2)

    static func stroke(_ color: Color, width: Double, dash: [Double] = []) -> AppearanceItem {
        .stroke(StrokePaint(paint: .solid(color), style: StrokeStyle(width: width, cap: .butt, join: .round, dash: dash)))
    }

    static func text(_ run: GlyphRun, color: Color = .black, overprint: Bool = false, greekable: Bool = true) -> DisplayItem {
        .text(TextRunItem(text: "", glyphRun: run, origin: run.glyphs.first?.position ?? .zero, color: color, overprint: overprint, greekable: greekable))
    }

    /// A line of effected type: a highlight band, a shadow and inline rings (`RoundOutline`
    /// regions) behind the glyphs, a dashed underline over them; and a synthesized bold oblique.
    static let effects: DisplayList = {
        let word = C.makeGlyphRun("Effects", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 24), at: Point(x: 8, y: 34))
        let outline = word.outline
        var band = DisplayPath()
        band.move(to: Point(x: 8, y: 28))
        band.addLine(to: Point(x: 100, y: 28))
        var underline = DisplayPath()
        underline.move(to: Point(x: 8, y: 38))
        underline.addLine(to: Point(x: 100, y: 38))
        let under = GroupItem(children: [
            C.path(band, [stroke(yellow, width: 14)]),
            C.path(outline, [.fill(FillPaint(paint: .solid(Color(red: 0.95, green: 0.6, blue: 0.6))))], transform: .translation(x: 2.5, y: 2.5)),
            C.path(word.roundOutline(width: 5), [C.fill(blue)]),
            C.path(word.roundOutline(width: 3), [C.fill(.white)]),
        ], hiddenInKeyline: true)
        let over = GroupItem(children: [C.path(underline, [stroke(red, width: 1.5, dash: [4, 2])])], hiddenInKeyline: true)
        let slanted = C.makeGlyphRun("Slant", font: GlyphFont(postScriptName: "Times-Roman", size: 26, obliqueness: 0.2126), at: Point(x: 10, y: 80))
        let bold = GroupItem(children: [C.path(slanted.roundOutline(width: 26 * 0.04), [C.fill(.black)])], hiddenInKeyline: true)
        return C.list([.group(under), text(word), .group(over), text(slanted), .group(bold)])
    }()

    /// Overprinting glyphs over a fill.
    static let overprint = C.list([
        C.path(DisplayPath(rect: Rect(x: 10, y: 10, width: 70, height: 70)), [C.fill(Color(red: 0, green: 0.7, blue: 0.9))]),
        text(C.makeGlyphRun("OP", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 40), at: Point(x: 30, y: 60)), color: Color(red: 0.9, green: 0, blue: 0.6), overprint: true),
        text(C.makeGlyphRun("K", font: GlyphFont(postScriptName: "Helvetica-Bold", size: 40), at: Point(x: 76, y: 60)), color: Color(red: 0.9, green: 0, blue: 0.6)),
    ])

    /// Type small on the device greeks under `greekTypeBelow`, unless it is not greekable.
    static let greeking = C.list([
        text(C.makeGlyphRun("Six point type", font: GlyphFont(postScriptName: "Helvetica", size: 6), at: Point(x: 8, y: 20))),
        text(C.makeGlyphRun("Selected six point", font: GlyphFont(postScriptName: "Helvetica", size: 6), at: Point(x: 8, y: 40)), greekable: false),
        text(C.makeGlyphRun("Large", font: GlyphFont(postScriptName: "Helvetica", size: 24), at: Point(x: 8, y: 76))),
    ])

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "textEffects", list: effects),
        ReferenceCase(name: "textEffectsKeyline", list: effects, viewMode: .keyline),
        ReferenceCase(name: "textOverprint", list: overprint, overprintPreview: true),
        ReferenceCase(name: "textGreeking", list: greeking, comparesPDF: false, greekTypeBelow: 8),
    ]
}
