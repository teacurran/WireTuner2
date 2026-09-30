import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// OBJ-031's *Fills* and *Contents* options (transforming.adoc, "Data model"; clipping-paths.adoc,
/// "Merge semantics"): fills off keeps gradient and tiled fills on the page, contents off turns a
/// clip group's clip path alone.
@Suite struct TransformOptionsTests {
    static let skew = WTGeometry.AffineTransform(a: 1.5, b: 0.25, c: 0.6, d: 0.8, tx: 0, ty: 0)
    static let pivot = Point(x: 13, y: -4)
    static let fillsOff = TransformOptions(fills: false)

    /// A 10 pt rectangle at `x` with a gradient fill of `type`; the fill's row.
    static func gradient(_ a: inout Replica, x: Double = 0, type: Wiretuner_Doc_V1_GradientType = .linear) throws -> (node: OpID, row: AppearanceRow) {
        let fill = try GradientCommandTests.filled(&a, x: x)
        try a.perform(ChooseGradient([fill], type: type))
        return fill
    }

    /// A 10 pt rectangle with a tiled fill at 30°, 50% by 200%, offset (2, 3); the fill's row.
    static func tiled(_ a: inout Replica) throws -> (node: OpID, row: AppearanceRow) {
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 4), on: &a)
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.kind = .tiled
        fill.settings.tiled.angle = 30
        fill.settings.tiled.scaleX = 50
        fill.settings.tiled.scaleY = 200
        fill.settings.tiled.offset = PathEditing.proto(Point(x: 2, y: 3))
        try a.perform(AddAppearance.fill([rect], fill))
        return (rect, AppearanceEditing.stack(rect, in: a.state).first { $0.list == .fills }!)
    }

    static func stored(_ fill: (node: OpID, row: AppearanceRow), _ state: EngineState) -> Wiretuner_Doc_V1_Fill {
        AppearanceEditing.entries(fill.node, in: state).first { $0.row == fill.row }!.fill
    }

    /// Where on the ramp a pasteboard point falls (Linear), through the node's chain.
    static func ramp(at point: Point, _ fill: (node: OpID, row: AppearanceRow), _ state: EngineState) -> Double {
        let gradient = stored(fill, state).settings.gradient
        let local = Objects.pasteboardTransform(of: fill.node, in: state).inverse.apply(point)
        let s = Point(x: gradient.axis.start.x, y: gradient.axis.start.y), e = Point(x: gradient.axis.end.x, y: gradient.axis.end.y)
        return (local - s).dot(e - s) / (e - s).lengthSquared
    }

    /// The gradient frame (start, end, end2) in pasteboard space.
    static func frame(_ fill: (node: OpID, row: AppearanceRow), _ state: EngineState) -> [Point] {
        let axis = stored(fill, state).settings.gradient.axis
        let p = Objects.pasteboardTransform(of: fill.node, in: state)
        return [axis.start, axis.end, axis.end2].map { p.apply(Point(x: $0.x, y: $0.y)) }
    }

    /// The tile's placement (pattern space → pasteboard).
    static func tilePlacement(_ fill: (node: OpID, row: AppearanceRow), _ state: EngineState) -> WTGeometry.AffineTransform {
        let tiled = stored(fill, state).settings.tiled
        return WTGeometry.AffineTransform.scale(x: tiled.scaleX / 100, y: tiled.scaleY / 100)
            .concatenating(.rotation(radians: tiled.angle * .pi / 180))
            .concatenating(.translation(x: tiled.offset.x, y: tiled.offset.y))
            .concatenating(Objects.pasteboardTransform(of: fill.node, in: state))
    }

    static func near(_ a: Point, _ b: Point) -> Bool { a.distance(to: b) < 1e-9 }

    // MARK: Fills

    @Test func fillsOffKeepsALinearGradientOnThePageUnderAnyMatrix() throws {
        var a = Replica(0xA)
        let fill = try Self.gradient(&a)
        try a.perform(EditGradient.axis([fill], start: Point(x: 1, y: 2), end: Point(x: 9, y: 5)))
        let probes = [Point(x: 3, y: 3), Point(x: -20, y: 7), Point(x: 40, y: -11)]
        let before = probes.map { Self.ramp(at: $0, fill, a.state) }
        let change = try a.perform(TransformObjects([fill.node], matrix: Self.skew, about: Self.pivot, kind: .skew, options: Self.fillsOff))!
        #expect(change.ops.count == 2, "the transform and the axis, one change")
        #expect(!Objects.transform(of: fill.node, in: a.state).isIdentity)
        for (probe, t) in zip(probes, before) { #expect(abs(Self.ramp(at: probe, fill, a.state) - t) < 1e-9) }
        // With Fills on the ramp moves with the object.
        try a.perform(TransformObjects([fill.node], matrix: .rotation(radians: 0.5), kind: .rotate))
        #expect(abs(Self.ramp(at: probes[1], fill, a.state) - before[1]) > 1e-3)
        // Undo puts the axis and the transform back in one step.
        a.undo()
        a.undo()
        #expect(Objects.transform(of: fill.node, in: a.state).isIdentity)
        #expect(Self.stored(fill, a.state).settings.gradient.axis.end.x == 9)
    }

    @Test func autoSizeGeometryIsWrittenOutAndBecomesNormal() throws {
        var a = Replica(0xA)
        let fill = try Self.gradient(&a, x: 20)
        try a.perform(EditGradient.behavior([fill], .autoSize))
        let probe = Point(x: 24, y: 5)
        // Auto size on the 10 pt square at x = 20: the ramp runs across the bounds.
        let expected = 0.4
        try a.perform(TransformObjects([fill.node], matrix: .scale(x: 3, y: 1), about: .zero, kind: .scale, options: Self.fillsOff))
        let gradient = Self.stored(fill, a.state).settings.gradient
        #expect(gradient.behavior == .normal && gradient.hasAxis)
        #expect(abs(Self.ramp(at: probe, fill, a.state) - expected) < 1e-9)
        // An unset axis (never dragged) is Auto size geometry too; its behaviour stays.
        let other = try Self.gradient(&a, x: 40)
        try a.perform(TransformObjects([other.node], matrix: .translation(x: 5, y: 0), kind: .move, options: Self.fillsOff))
        let moved = Self.stored(other, a.state).settings.gradient
        #expect(moved.hasAxis && moved.behavior != .autoSize)
        #expect(Self.near(Self.frame(other, a.state)[0], Point(x: 40, y: 5)))
    }

    @Test func radialAndRectangleHandlesMapExactly() throws {
        var a = Replica(0xA)
        let radial = try Self.gradient(&a, type: .radial)
        try a.perform(EditGradient.axis([radial], start: Point(x: 5, y: 5), end: Point(x: 9, y: 5)))
        let rectangle = try Self.gradient(&a, x: 30, type: .rectangle)
        let before = Self.frame(radial, a.state)
        try a.perform(TransformObjects([radial.node, rectangle.node], matrix: Self.skew, about: Self.pivot, kind: .skew, options: Self.fillsOff))
        let unset = Point(x: 5, y: 9)   // end2 unset reads as end - start turned 90°
        #expect(zip(Self.frame(radial, a.state), [before[0], before[1], unset]).allSatisfy { Self.near($0, $1) })
        // Auto size on the square at x = 30: the centre, the half width and the half height.
        let expected = [Point(x: 35, y: 5), Point(x: 40, y: 5), Point(x: 35, y: 10)]
        #expect(zip(Self.frame(rectangle, a.state), expected).allSatisfy { Self.near($0, $1) })
    }

    @Test func coneMapsItsHandlesAndAutoContourIsLeftAlone() throws {
        var a = Replica(0xA)
        let cone = try Self.gradient(&a, type: .cone)
        try a.perform(EditGradient.axis([cone], start: Point(x: 5, y: 5), end: Point(x: 6, y: 8)))
        let contour = try Self.gradient(&a, x: 30, type: .contour)
        let before = Self.frame(cone, a.state)
        let change = try a.perform(TransformObjects([cone.node, contour.node], matrix: .rotation(radians: 1), about: Self.pivot, kind: .rotate,
                                                    options: Self.fillsOff))!
        #expect(change.ops.count == 3, "two transforms and the cone's axis")
        #expect(zip(Self.frame(cone, a.state), before).prefix(2).allSatisfy { Self.near($0, $1) })
        #expect(!Self.stored(contour, a.state).settings.gradient.hasAxis)
    }

    @Test func tiledFillsStayOnThePage() throws {
        var a = Replica(0xA)
        let fill = try Self.tiled(&a)
        let before = Self.tilePlacement(fill, a.state)
        let similarity = WTGeometry.AffineTransform.rotation(radians: 0.7).concatenating(.scale(2.5))
        let change = try a.perform(TransformObjects([fill.node], matrix: similarity, about: Self.pivot, kind: .rotate, options: Self.fillsOff))!
        #expect(change.ops.count == 2)
        #expect(nearly(Self.tilePlacement(fill, a.state), before, 1e-9))
        // A reflection cannot be held by the tile's registers: the scales stay positive and the
        // tile keeps its place.
        try a.perform(TransformObjects([fill.node], matrix: .scale(x: -1, y: 1), about: Self.pivot, kind: .reflect, options: Self.fillsOff))
        let tiled = Self.stored(fill, a.state).settings.tiled
        #expect(tiled.scaleX > 0 && tiled.scaleY > 0)
        let origin = Self.tilePlacement(fill, a.state).apply(Point.zero)
        #expect(Self.near(origin, before.apply(Point.zero)))
    }

    @Test func fillsOffReachesGroupMembersAndCopies() throws {
        var a = Replica(0xA)
        let fill = try Self.gradient(&a)
        try a.perform(EditGradient.axis([fill], start: Point(x: 0, y: 0), end: Point(x: 10, y: 0)))
        let plain = try LayerFixture.object(LayerFixture.rect(on: nil, x: 50), on: &a)
        let group = try a.perform(GroupObjects([fill.node, plain]))!.createdObjects[0]
        let probe = Point(x: 4, y: 4)
        let before = Self.ramp(at: probe, fill, a.state)
        let change = try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.3), about: Self.pivot, kind: .rotate, options: Self.fillsOff))!
        #expect(change.ops.count == 2, "the group's transform and the member's axis")
        #expect(abs(Self.ramp(at: probe, fill, a.state) - before) < 1e-9)
        // Copies: each copy's member keeps the ramp on the page.
        let copies = try a.perform(TransformObjects([group], matrix: .translation(x: 3, y: 1), kind: .move, options: Self.fillsOff, copies: 2))!.createdRoots
        #expect(copies.count == 2)
        for copy in copies {
            let member = state(a).liveChildren(copy)[0]
            let row = AppearanceEditing.stack(member, in: a.state).first { $0.list == .fills }!
            #expect(abs(Self.ramp(at: probe, (member, row), a.state) - before) < 1e-9)
        }
        // With Fills on, a copy's ramp moves with it.
        let moving = try a.perform(TransformObjects([fill.node], matrix: .translation(x: 3, y: 0), kind: .move, copies: 1))!.createdRoots[0]
        let row = AppearanceEditing.stack(moving, in: a.state).first { $0.list == .fills }!
        #expect(abs(Self.ramp(at: probe, (moving, row), a.state) - before) > 0.1)
    }

    @Test func compensationSkipsWhatDoesNotMoveWithTheObject() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let change = try a.perform(TransformObjects([rect], matrix: .scale(2), kind: .scale, options: Self.fillsOff))!
        #expect(change.ops.count == 1, "a basic fill has nothing to map")
        let fill = Self.stored((rect, AppearanceEditing.stack(rect, in: a.state).first { $0.list == .fills }!), a.state)
        #expect(TransformFills.compensated(fill, by: .scale(2), bounds: nil) == nil)
        #expect(TransformFills.compensated(fill, by: .identity, bounds: nil) == nil)
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.type = .linear
        #expect(TransformFills.gradient(gradient, by: .scale(2), bounds: nil) == nil, "Auto size without bounds")
        #expect(TransformFills.autoAxis(.linear, bounds: Rect(x: 3, y: 0, width: 0, height: 4)).end == Point(x: 4, y: 2))
        #expect(TransformFills.localBounds(WellKnown.layers, in: a.state) == nil)
        // A tiled fill never given a scale reads 100%, an unreadable angle or offset 0.
        var tiled = Wiretuner_Doc_V1_TiledFill()
        tiled.angle = .nan
        tiled.offset.x = .infinity
        let mapped = TransformFills.tiled(tiled, by: .translation(x: 2, y: 3))
        #expect(mapped.scaleX == 100 && mapped.scaleY == 100 && mapped.angle == 0 && mapped.offset == PathEditing.proto(Point(x: 2, y: 3)))
    }

    @Test func aConcurrentAxisDragAndAFillsOffRotateConverge() throws {
        var pair = Pair()
        let fill = try Self.gradient(&pair.a)
        try pair.a.perform(EditGradient.axis([fill], start: Point(x: 0, y: 0), end: Point(x: 10, y: 0)))
        pair.sync()
        try pair.b.perform(EditGradient.axis([fill], start: Point(x: 2, y: 2), end: Point(x: 8, y: 2)))
        try pair.a.perform(TransformObjects([fill.node], matrix: .rotation(radians: 0.4), kind: .rotate, options: Self.fillsOff))
        let theirs = Self.stored(fill, pair.b.state).settings.gradient.axis
        let mine = Self.stored(fill, pair.a.state).settings.gradient.axis
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // The matrix and the axis are separate registers: the rotation stands, the axis is one
        // whole value (the later writer's).
        #expect(!Objects.transform(of: fill.node, in: pair.a.state).isIdentity)
        let axis = Self.stored(fill, pair.a.state).settings.gradient.axis
        #expect(axis == mine || axis == theirs)
        #expect(mine != theirs)
    }

    // MARK: Contents

    @Test func contentsOffTurnsTheClipPathAlone() throws {
        var a = Replica(0xA)
        let (path, contents, _) = try ClippingTests.fixture(on: &a)
        let group = try a.perform(PasteContents(try ClippingTests.cut(contents, on: &a), into: path))!.createdObjects[0]
        let inside = ClipGroups.contents(of: group, in: a.state)
        let before = ClippingTests.bounds(inside, in: a.state)
        let pathBefore = Objects.transform(of: path, in: a.state)
        let off = TransformOptions(contents: false)
        let change = try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.5), about: Self.pivot, kind: .rotate, options: off))!
        #expect(change.ops.count == 1)
        #expect(Objects.transform(of: group, in: a.state).isIdentity, "G.transform untouched")
        #expect(nearly(Objects.transform(of: path, in: a.state), pathBefore.concatenating(.rotation(radians: 0.5, around: Self.pivot))))
        #expect(ClippingTests.bounds(inside, in: a.state) == before)
        // A move always moves both.
        try a.perform(TransformObjects([group], matrix: .translation(x: 4, y: 0), kind: .move, options: off))
        #expect(Objects.transform(of: group, in: a.state) == .translation(x: 4, y: 0))
        // Copies: the group is copied with its clip path turned one step further each time.
        let copies = try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.5), about: Self.pivot, kind: .rotate, options: off, copies: 2))!.createdRoots
        #expect(copies.count == 2)
        for (k, copy) in copies.enumerated() {
            let clip = try #require(ClipGroups.clipPath(of: copy, in: a.state))
            #expect(Objects.transform(of: copy, in: a.state) == Objects.transform(of: group, in: a.state))
            let turned = Objects.transform(of: path, in: a.state).concatenating(.rotation(radians: 0.5 * Double(k + 1), around: Point(x: Self.pivot.x - 4, y: Self.pivot.y)))
            #expect(nearly(Objects.transform(of: clip, in: a.state), turned))
            #expect(ClippingTests.bounds(ClipGroups.contents(of: copy, in: a.state), in: a.state) == ClippingTests.bounds(inside, in: a.state))
        }
        // A locked clip path, or a plain group, moves the whole group.
        try a.perform(SetLocked([path], locked: true))
        try a.perform(TransformObjects([group], matrix: .scale(2), kind: .scale, options: off))
        #expect(Objects.transform(of: group, in: a.state).a == 2)
    }

    @Test func contentsOffAndFillsOffTogetherKeepTheClipPathsFill() throws {
        var a = Replica(0xA)
        let (path, contents, _) = try ClippingTests.fixture(on: &a)
        try a.perform(AddAppearance.fill([path], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let row = AppearanceEditing.stack(path, in: a.state).first { $0.list == .fills }!
        try a.perform(ChooseGradient([(path, row)]))
        try a.perform(EditGradient.axis([(path, row)], start: Point(x: 0, y: 0), end: Point(x: 40, y: 0)))
        let group = try a.perform(PasteContents(try ClippingTests.cut(contents, on: &a), into: path))!.createdObjects[0]
        let probe = Point(x: 20, y: 20)
        let before = Self.ramp(at: probe, (path, row), a.state)
        let options = TransformOptions(fills: false, contents: false)
        try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.5), about: Self.pivot, kind: .rotate, options: options))
        #expect(abs(Self.ramp(at: probe, (path, row), a.state) - before) < 1e-9)
        let copy = try a.perform(TransformObjects([group], matrix: .scale(2), about: Self.pivot, kind: .scale, options: options, copies: 1))!.createdRoots[0]
        let clip = try #require(ClipGroups.clipPath(of: copy, in: a.state))
        let copyRow = AppearanceEditing.stack(clip, in: a.state).first { $0.list == .fills }!
        #expect(abs(Self.ramp(at: probe, (clip, copyRow), a.state) - before) < 1e-9)
    }
}

private func state(_ replica: Replica) -> EngineState { replica.state }
