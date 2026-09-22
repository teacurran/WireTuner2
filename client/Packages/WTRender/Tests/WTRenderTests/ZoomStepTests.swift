import WTGeometry
import Testing
@testable import WTRender

@Suite struct ZoomStepTests {
    @Test func nearestStepAndScale() {
        #expect(ZoomStep(nearest: 1).index == 0)
        #expect(ZoomStep(nearest: 2).index == ZoomStep.stepsPerOctave)
        #expect(ZoomStep(nearest: 0.5).index == -ZoomStep.stepsPerOctave)
        #expect(ZoomStep(index: ZoomStep.stepsPerOctave).scale == 2)
        #expect(ZoomStep(index: 0).scale == 1)
        #expect(ZoomStep(nearest: 0).index == 0, "non-positive scales fall back to 100%")
        #expect(ZoomStep(nearest: -3).index == 0)
        #expect(ZoomStep(nearest: .nan).index == 0)
        #expect(ZoomStep(nearest: .infinity).index == 0)
        #expect(ZoomStep(index: 3).advanced(by: -5) == ZoomStep(index: -2))
        #expect(ZoomStep(index: 1) < ZoomStep(index: 2))
    }

    @Test func anyScaleIsWithinHalfAStepOfItsRung() {
        var scale = 0.06
        while scale <= 256 {
            let step = ZoomStep(nearest: scale)
            let ratio = step.scale / scale
            #expect(ratio > 0.994 && ratio < 1.006, "\(scale) → \(step.scale)")
            scale *= 1.0173
        }
    }

    @Test func presetLadderSitsOnTheGrid() {
        for preset in ZoomLadder.presets.dropFirst(2) {
            #expect(approx(ZoomStep(nearest: preset).scale, preset, tolerance: 1e-12), "\(preset)")
        }
        #expect(abs(ZoomStep(nearest: 0.06).scale / 0.06 - 1) < 0.003)
        #expect(abs(ZoomStep(nearest: 0.12).scale / 0.12 - 1) < 0.003)
    }

    @Test func zoomInAndOutWalkThePresets() {
        #expect(ZoomLadder.zoomIn(from: 1) == 2)
        #expect(ZoomLadder.zoomIn(from: 1.5) == 2)
        #expect(ZoomLadder.zoomIn(from: 256) == 256)
        #expect(ZoomLadder.zoomIn(from: 300) == 256)
        #expect(ZoomLadder.zoomOut(from: 1) == 0.5)
        #expect(ZoomLadder.zoomOut(from: 0.7) == 0.5)
        #expect(ZoomLadder.zoomOut(from: 0.06) == 0.06)
        #expect(ZoomLadder.zoomOut(from: 0.01) == 0.06)
        #expect(ZoomLadder.presets.count == 13)
    }
}

@Suite struct FlatteningToleranceTests {
    @Test func toleranceScalesInverselyWithZoom() {
        let tolerance = FlatteningTolerance.standard
        #expect(tolerance.devicePixels == 0.25)
        #expect(tolerance.pasteboardUnits(atScale: 2) == 0.125)
        #expect(tolerance.pasteboardUnits(atScale: 0.5) == 0.5)
        #expect(tolerance.pasteboardUnits(atScale: 0) == 0.25, "a degenerate scale falls back to device pixels")
        #expect(tolerance.pasteboardUnits(atScale: .nan) == 0.25)
        #expect(FlatteningTolerance(devicePixels: -1).devicePixels == 1e-6)
    }

    @Test func geometryAndViewportOverloadsAgree() {
        let tolerance = FlatteningTolerance(devicePixels: 0.5)
        let viewport = Viewport(zoom: 2, size: Size(width: 10, height: 10))
        let geometry = TileGeometry(viewport: viewport, backingScale: 2)
        #expect(approx(geometry.zoomStep.scale, 4))
        #expect(approx(tolerance.pasteboardUnits(for: geometry), 0.125))
        #expect(approx(tolerance.pasteboardUnits(for: viewport, backingScale: 2), 0.125))
    }
}
