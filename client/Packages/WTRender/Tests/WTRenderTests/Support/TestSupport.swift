// Shared helpers: the golden corpus of small display lists, a PDF rasterizer for the
// bitmap-vs-PDF gate, and the pixel comparison the spec describes (docs/spec/testing.adoc,
// "Geometry and rendering").

import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
// GEO-003 added stroke types of the same names to WTGeometry; the display list's are WTRender's.
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// Foundation also has an `AffineTransform`; the tests mean WTGeometry's.
typealias AffineTransform = WTGeometry.AffineTransform

func approx(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

func approx(_ lhs: Point, _ rhs: Point, tolerance: Double = 1e-9) -> Bool {
    approx(lhs.x, rhs.x, tolerance: tolerance) && approx(lhs.y, rhs.y, tolerance: tolerance)
}

func approx(_ lhs: Rect, _ rhs: Rect, tolerance: Double = 1e-9) -> Bool {
    approx(lhs.origin, rhs.origin, tolerance: tolerance)
        && approx(lhs.width, rhs.width, tolerance: tolerance)
        && approx(lhs.height, rhs.height, tolerance: tolerance)
}

let red = Color(red: 0.9, green: 0.1, blue: 0.1)
let green = Color(red: 0.1, green: 0.7, blue: 0.2)
let blue = Color(red: 0.1, green: 0.2, blue: 0.9)

/// A five-point star centred on `center`; self-intersecting, so the fill rule matters.
func star(center: Point, radius: Double) -> DisplayPath {
    var points: [Point] = []
    for index in 0..<5 {
        let angle = -Double.pi / 2 + Double(index) * 4 * Double.pi / 5
        points.append(Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
    }
    return DisplayPath(polygon: points)
}

/// The corpus: small display lists exercising every item kind and style, named for the report.
enum Corpus {
    static let canvas: CanvasID = "corpus"
    static let viewSize = Size(width: 128, height: 96)

    static func list(_ items: [DisplayItem]) -> DisplayList {
        DisplayList(canvas: canvas, items: items)
    }

    static let solidRect = list([
        .fill(FillItem(path: DisplayPath(rect: Rect(x: 10, y: 10, width: 60, height: 40)), paint: .solid(red))),
    ])

    static let evenOddStar = list([
        .fill(FillItem(path: star(center: Point(x: 40, y: 48), radius: 36), rule: .evenOdd, paint: .solid(blue))),
        .fill(FillItem(path: star(center: Point(x: 92, y: 48), radius: 30), rule: .nonZero, paint: .solid(green))),
    ])

    static let ellipse = list([
        .fill(FillItem(path: DisplayPath(ellipseIn: Rect(x: 8, y: 8, width: 110, height: 80)), paint: .solid(green))),
    ])

    static let strokes: DisplayList = {
        var zigzag = DisplayPath()
        zigzag.move(to: Point(x: 8, y: 80))
        zigzag.addLine(to: Point(x: 30, y: 16))
        zigzag.addLine(to: Point(x: 52, y: 80))
        zigzag.addLine(to: Point(x: 74, y: 16))
        var curve = DisplayPath()
        curve.move(to: Point(x: 80, y: 88))
        curve.addQuadCurve(control: Point(x: 124, y: 88), to: Point(x: 124, y: 40))
        curve.addCubicCurve(control1: Point(x: 124, y: 8), control2: Point(x: 90, y: 8), to: Point(x: 84, y: 30))
        return list([
            .stroke(StrokeItem(path: zigzag, style: StrokeStyle(width: 6, cap: .round, join: .round), paint: .solid(blue))),
            .stroke(StrokeItem(path: zigzag, style: StrokeStyle(width: 2, cap: .square, join: .miter, miterLimit: 4), paint: .solid(red), transform: .translation(x: 20, y: 0))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 4, y: 4, width: 120, height: 88)), style: StrokeStyle(width: 1.5, join: .bevel, dash: [4, 2], dashPhase: 1), paint: .solid(.black))),
            .stroke(StrokeItem(path: curve, style: StrokeStyle(width: 3, cap: .butt, join: .miter), paint: .solid(green))),
        ])
    }()

    static let transformed = list([
        .fill(FillItem(
            path: DisplayPath(rect: Rect(x: -20, y: -10, width: 40, height: 20)),
            paint: .solid(red),
            transform: AffineTransform.scale(x: 1.5, y: 1).concatenating(.rotation(degrees: 30)).concatenating(.translation(x: 64, y: 48))
        )),
        .fill(FillItem(
            path: DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 30, height: 30)),
            paint: .solid(blue.withAlpha(multipliedBy: 0.6)),
            transform: .translation(x: 70, y: 40)
        )),
    ])

    static let groupClipOpacity = list([
        .group(GroupItem(
            children: [
                .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 128, height: 48)), paint: .solid(red))),
                .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 48, width: 128, height: 48)), paint: .solid(blue))),
            ],
            clip: DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 100, height: 80)),
            opacity: 0.5,
            transform: .translation(x: 14, y: 8)
        )),
    ])

    static let nestedGroups = list([
        .group(GroupItem(
            children: [
                .group(GroupItem(
                    children: [
                        .fill(FillItem(path: star(center: Point(x: 64, y: 48), radius: 40), rule: .evenOdd, paint: .solid(green))),
                    ],
                    clip: DisplayPath(rect: Rect(x: 30, y: 10, width: 70, height: 76)),
                    clipRule: .evenOdd
                )),
                .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 30, y: 10, width: 70, height: 76)), style: StrokeStyle(width: 2), paint: .solid(.black))),
            ],
            opacity: 0.8
        )),
    ])

    static let placeholders = list([
        .image(ImageItem(assetID: "blob-1", rect: Rect(x: 8, y: 8, width: 50, height: 36))),
        .text(TextRunItem(text: "WireTuner", origin: Point(x: 64, y: 70), bounds: Rect(x: 64, y: 54, width: 56, height: 20), color: blue)),
    ])

    static let empty = list([])

    static let offscreen = list([
        .fill(FillItem(path: DisplayPath(rect: Rect(x: 1000, y: 1000, width: 10, height: 10)), paint: .solid(red))),
        .fill(FillItem(path: DisplayPath(), paint: .solid(red))),
    ])

    static let all: [(name: String, list: DisplayList)] = [
        ("solidRect", solidRect),
        ("evenOddStar", evenOddStar),
        ("ellipse", ellipse),
        ("strokes", strokes),
        ("transformed", transformed),
        ("groupClipOpacity", groupClipOpacity),
        ("nestedGroups", nestedGroups),
        ("placeholders", placeholders),
        ("empty", empty),
        ("offscreen", offscreen),
    ]

    static let viewports: [(name: String, viewport: Viewport)] = [
        ("identity", Viewport(size: viewSize)),
        ("zoom2rot15", Viewport(scrollOrigin: Point(x: 20, y: 30), rotationDegrees: 15, zoom: 2, size: viewSize)),
        ("zoomHalfRot90", Viewport(scrollOrigin: Point(x: -40, y: 60), rotationDegrees: 90, zoom: 0.5, size: viewSize)),
    ]

    /// A 50,000-rectangle grid, the performance design point.
    static func manyRects(count: Int = 50_000, spacing: Double = 12, edge: Double = 8) -> DisplayList {
        let columns = Int(Double(count).squareRoot().rounded(.up))
        var builder = DisplayListBuilder(canvas: "perf")
        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            let rect = Rect(x: Double(column) * spacing, y: Double(row) * spacing, width: edge, height: edge)
            let color = Color(red: Double(column % 7) / 7, green: Double(row % 5) / 5, blue: 0.5)
            builder.add(.fill(FillItem(path: DisplayPath(rect: rect), paint: .solid(color))))
        }
        return builder.build()
    }
}

/// Rasterizes a one-page PDF back into a bitmap through Core Graphics.
enum PDFRasterizer {
    static func rasterize(_ data: Data, scale: Double, flatteningTolerance: FlatteningTolerance = .standard) -> BitmapSurface? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else {
            return nil
        }
        let box = page.getBoxRect(.mediaBox)
        guard let surface = BitmapSurface(width: Int((box.width * scale).rounded()), height: Int((box.height * scale).rounded())) else {
            return nil
        }
        surface.context.setFlatness(CGFloat(flatteningTolerance.devicePixels))
        surface.context.scaleBy(x: scale, y: scale)
        surface.context.drawPDFPage(page)
        return surface
    }
}

/// Per-pixel comparison: interior pixels (a flat 3 × 3 neighbourhood in the reference) must
/// match within `interiorTolerance` (0 for opaque content); anti-aliased edge pixels may
/// differ by up to `edgeTolerance`.
struct PixelComparison {
    var pixels = 0
    var interiorPixels = 0
    var edgePixels = 0
    var interiorMismatches = 0
    var edgeMismatches = 0
    var maxInteriorDifference = 0
    var maxEdgeDifference = 0

    init(reference: BitmapSurface, candidate: BitmapSurface, interiorTolerance: Int = 0, edgeTolerance: Int) {
        precondition(reference.width == candidate.width && reference.height == candidate.height)
        for y in 0..<reference.height {
            for x in 0..<reference.width {
                pixels += 1
                let difference = reference.pixel(x: x, y: y).maxChannelDifference(to: candidate.pixel(x: x, y: y))
                if reference.isFlat(x: x, y: y) {
                    interiorPixels += 1
                    maxInteriorDifference = max(maxInteriorDifference, difference)
                    if difference > interiorTolerance {
                        interiorMismatches += 1
                    }
                } else {
                    edgePixels += 1
                    maxEdgeDifference = max(maxEdgeDifference, difference)
                    if difference > edgeTolerance {
                        edgeMismatches += 1
                    }
                }
            }
        }
    }

    var passes: Bool { interiorMismatches == 0 && edgeMismatches == 0 }
}

/// A renderer whose tiles never materialize, for the cache's failure path.
struct FailingRenderer: WTRender {
    let flatteningTolerance = FlatteningTolerance.standard
    let viewMode = ViewMode.preview

    func render(_ displayList: DisplayList, viewport: Viewport, into context: CGContext) {}
    func render(_ displayList: DisplayList, tile key: TileKey, geometry: TileGeometry, into context: CGContext) {}
    func renderTile(_ displayList: DisplayList, key: TileKey, geometry: TileGeometry) -> CGImage? { nil }
}
