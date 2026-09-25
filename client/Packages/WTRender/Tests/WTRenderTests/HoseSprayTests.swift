import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DRAW-038/DRAW-039: the Graphic Hose's spray layout.
@Suite struct HoseSprayTests {
    /// A horizontal drag from (0, 0) to (length, 0) in `steps` samples taking `seconds`.
    static func spray(_ options: HoseSprayOptions, count: Int = 3, extent: Double = 10, length: Double = 200, steps: Int = 20,
                      seconds: Double = 0.5, seed: UInt64 = 1) -> HoseSprayer {
        var sprayer = HoseSprayer(options: options, objectCount: count, extent: extent, seed: seed)
        sprayer.begin(at: Point(x: 0, y: 0), time: 0)
        for i in 1...steps {
            sprayer.drag(to: Point(x: length * Double(i) / Double(steps), y: 0), time: seconds * Double(i) / Double(steps))
        }
        return sprayer
    }

    @Test func optionsNormalize() {
        let options = HoseSprayOptions(gridSize: 0, spacingAmount: 500, scalePercent: 0, angle: .nan)
        #expect(options.gridSize == 36 && options.spacingAmount == 200 && options.scalePercent == 100 && options.angle == 0)
        let low = HoseSprayOptions(gridSize: -3, spacingAmount: -1, scalePercent: 0.2, angle: 1)
        #expect(low.gridSize == 36 && low.spacingAmount == 0 && low.scalePercent == 1 && low.angle == 1)
        #expect(HoseSprayOptions(gridSize: .infinity, spacingAmount: .nan, scalePercent: 900).gridSize == 36)
        #expect(HoseSprayOptions(spacingAmount: .nan, scalePercent: .nan).spacingAmount == 0)
        #expect(HoseSprayOptions(scalePercent: 900).scalePercent == 200)
    }

    @Test func variableSpacingFollowsTheAmountAndTheSpeed() {
        // 400 pt/s: factor 1; amount 100 → every 11 pt.
        let steady = Self.spray(HoseSprayOptions(spacingAmount: 100), length: 200, seconds: 0.5)
        let centers = steady.placements.map(\.center.x)
        #expect(centers.first == 0 && centers.count == 19)
        for (a, b) in zip(centers, centers.dropFirst()) {
            #expect(abs(b - a - 11) < 1e-9)
        }
        // Faster spreads them out; the factor is clamped to 0.5 ... 3.
        let fast = Self.spray(HoseSprayOptions(spacingAmount: 100), length: 200, seconds: 0.01)
        #expect(fast.placements.count == 7)
        let slow = Self.spray(HoseSprayOptions(spacingAmount: 100), length: 200, seconds: 100)
        #expect(slow.placements.count == 37)
        #expect(HoseSprayer.speedFactor(0) == 0.5 && HoseSprayer.speedFactor(4000) == 3 && HoseSprayer.speedFactor(800) == 2)
        // A tight hose at amount 0.
        #expect((200...201).contains(Self.spray(HoseSprayOptions(spacingAmount: 0)).placements.count))
    }

    @Test func randomSpacingDeviatesWithinTheAmount() {
        let sprayer = Self.spray(HoseSprayOptions(spacing: .random, spacingAmount: 200), length: 400, steps: 40, seconds: 1)
        let gaps = zip(sprayer.placements, sprayer.placements.dropFirst()).map { $1.center.x - $0.center.x }
        #expect(gaps.count > 10)
        #expect(gaps.allSatisfy { $0 >= 1 - 1e-9 && $0 <= 20 + 1e-9 })
        #expect(Set(gaps.map { ($0 * 1000).rounded() }).count > 3)
        // Deterministic for a seed.
        #expect(Self.spray(HoseSprayOptions(spacing: .random, spacingAmount: 200), length: 400, steps: 40, seconds: 1).placements == sprayer.placements)
        #expect(Self.spray(HoseSprayOptions(spacing: .random, spacingAmount: 200), length: 400, steps: 40, seconds: 1, seed: 9).placements
                != sprayer.placements)
    }

    @Test func gridSpacingPlacesOnePerCell() {
        var sprayer = HoseSprayer(options: HoseSprayOptions(spacing: .grid, gridSize: 20), objectCount: 2, extent: 5, seed: 1)
        #expect(sprayer.begin(at: Point(x: 3, y: 3), time: 0).map(\.center) == [Point(x: 10, y: 10)])
        sprayer.drag(to: Point(x: 95, y: 3), time: 0.01)
        sprayer.drag(to: Point(x: 95, y: 3), time: 0.02)
        // Back over visited cells places nothing new; a new row does.
        #expect(sprayer.drag(to: Point(x: 5, y: 5), time: 5).isEmpty)
        let down = sprayer.drag(to: Point(x: 5, y: 25), time: 6)
        #expect(down.map(\.center) == [Point(x: 10, y: 30)])
        #expect(sprayer.placements.map(\.center.x) == [10, 30, 50, 70, 90, 10])
        // Tightening shrinks the cells from here on.
        sprayer.tighten()
        #expect(sprayer.spacingMultiplier == 0.8)
    }

    @Test func orderModes() {
        let loop = Self.spray(HoseSprayOptions(spacingAmount: 100), count: 3)
        #expect(loop.placements.prefix(7).map(\.index) == [0, 1, 2, 0, 1, 2, 0])
        let bounce = Self.spray(HoseSprayOptions(order: .backAndForth, spacingAmount: 100), count: 3)
        #expect(bounce.placements.prefix(9).map(\.index) == [0, 1, 2, 1, 0, 1, 2, 1, 0])
        let single = Self.spray(HoseSprayOptions(order: .backAndForth, spacingAmount: 100), count: 1)
        #expect(single.placements.allSatisfy { $0.index == 0 })
        let random = Self.spray(HoseSprayOptions(order: .random, spacingAmount: 100), count: 4)
        #expect(random.placements.allSatisfy { (0..<4).contains($0.index) } && Set(random.placements.map(\.index)).count > 1)
        // No objects: nothing is placed, whatever the drag.
        #expect(Self.spray(HoseSprayOptions(), count: 0).placements.isEmpty)
        // At most ten objects are sprayed.
        #expect(HoseSprayer(options: HoseSprayOptions(), objectCount: 14, extent: 0, seed: 0).objectCount == 10)
        #expect(HoseSprayer(options: HoseSprayOptions(), objectCount: 1, extent: .nan, seed: 0).extent == 1)
    }

    @Test func scaleAndRotationModes() {
        let uniform = Self.spray(HoseSprayOptions(spacingAmount: 100, scalePercent: 50, angle: 0.5))
        #expect(uniform.placements.allSatisfy { $0.scale == 0.5 && $0.rotation == 0.5 })
        let incremental = Self.spray(HoseSprayOptions(spacingAmount: 100, rotation: .incremental, angle: 0.25))
        #expect(incremental.placements.prefix(3).map(\.rotation) == [0, 0.25, 0.5])
        let random = Self.spray(HoseSprayOptions(spacingAmount: 100, scale: .random, scalePercent: 150, rotation: .random))
        #expect(random.placements.allSatisfy { (0.01...1.5).contains($0.scale) && (0..<(2 * Double.pi)).contains($0.rotation) })
        #expect(Set(random.placements.map(\.scale)).count > 1)
    }

    @Test func arrowKeysAdjustFromTheNextObject() {
        var sprayer = HoseSprayer(options: HoseSprayOptions(spacingAmount: 100), objectCount: 1, extent: 10, seed: 1)
        sprayer.begin(at: .zero, time: 0)
        sprayer.shrink()
        sprayer.drag(to: Point(x: 11, y: 0), time: 11.0 / 400)
        #expect(sprayer.placements.map(\.scale) == [1, 0.8] && sprayer.placements[1].center == Point(x: 11, y: 0))
        sprayer.enlarge()
        sprayer.enlarge()
        sprayer.loosen()
        #expect(abs(sprayer.scaleMultiplier - 1.25) < 1e-9 && sprayer.spacingMultiplier == 1.25)
        for _ in 0..<40 { sprayer.tighten() }
        #expect(sprayer.spacingMultiplier == 0.05)
        for _ in 0..<60 { sprayer.enlarge() }
        #expect(sprayer.scaleMultiplier == 20)
    }

    @Test func aClickPlacesOneAndADragWithoutAPressStartsTheStroke() {
        var click = HoseSprayer(options: HoseSprayOptions(), objectCount: 2, extent: 10, seed: 3)
        #expect(click.begin(at: Point(x: 4, y: 5), time: 0).count == 1)
        #expect(click.drag(to: Point(x: 4, y: 5), time: 1).isEmpty)
        var drag = HoseSprayer(options: HoseSprayOptions(), objectCount: 2, extent: 10, seed: 3)
        #expect(drag.drag(to: Point(x: 1, y: 1), time: 0).map(\.center) == [Point(x: 1, y: 1)])
    }

    @Test func thePlacementTransformScalesRotatesThenMoves() {
        let placement = HosePlacement(index: 0, center: Point(x: 10, y: 20), scale: 2, rotation: Double.pi / 2)
        let mapped = placement.transform.apply(Point(x: 1, y: 0))
        #expect(abs(mapped.x - 10) < 1e-9 && abs(mapped.y - 22) < 1e-9)
        var random = HoseRandom(seed: 5)
        var again = HoseRandom(seed: 5)
        #expect(random.next() == again.next())
    }
}
