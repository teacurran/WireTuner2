import CoreGraphics
import Foundation
import QuartzCore
import Testing
import WTGeometry
@testable import WTRender

/// COLLAB-035's render half: measurements, formatting and the overlay layer.
@Suite struct InspectOverlayTests {
    @Test func unitsAndScaleFormatValues() {
        #expect(InspectFormat().string(12.5) == "12.5 pt")
        #expect(InspectFormat(unit: .pixels, scale: 2).string(100) == "200 px")
        #expect(InspectFormat(unit: .inches).string(36) == "0.5 in")
        #expect(InspectFormat(unit: .millimeters).string(72) == "25.4 mm")
        #expect(InspectFormat(unit: .centimeters, decimals: 1).string(72) == "2.5 cm")
        #expect(InspectFormat(unit: .points, decimals: 0).string(-0.2) == "0 pt")
        #expect(InspectFormat(unit: .pixels, scale: -3).scale == 1)
        #expect(InspectFormat(unit: .pixels, scale: 3).size(Size(width: 10, height: 4.25)) == "30 × 12.75 px")
        #expect(InspectFormat().coordinates(Point(x: 15, y: 30), origin: Point(x: 5, y: 10)) == "x 10 pt, y 20 pt")
        #expect(InspectUnit.allCases.map(\.symbol) == ["pt", "px", "mm", "cm", "in"])
    }

    @Test func gapsBetweenSeparateObjectsAndTheOverlap() {
        let selected = Rect(x: 0, y: 0, width: 10, height: 10)
        // To the right, sharing a vertical span: one horizontal gap through the shared middle.
        let right = InspectMeasurements.measure(hovered: Rect(x: 30, y: 4, width: 10, height: 10), selected: selected)
        #expect(right.lines == [InspectLine(from: Point(x: 10, y: 7), to: Point(x: 30, y: 7), axis: .horizontal)])
        #expect(right.lines[0].distance == 20 && right.lines[0].middle == Point(x: 20, y: 7))
        #expect(right.outline == Rect(x: 30, y: 4, width: 10, height: 10) && right.overlap == nil)
        // Up and to the left, sharing nothing: both gaps, through the hovered object's middle.
        let diagonal = InspectMeasurements.gaps(from: selected, to: Rect(x: -20, y: -30, width: 5, height: 5))
        #expect(diagonal.lines == [InspectLine(from: Point(x: -15, y: -27.5), to: Point(x: 0, y: -27.5), axis: .horizontal),
                                   InspectLine(from: Point(x: -17.5, y: -25), to: Point(x: -17.5, y: 0), axis: .vertical)])
        #expect(diagonal.lines[1].distance == 25)
        // Below, sharing a horizontal span.
        let below = InspectMeasurements.gaps(from: selected, to: Rect(x: 2, y: 15, width: 4, height: 4))
        #expect(below.lines == [InspectLine(from: Point(x: 4, y: 10), to: Point(x: 4, y: 15), axis: .vertical)])
        // Overlapping: the intersection, no lines.
        let overlap = InspectMeasurements.measure(hovered: Rect(x: 5, y: 5, width: 10, height: 10), selected: selected)
        #expect(overlap.lines.isEmpty && overlap.overlap == Rect(x: 5, y: 5, width: 5, height: 5))
    }

    @Test func pageEdgeDistancesPointsAndNothing() {
        let page = Rect(x: 0, y: 0, width: 100, height: 200)
        let lines = InspectMeasurements.measure(hovered: Rect(x: 10, y: 20, width: 30, height: 40), container: page).lines
        #expect(lines.map(\.distance) == [10, 60, 20, 140])
        // The selected object itself hovered: just its outline.
        let same = Rect(x: 1, y: 1, width: 2, height: 2)
        #expect(InspectMeasurements.measure(hovered: same, selected: same, container: page).lines.isEmpty)
        let point = InspectMeasurements.measure(hovered: nil, point: Point(x: 3, y: 4), origin: Point(x: 1, y: 1))
        #expect(point.outline == nil && point.point == Point(x: 3, y: 4) && !point.isEmpty)
        #expect(InspectMeasurements.measure(hovered: .null).isEmpty)
        #expect(InspectMeasurements.empty.isEmpty)
    }

    @Test func shiftFreezesWhatIsShown() {
        var state = InspectOverlayState()
        let first = InspectMeasurements.measure(hovered: Rect(x: 0, y: 0, width: 1, height: 1))
        let changed = state.update(first)
        let again = state.update(first)
        #expect(changed && !again)
        state.frozen = true
        let frozen = state.update(.empty)
        #expect(!frozen)
        #expect(state.shown == first)
        state.clear()
        #expect(state.shown.isEmpty && !state.frozen)
    }

    static func bitmap(_ size: Int = 200) -> CGContext {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // y down, as a flipped layer draws.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    static func painted(_ context: CGContext) -> Int {
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(context.width * context.height)).filter { data[$0 * 4 + 3] != 0 }.count
    }

    @Test func theRendererDrawsEveryPart() {
        let viewport = Viewport(zoom: 2, size: Size(width: 200, height: 200))
        let measurements = InspectMeasurements(outline: Rect(x: 10, y: 10, width: 20, height: 20),
                                               lines: [InspectLine(from: Point(x: 30, y: 20), to: Point(x: 60, y: 20), axis: .horizontal)],
                                               overlap: Rect(x: 12, y: 12, width: 4, height: 4), point: Point(x: 70, y: 70))
        let context = Self.bitmap()
        InspectOverlayRenderer.draw(measurements, format: InspectFormat(unit: .pixels, scale: 2), viewport: viewport, in: context)
        #expect(Self.painted(context) > 500)
        // A zero-length line still draws its ticks without dividing by zero.
        let degenerate = Self.bitmap()
        InspectOverlayRenderer.draw(InspectMeasurements(lines: [InspectLine(from: .zero, to: .zero, axis: .vertical)]),
                                    format: InspectFormat(), viewport: viewport, in: degenerate)
        #expect(Self.painted(degenerate) > 0)
    }

    @Test func theLayerRedrawsOnlyForChanges() {
        let layer = InspectOverlayLayer()
        #expect(layer.isGeometryFlipped)
        layer.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let measurements = InspectMeasurements.measure(hovered: Rect(x: 10, y: 10, width: 30, height: 30), container: Rect(x: 0, y: 0, width: 90, height: 90))
        // Nothing to draw without a viewport.
        let blank = Self.bitmap()
        layer.draw(in: blank)
        #expect(Self.painted(blank) == 0)
        layer.viewport = Viewport(size: Size(width: 200, height: 200))
        layer.format = InspectFormat(unit: .millimeters)
        #expect(layer.show(measurements))
        #expect(!layer.show(measurements))
        layer.frozen = true
        #expect(layer.frozen && !layer.show(.empty))
        let drawn = Self.bitmap()
        layer.draw(in: drawn)
        #expect(Self.painted(drawn) > 0)
        let copy = InspectOverlayLayer(layer: layer)
        #expect(copy.state == layer.state && copy.viewport == layer.viewport && copy.format == layer.format)
        _ = InspectOverlayLayer(layer: CALayer())
        layer.clear()
        #expect(layer.state.shown.isEmpty)
    }
}
