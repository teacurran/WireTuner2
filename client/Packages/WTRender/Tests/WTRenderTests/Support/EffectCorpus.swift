// The FX golden corpus: the vector effect kernels (FX-004, FX-005, FX-046), attachment levels and
// order (FX-006), Combine (FX-048), the raster effects (FX-009 ... FX-011), transparency (FX-015),
// extrusions (FX-018, FX-019, FX-022), blends (FX-025, FX-026, FX-029), envelopes (FX-038) and
// perspective (FX-042).  Each case joins `ReferenceCorpus.cases`, so it has goldens at 1× and 4×
// and runs through REND-007's Metal/Core Graphics parity.

import WTGeometry
import CoreGraphics
import Foundation
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

enum EffectCorpus {
    typealias C = ReferenceCorpus

    static let blue = Color(red: 0.1, green: 0.3, blue: 0.85)
    static let red = Color(red: 0.85, green: 0.15, blue: 0.1)
    static let green = Color(red: 0.1, green: 0.6, blue: 0.25)

    static func item(_ path: DisplayPath, _ items: [AppearanceItem], effects: [EffectElement], transform: AffineTransform = .identity) -> DisplayItem {
        .path(PathItem(path: path, appearance: Appearance(items, effects: effects), transform: transform))
    }

    static func star(_ center: Point, outer: Double, inner: Double, points: Int = 5) -> DisplayPath {
        DisplayPath(polygon: (0..<(2 * points)).map { index in
            let angle = Double(index) * .pi / Double(points) - .pi / 2
            let radius = index % 2 == 0 ? outer : inner
            return Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        })
    }

    static func leaf(in rect: Rect) -> DisplayPath {
        var path = DisplayPath()
        path.move(to: Point(x: rect.minX, y: rect.maxY))
        path.addCubicCurve(control1: Point(x: rect.minX, y: rect.minY + rect.height * 0.3), control2: Point(x: rect.maxX - rect.width * 0.3, y: rect.minY), to: Point(x: rect.maxX, y: rect.minY))
        path.addCubicCurve(control1: Point(x: rect.maxX, y: rect.maxY - rect.height * 0.3), control2: Point(x: rect.minX + rect.width * 0.3, y: rect.maxY), to: Point(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    static let fillStroke: [AppearanceItem] = [C.fill(C.orange), C.stroke(.black, width: 2)]

    // MARK: Vector kernels

    static let bendDuetTransform = C.list([
        item(DisplayPath(rect: Rect(x: 16, y: 16, width: 48, height: 48)), fillStroke, effects: [EffectElement(.bend(.init(size: 10)))]),
        item(star(Point(x: 104, y: 40), outer: 28, inner: 14), [C.fill(C.cyan), C.stroke(.black, width: 1.5)], effects: [EffectElement(.bend(.init(size: -8, center: Point(x: 4, y: 0))))]),
        item(leaf(in: Rect(x: 148, y: 14, width: 36, height: 44)), [C.fill(green), C.stroke(.black, width: 1.5)], effects: [EffectElement(.duet(.init(mode: .reflect, center: Point(x: 18, y: 0), axisAngle: 90)))]),
        item(DisplayPath(ellipseIn: Rect(x: 36, y: 100, width: 10, height: 30)), [C.fill(C.magenta)], effects: [EffectElement(.duet(.init(mode: .rotate, center: Point(x: 0, y: -15), copies: 6)))]),
        item(C.line(80, 100, 110, 130), [C.stroke(blue, width: 3, cap: .round)], effects: [EffectElement(.duet(.init(mode: .rotate, center: Point(x: -15, y: 15), copies: 4, joined: true, closed: true)))]),
        item(DisplayPath(rect: Rect(x: 150, y: 96, width: 30, height: 20)), [C.fill(red.withAlpha(multipliedBy: 0.9)), C.stroke(.black, width: 1)], effects: [EffectElement(.transform(.init(scaleX: 90, scaleY: 90, rotate: 20, move: Point(x: 6, y: -4), copies: 5)))]),
    ])

    static let expandRaggedSketch = C.list([
        item(AttributeCorpus.wave(in: Rect(x: 12, y: 16, width: 90, height: 40)), [C.fill(C.cyan), C.stroke(.black, width: 1)], effects: [EffectElement(.expandPath(.init(width: 12, cap: .round, join: .round)))]),
        item(DisplayPath(rect: Rect(x: 128, y: 20, width: 40, height: 30)), [C.fill(C.yellow), C.stroke(.black, width: 1)], effects: [EffectElement(.expandPath(.init(direction: .outside, width: 8, join: .round)))]),
        item(DisplayPath(rect: Rect(x: 188, y: 20, width: 40, height: 30)), [C.fill(C.orange), C.stroke(.black, width: 1)], effects: [EffectElement(.expandPath(.init(direction: .inside, width: 8)))]),
        item(DisplayPath(ellipseIn: Rect(x: 16, y: 80, width: 56, height: 56)), [C.fill(green), C.stroke(.black, width: 1)], effects: [EffectElement(.ragged(.init(size: 4, frequency: 30, seed: 7)))]),
        item(DisplayPath(ellipseIn: Rect(x: 92, y: 80, width: 56, height: 56)), [C.fill(C.magenta), C.stroke(.black, width: 1)], effects: [EffectElement(.ragged(.init(size: 4, frequency: 20, smooth: true, seed: 11)))]),
        item(DisplayPath(rect: Rect(x: 170, y: 84, width: 54, height: 48)), [C.stroke(.black, width: 1, cap: .round, join: .round)], effects: [EffectElement(.sketch(.init(amount: 4, copies: 3, seed: 5)))]),
    ])

    static let corners = C.list([
        item(star(Point(x: 40, y: 44), outer: 32, inner: 16), fillStroke, effects: [EffectElement(.corners(.init(radius: 6, style: .round)))]),
        item(star(Point(x: 116, y: 44), outer: 32, inner: 16), fillStroke, effects: [EffectElement(.corners(.init(radius: 6, style: .invertedRound)))]),
        item(star(Point(x: 192, y: 44), outer: 32, inner: 16), fillStroke, effects: [EffectElement(.corners(.init(radius: 6, style: .chamfer)))]),
        item(DisplayPath(rect: Rect(x: 20, y: 96, width: 80, height: 50)), [C.fill(C.cyan), C.stroke(.black, width: 2)], effects: [EffectElement(.corners(.init(radius: 14, style: .round, points: [CornerPoint(contour: 0, anchor: 0), CornerPoint(contour: 0, anchor: 2)])))]),
        item(DisplayPath(ellipseIn: Rect(x: 124, y: 96, width: 50, height: 50)), [C.fill(green)], effects: [EffectElement(.corners(.init(radius: 10)))]),
        item(DisplayPath(polygon: [Point(x: 190, y: 146), Point(x: 210, y: 96), Point(x: 236, y: 146)]), [C.fill(C.magenta), C.stroke(.black, width: 1)], effects: [EffectElement(.corners(.init(radius: 200, style: .round)))]),
    ])

    // MARK: Pipeline

    static let attachment = C.list([
        // A Transform on the fill: a nudged, scaled copy of the fill under an unmoved stroke.
        item(star(Point(x: 44, y: 44), outer: 30, inner: 14), [C.fill(Color(white: 0.3)), C.stroke(C.orange, width: 3)], effects: [EffectElement(.transform(.init(scaleX: 95, scaleY: 95, move: Point(x: 5, y: -5))), target: .element(0))]),
        // A Ragged on the stroke only.
        item(DisplayPath(ellipseIn: Rect(x: 92, y: 14, width: 60, height: 60)), [C.fill(C.cyan), C.stroke(.black, width: 2)], effects: [EffectElement(.ragged(.init(size: 3, frequency: 40, seed: 3)), target: .element(1))]),
        // Order: Bend then Duet, and a hidden Ragged and an unknown kind that draw nothing.
        item(leaf(in: Rect(x: 172, y: 20, width: 30, height: 40)), [C.fill(green), C.stroke(.black, width: 1)], effects: [
            EffectElement(.bend(.init(size: 5))),
            EffectElement(.ragged(.init(size: 6, frequency: 40, seed: 3)), hidden: true),
            EffectElement(.unsupported),
            EffectElement(.duet(.init(mode: .reflect, center: Point(x: 18, y: 0), axisAngle: 90))),
        ]),
        // Group-level vector effect: every member bent about the group's centre.
        .group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 20, y: 96, width: 40, height: 40)), [C.fill(C.yellow), C.stroke(.black, width: 1)]),
            C.path(DisplayPath(rect: Rect(x: 64, y: 96, width: 40, height: 40)), [C.fill(C.magenta), C.stroke(.black, width: 1)]),
        ], appearance: Appearance(effects: [EffectElement(.bend(.init(size: -8)))]))),
        // A Combine on a single path renders as no effect.
        item(DisplayPath(rect: Rect(x: 128.25, y: 100.25, width: 40, height: 36)), [C.fill(blue)], effects: [EffectElement(.combine(.init(operation: .subtract)))]),
        // Transform with copies at object level.
        item(DisplayPath(ellipseIn: Rect(x: 190, y: 104, width: 16, height: 30)), [C.fill(red), C.stroke(.black, width: 1)], effects: [EffectElement(.transform(.init(rotate: -30, center: Point(x: 12, y: -8), copies: 4)))]),
    ])

    static func combineGroup(_ operation: LiveEffect.Combine.Operation, at origin: Point) -> DisplayItem {
        .group(GroupItem(children: [
            C.path(DisplayPath(ellipseIn: Rect(x: origin.x, y: origin.y, width: 40, height: 40)), [C.fill(.white)]),
            C.path(DisplayPath(ellipseIn: Rect(x: origin.x + 22, y: origin.y + 4, width: 34, height: 34)), [C.fill(.white)]),
            C.path(DisplayPath(rect: Rect(x: origin.x + 10, y: origin.y + 24, width: 36, height: 26)), [C.fill(.white)]),
        ], appearance: Appearance([C.fill(C.cyan), C.stroke(.black, width: 1.5)], effects: [EffectElement(.combine(.init(operation: operation)))])))
    }

    static let combine = C.list([
        combineGroup(.union, at: Point(x: 8, y: 16)),
        combineGroup(.subtract, at: Point(x: 72, y: 16)),
        combineGroup(.intersect, at: Point(x: 136, y: 16)),
        combineGroup(.exclude, at: Point(x: 196, y: 16)),
    ])

    // MARK: Raster

    static let blurSharpen = C.list([
        item(star(Point(x: 40, y: 44), outer: 30, inner: 14), [C.fill(C.orange)], effects: [EffectElement(.blur(.init(style: .gaussian, radius: 3)))]),
        item(star(Point(x: 110, y: 44), outer: 30, inner: 14), [C.fill(blue)], effects: [EffectElement(.blur(.init(style: .basic, radius: 4)))]),
        // A blurred fill under a crisp stroke.
        item(DisplayPath(ellipseIn: Rect(x: 160, y: 18, width: 56, height: 52)), [C.fill(green), C.stroke(.black, width: 2)], effects: [EffectElement(.blur(.init(radius: 5)), target: .element(0))]),
        item(DisplayPath(rect: Rect(x: 16, y: 92, width: 90, height: 44)), [AttributeCorpus.fill(.gradient(Gradient(.linear, from: C.yellow, to: red)))], effects: [EffectElement(.sharpen(.init(style: .basic, amount: 200)))]),
        item(DisplayPath(rect: Rect(x: 124, y: 92, width: 90, height: 44)), [AttributeCorpus.fill(.pattern(PatternPaint(bitmap: .checker, color: blue)))], effects: [EffectElement(.sharpen(.init(style: .unsharpMask, amount: 150, pixelRadius: 1.5, threshold: 4)))]),
    ])

    static let shadowGlow = C.list([
        item(star(Point(x: 40, y: 40), outer: 28, inner: 13), [C.fill(C.orange)], effects: [EffectElement(.shadow(.init(style: .dropShadow, color: .black, offset: 5, opacity: 70, softness: 6, angle: 315)))]),
        item(star(Point(x: 116, y: 40), outer: 28, inner: 13), [C.fill(C.yellow)], effects: [EffectElement(.shadow(.init(style: .innerShadow, color: .black, offset: 4, opacity: 80, softness: 5, angle: 135)))]),
        item(star(Point(x: 40, y: 110), outer: 28, inner: 13), [C.fill(C.cyan)], effects: [EffectElement(.shadow(.init(style: .glow, color: C.magenta, offset: 4, opacity: 90, softness: 6)))]),
        item(star(Point(x: 116, y: 110), outer: 28, inner: 13), [C.fill(blue)], effects: [EffectElement(.shadow(.init(style: .innerGlow, color: .white, offset: 3, opacity: 90, softness: 5)))]),
        // Shadow then Transform: the Transform copies the shadowed result.
        item(DisplayPath(rect: Rect(x: 170, y: 20, width: 24, height: 24)), [C.fill(green)], effects: [
            EffectElement(.shadow(.init(color: .black, offset: 3, opacity: 60, softness: 3, angle: 315))),
            EffectElement(.transform(.init(move: Point(x: 0, y: -40), copies: 2))),
        ]),
    ])

    static let bevel = C.list([
        item(DisplayPath(rect: Rect(x: 16, y: 16, width: 60, height: 50)), [C.fill(C.orange)], effects: [EffectElement(.bevelEmboss(.init(style: .innerBevel, width: 8, contrast: 70, softness: 2, angle: 135, edgeShape: .flat)))]),
        item(DisplayPath(ellipseIn: Rect(x: 100, y: 16, width: 56, height: 50)), [C.fill(C.cyan)], effects: [EffectElement(.bevelEmboss(.init(style: .outerBevel, color: Color(white: 0.7), width: 6, contrast: 80, softness: 1, angle: 45, edgeShape: .smooth)))]),
        item(star(Point(x: 46, y: 112), outer: 30, inner: 15), [C.fill(red)], effects: [EffectElement(.bevelEmboss(.init(style: .raisedEmboss, width: 4, contrast: 90, softness: 1, angle: 135)))]),
        item(star(Point(x: 128, y: 112), outer: 30, inner: 15), [C.fill(blue)], effects: [EffectElement(.bevelEmboss(.init(style: .insetEmboss, width: 4, contrast: 90, softness: 1, angle: 135)))]),
        item(DisplayPath(rect: Rect(x: 180, y: 20, width: 56, height: 120)), [C.fill(green)], effects: [EffectElement(.bevelEmboss(.init(style: .innerBevel, width: 10, contrast: 60, angle: 90, edgeShape: .ring, buttonPreset: .highlighted)))]),
    ])

    static let transparency = C.list([
        // Backdrop bars, off the pixel grid: an edge exactly on a tile's pixel boundary is a sample
        // coincidence, not an effect.
        C.path(DisplayPath(rect: Rect(x: 0.25, y: 0.25, width: 255.5, height: 20)), [C.fill(blue)]),
        C.path(DisplayPath(rect: Rect(x: 0.25, y: 76.25, width: 255.5, height: 19.5)), [C.fill(blue)]),
        // Object level: the stroke does not show through the fill.
        item(DisplayPath(rect: Rect(x: 12, y: 8, width: 50, height: 80)), [C.stroke(.black, width: 8), C.fill(C.orange)], effects: [EffectElement(.transparency(.init(style: .basic, amount: 50)))]),
        // Fill level: it does.
        item(DisplayPath(rect: Rect(x: 76, y: 8, width: 50, height: 80)), [C.stroke(.black, width: 8), C.fill(C.orange)], effects: [EffectElement(.transparency(.init(style: .basic, amount: 50)), target: .element(1))]),
        // Gradient mask: transparent where the gradient is white.
        item(DisplayPath(rect: Rect(x: 140, y: 8, width: 50, height: 80)), [C.fill(green)], effects: [EffectElement(.transparency(.init(style: .gradientMask, mask: Gradient(.linear, from: .black, to: .white))))]),
        // Feather.
        item(DisplayPath(ellipseIn: Rect(x: 200, y: 12, width: 50, height: 72)), [C.fill(red)], effects: [EffectElement(.transparency(.init(style: .feather, radius: 10, softness: 60)))]),
    ])

    // MARK: Wrapper kinds

    static func extrusion(_ path: DisplayPath, fill: Color, spec: ExtrudeSpec) -> DisplayItem {
        .group(GroupItem(children: [C.path(path, [C.fill(fill), C.stroke(.black, width: 1)])], live: .extrude(spec)))
    }

    static let lit = ExtrudeSpec.Light(direction: .topLeft, intensity: 80)

    static let extrude = C.list([
        extrusion(DisplayPath(rect: Rect(x: 20, y: 60, width: 40, height: 40)), fill: C.orange, spec: ExtrudeSpec(length: 60, vanishingPoint: Point(x: 128, y: 10), surface: .shaded, ambient: 30, light1: lit)),
        extrusion(DisplayPath(ellipseIn: Rect(x: 90, y: 90, width: 36, height: 36)), fill: C.cyan, spec: ExtrudeSpec(length: 40, vanishingPoint: Point(x: 128, y: 10), rotationX: 10, rotationY: 20, surface: .shaded, surfaceSteps: 6, ambient: 30, light1: lit)),
        extrusion(DisplayPath(rect: Rect(x: 180, y: 60, width: 36, height: 30)), fill: green, spec: ExtrudeSpec(length: 50, vanishingPoint: Point(x: 128, y: 10), surface: .wireframe)),
        extrusion(DisplayPath(rect: Rect(x: 200, y: 110, width: 30, height: 30)), fill: C.yellow, spec: ExtrudeSpec(length: 30, vanishingPoint: Point(x: 128, y: 10), surface: .shaded, ambient: 40, light1: lit, profile: .init(kind: .bevel, path: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 6, y: -6), Point(x: 30, y: -6)], closed: false), steps: 2, twist: 20))),
    ])

    static func blendKeys(_ spec: BlendSpec, path: DisplayPath? = nil, a: DisplayItem, b: DisplayItem) -> DisplayItem {
        var children = [a, b]
        var spec = spec
        if let path {
            children.insert(C.path(path, [C.stroke(Color(white: 0.5), width: 1)]), at: 0)
            spec.path = 0
        }
        return .group(GroupItem(children: children, live: .blend(spec)))
    }

    static let blend = C.list([
        blendKeys(BlendSpec(steps: 5), a: C.path(DisplayPath(ellipseIn: Rect(x: 10, y: 20, width: 20, height: 20)), [C.fill(red)]), b: C.path(DisplayPath(rect: Rect(x: 90, y: 10, width: 40, height: 40)), [C.fill(blue)])),
        blendKeys(BlendSpec(steps: 8, showPath: true, rotateOnPath: true), path: AttributeCorpus.wave(in: Rect(x: 20, y: 70, width: 200, height: 60)),
                  a: C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 16, height: 8)), [C.fill(C.orange), C.stroke(.black, width: 1)]),
                  b: C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 16, height: 24)), [C.fill(green), C.stroke(.black, width: 1)])),
        blendKeys(BlendSpec(steps: 4, rangeFirst: 20, rangeLast: 80), a: C.path(star(Point(x: 160, y: 30), outer: 16, inner: 8), [AttributeCorpus.fill(.gradient(Gradient(.linear, from: C.yellow, to: red)))]), b: C.path(DisplayPath(ellipseIn: Rect(x: 210, y: 14, width: 32, height: 32)), [AttributeCorpus.fill(.gradient(Gradient(.linear, from: C.cyan, to: blue)))])),
    ])

    static let envelope = C.list([
        .group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 20, y: 30, width: 80, height: 60)), [C.fill(C.cyan), C.stroke(.black, width: 1)]),
            C.path(star(Point(x: 60, y: 60), outer: 20, inner: 9), [C.fill(C.yellow), C.stroke(.black, width: 1)]),
        ], live: .envelope(EnvelopeSpec(contour: arch(Rect(x: 20, y: 30, width: 80, height: 60), rise: 20), sourceBounds: Rect(x: 20, y: 30, width: 80, height: 60), corners: [0, 1, 2, 3])))),
        .group(GroupItem(children: [
            C.path(DisplayPath(ellipseIn: Rect(x: 140, y: 30, width: 80, height: 60)), [C.fill(C.orange), C.stroke(.black, width: 1)]),
        ], live: .envelope(EnvelopeSpec(contour: DisplayPath(polygon: [Point(x: 150, y: 20), Point(x: 230, y: 40), Point(x: 220, y: 100), Point(x: 140, y: 90)]), sourceBounds: Rect(x: 140, y: 30, width: 80, height: 60))))),
    ])

    /// A rectangle whose top edge bows up by `rise` and bottom edge down by it.
    static func arch(_ rect: Rect, rise: Double) -> DisplayPath {
        var path = DisplayPath()
        path.move(to: Point(x: rect.minX, y: rect.minY))
        path.addCubicCurve(control1: Point(x: rect.minX + rect.width / 3, y: rect.minY - rise), control2: Point(x: rect.maxX - rect.width / 3, y: rect.minY - rise), to: Point(x: rect.maxX, y: rect.minY))
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        path.addCubicCurve(control1: Point(x: rect.maxX - rect.width / 3, y: rect.maxY + rise / 2), control2: Point(x: rect.minX + rect.width / 3, y: rect.maxY + rise / 2), to: Point(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    static let grid = PerspectiveGridSpec.defaultGrid(page: Rect(x: 0, y: 0, width: 256, height: 160))

    static func attached(_ plane: PerspectiveSpec.Plane, at cell: Point, color: Color, size: Double = 1, flipped: Bool = false) -> DisplayItem {
        .group(GroupItem(children: [
            C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 36, height: 36)), [C.fill(color), C.stroke(.black, width: 1)]),
        ], live: .perspective(PerspectiveSpec(grid: grid, plane: plane, cellPosition: cell, cellWidth: size, cellHeight: size, flipped: flipped))))
    }

    static let perspective = C.list([
        attached(.leftWall, at: Point(x: -1.2, y: 0.2), color: C.orange),
        attached(.rightWall, at: Point(x: 0.2, y: 0.2), color: C.cyan),
        attached(.floorLeft, at: Point(x: 1.2, y: -1.4), color: green, size: 0.8),
        attached(.floorRight, at: Point(x: 0.1, y: 0.1), color: C.magenta, size: 0.8, flipped: true),
    ])

    static let cases: [ReferenceCase] = [
        ReferenceCase(name: "effectsBendDuetTransform", list: bendDuetTransform, viewSize: Size(width: 240, height: 160)),
        ReferenceCase(name: "effectsExpandRaggedSketch", list: expandRaggedSketch, viewSize: Size(width: 240, height: 150)),
        ReferenceCase(name: "effectsCorners", list: corners, viewSize: Size(width: 240, height: 160)),
        ReferenceCase(name: "effectsAttachment", list: attachment, viewSize: Size(width: 240, height: 150)),
        ReferenceCase(name: "effectsCombine", list: combine, viewSize: Size(width: 256, height: 80)),
        ReferenceCase(name: "effectsBlurSharpen", list: blurSharpen, viewSize: Size(width: 232, height: 150), comparesPDF: false),
        ReferenceCase(name: "effectsShadowGlow", list: shadowGlow, viewSize: Size(width: 210, height: 150), comparesPDF: false),
        ReferenceCase(name: "effectsBevel", list: bevel, viewSize: Size(width: 250, height: 150), comparesPDF: false),
        ReferenceCase(name: "effectsTransparency", list: transparency, viewSize: Size(width: 256, height: 96), comparesPDF: false),
        ReferenceCase(name: "effectsExtrude", list: extrude, viewSize: Size(width: 256, height: 150)),
        ReferenceCase(name: "effectsBlend", list: blend, viewSize: Size(width: 256, height: 150), comparesPDF: false),
        ReferenceCase(name: "effectsEnvelope", list: envelope, viewSize: Size(width: 256, height: 120)),
        ReferenceCase(name: "effectsPerspective", list: perspective, viewSize: Size(width: 256, height: 160)),
    ]
}
