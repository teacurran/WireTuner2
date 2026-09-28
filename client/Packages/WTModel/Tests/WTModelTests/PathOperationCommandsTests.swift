import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Transparency, Expand Stroke and Inset Path (OBJ-026, OBJ-029, OBJ-030).
@Suite struct PathOperationCommandsTests {
    typealias Fixture = CombineCommandTests

    /// An appearance of one basic stroke of grey `level`, `width` wide, and no fill.
    static func stroked(_ level: Double, width: Double, cap: Wiretuner_Doc_V1_LineCap = .butt, join: Wiretuner_Doc_V1_LineJoin = .miter,
                        dash: [Double] = []) -> Wiretuner_Doc_V1_AppearanceProps {
        var stroke = Appearances.basicStroke(red: level, green: level, blue: level, width: width)
        stroke.settings.basic.cap = cap
        stroke.settings.basic.join = join
        if !dash.isEmpty { stroke.settings.basic.dash = Wiretuner_Doc_V1_DashPattern.with { $0.lengths = dash } }
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.strokes = [stroke]
        return appearance
    }

    static func line(_ a: inout Replica, _ coordinates: [(Double, Double)], appearance: Wiretuner_Doc_V1_AppearanceProps,
                     closed: Bool = false) throws -> OpID {
        let points = PathFixture.points(coordinates)
        return try LayerFixture.object(CreatePath(contours: [NewContour(closed: closed, points: points)], appearance: appearance), on: &a)
    }

    /// The sRGB red of `node`'s first fill.
    static func red(_ node: OpID, in state: EngineState) -> Double? {
        state.props(node).path.appearance.fills.first?.settings.basic.color.inline.rgb.r
    }

    static func gradient(_ stops: [(Double, Double)]) -> Wiretuner_Doc_V1_FillSettings {
        var settings = Wiretuner_Doc_V1_FillSettings()
        settings.kind = .gradient
        settings.gradient.stops = stops.enumerated().map { index, stop in
            Wiretuner_Doc_V1_GradientStop.with {
                $0.id = Ops.elementID(OpID(counter: UInt64(index + 1), replica: 9))
                $0.offset = stop.0
                $0.color = Appearances.inline(red: stop.1, green: stop.1, blue: stop.1)
            }
        }
        return settings
    }

    // MARK: Transparency

    @Test func transparencyFillsTheOverlapWithTheMixedColourAndKeepsTheInputs() throws {
        var a = Replica(0xA)
        let back = try Fixture.square(&a, x: 0, level: 0.2)
        let front = try Fixture.square(&a, x: 10, level: 0.8)
        let above = try Fixture.square(&a, x: 300)
        #expect(TransparencyCommand.canPerform([front, back], in: a.state))
        let change = try #require(try a.perform(TransparencyCommand([front, back], percent: 50)))
        #expect(change.label == "Transparency")
        let result = try #require(change.createdObjects.first)
        #expect(abs(try #require(Self.red(result, in: a.state)) - 0.5) < 1e-9)
        #expect(a.state.props(result).path.appearance.strokes.isEmpty && !a.state.props(result).path.common.hasTransform)
        #expect(abs(Fixture.area(result, in: a.state) - 200) < 1e-6)
        #expect(a.state.isLive(back) && a.state.isLive(front), "never consumes")
        let layer = try #require(Objects.parent(of: result, in: a.state))
        #expect(a.state.liveChildren(layer).suffix(3) == [front, result, above], "on top of the frontmost")
        // 0% shows the back colour, 100% the front.
        #expect(TransparencyCommand.mixedColor([back, front], percent: 0, in: a.state)?.red == 0.2)
        #expect(abs(try #require(TransparencyCommand.mixedColor([back, front], percent: 100, in: a.state)?.red) - 0.8) < 1e-9)
        a.undo()
        #expect(!a.state.isLive(result))
    }

    @Test func transparencyAveragesAGradientFill() throws {
        var a = Replica(0xA)
        let back = try Fixture.square(&a, x: 0, level: 1)
        let front = try Fixture.square(&a, x: 10, level: 0)
        let fill = AppearanceEditing.stack(front, in: a.state).first { $0.list == .fills }!
        try a.perform(ChooseGradient([(front, fill)]))
        let result = try #require(try a.perform(TransparencyCommand([back, front], percent: 100))?.createdObjects.first)
        #expect(abs(try #require(Self.red(result, in: a.state)) - 0.5) < 1e-9, "black to white averages to mid grey")
    }

    @Test func transparencyValidation() throws {
        var a = Replica(0xA)
        let one = try Fixture.square(&a, x: 0)
        let two = try Fixture.square(&a, x: 10)
        let three = try Fixture.square(&a, x: 5)
        let far = try Fixture.square(&a, x: 500)
        let unfilled = try Self.line(&a, [(0, 0), (20, 0), (20, 20)], appearance: Self.stroked(0, width: 1), closed: true)
        let open = try LayerFixture.object(PathFixture.open([(0, 0), (20, 0)]), on: &a)
        #expect(!TransparencyCommand.canPerform([one], in: a.state))
        #expect(!TransparencyCommand.canPerform([one, two, three], in: a.state))
        #expect(!TransparencyCommand.canPerform([one, unfilled], in: a.state))
        #expect(!TransparencyCommand.canPerform([one, open], in: a.state))
        #expect(TransparencyCommand.overlap([one], in: a.state).isEmpty && TransparencyCommand.mixedColor([one], percent: 50, in: a.state) == nil)
        #expect(try a.perform(TransparencyCommand([one, far])) == nil, "no overlap, no change")
        #expect(try a.perform(TransparencyCommand([one])) == nil)
    }

    @Test func averageColoursOfEveryFillKind() {
        let resolver = ColorResolver(EngineState())
        let grey = { (level: Double) in Appearances.inline(red: level, green: level, blue: level) }
        func settings(_ build: (inout Wiretuner_Doc_V1_FillSettings) -> Void) -> Wiretuner_Doc_V1_FillSettings {
            var value = Wiretuner_Doc_V1_FillSettings()
            build(&value)
            return value
        }
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .lens; $0.lens.color = grey(0.3) }, resolver: resolver)?.red == 0.3)
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .pattern; $0.pattern.color = grey(0.4) }, resolver: resolver)?.red == 0.4)
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .textured; $0.textured.color = grey(0.6) }, resolver: resolver)?.red == 0.6)
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .tiled }, resolver: resolver) == .white)
        let custom = PathOperationPaint.averageColor(settings { $0.kind = .custom; $0.custom.color = grey(0.2); $0.custom.color2 = grey(0.6) }, resolver: resolver)
        #expect(abs((custom?.red ?? 0) - 0.4) < 1e-9)
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .custom }, resolver: resolver) == nil)
        #expect(PathOperationPaint.averageColor(settings { $0.kind = .basic; $0.basic.color = ColorResolver.none }, resolver: resolver) == nil)
        // Ramps: flat past the ends, a single stop is its colour, none reads as nothing.
        #expect(abs((PathOperationPaint.averageColor(Self.gradient([(0.5, 0), (1, 1)]), resolver: resolver)?.red ?? 0) - 0.25) < 1e-9)
        #expect(PathOperationPaint.averageColor(Self.gradient([(0.3, 0.7)]), resolver: resolver)?.red == 0.7)
        #expect(PathOperationPaint.averageColor(Self.gradient([(0, 0.7), (0, 0.7)]), resolver: resolver)?.red == 0.7)
        #expect(PathOperationPaint.averageColor(Self.gradient([]), resolver: resolver) == nil)
        // Mixing: one shared space stays, mixed spaces meet in Display P3.
        let cmyk = PathOperationPaint.mix(Color(cyan: 0, magenta: 0, yellow: 0, black: 1), Color(cyan: 1, magenta: 0, yellow: 0, black: 0), amount: 0.5)
        #expect(cmyk.space == .cmyk && cmyk.components == SIMD4(0.5, 0, 0, 0.5))
        #expect(PathOperationPaint.mix(.black, Color(cyan: 1, magenta: 0, yellow: 0, black: 0), amount: 2).space == .displayP3)
    }

    @Test func strokeColoursOfEveryStrokeKind() {
        let grey = Appearances.inline(red: 0.5, green: 0.5, blue: 0.5)
        func settings(_ build: (inout Wiretuner_Doc_V1_StrokeSettings) -> Void) -> Wiretuner_Doc_V1_StrokeSettings {
            var value = Wiretuner_Doc_V1_StrokeSettings()
            build(&value)
            return value
        }
        #expect(PathOperationPaint.strokeColor(settings { $0.kind = .brush; $0.brush.color = grey }) == grey)
        #expect(PathOperationPaint.strokeColor(settings { $0.kind = .calligraphic; $0.calligraphic.color = grey }) == grey)
        #expect(PathOperationPaint.strokeColor(settings { $0.kind = .custom; $0.custom.color = grey }) == grey)
        #expect(PathOperationPaint.strokeColor(settings { $0.kind = .pattern; $0.pattern.color = grey }) == grey)
        #expect(PathOperationPaint.strokeColor(settings { $0.basic.color = grey }) == grey)
        #expect(PathOperationPaint.strokeColor(settings { $0.basic.color = ColorResolver.none }) == nil)
        #expect(PathOperationPaint.strokeColor(settings { _ in }) == nil)
    }

    // MARK: Expand Stroke

    @Test func aTwoPointLineExpandsToAFourPointClosedPathFilledWithTheStrokeColour() throws {
        var a = Replica(0xA)
        let line = try Self.line(&a, [(0, 0), (100, 0)], appearance: Self.stroked(0.3, width: 10))
        #expect(ExpandStrokeCommand.style([line], in: a.state).width == 10)
        let change = try #require(try a.perform(ExpandStrokeCommand([line], width: 10)))
        #expect(change.label == "Expand Stroke")
        let result = try #require(change.createdObjects.first)
        let path = try #require(Objects.localPath(result, in: a.state))
        #expect(path.contours.count == 1 && path.contours[0].closed && path.contours[0].points.count == 4)
        #expect(Self.red(result, in: a.state) == 0.3 && a.state.props(result).path.appearance.strokes.isEmpty)
        #expect(abs(Fixture.area(result, in: a.state) - 1000) < 1e-6)
        #expect(!a.state.isLive(line))
        a.undo()
        #expect(a.state.isLive(line) && !a.state.isLive(result))
    }

    @Test func aClosedPathExpandsToATwoContourCompositeAndKeepsItsOriginalOnRequest() throws {
        var a = Replica(0xA)
        let square = try Self.line(&a, [(0, 0), (100, 0), (100, 100), (0, 100)], appearance: Self.stroked(0.1, width: 4), closed: true)
        let other = try Self.line(&a, [(200, 0), (300, 0)], appearance: Self.stroked(0.2, width: 2))
        let change = try #require(try a.perform(ExpandStrokeCommand([other, square], width: 4, keepOriginal: true)))
        #expect(change.createdObjects.count == 2, "each input one by one")
        let composite = try #require(change.createdObjects.first { Objects.localPath($0, in: a.state)?.contours.count == 2 })
        #expect(abs(Fixture.area(composite, in: a.state) - (104 * 104 - 96 * 96)) < 1e-6)
        #expect(a.state.isLive(square) && a.state.isLive(other))
    }

    @Test func theOutlineMatchesTheRenderedStrokeForEveryCapAndJoin() throws {
        let caps: [(Wiretuner_Doc_V1_LineCap, WTGeometry.LineCap)] = [(.butt, .butt), (.round, .round), (.square, .square)]
        let joins: [(Wiretuner_Doc_V1_LineJoin, WTGeometry.LineJoin)] = [(.miter, .miter), (.round, .round), (.bevel, .bevel)]
        for (storedCap, cap) in caps {
            for (storedJoin, join) in joins {
                var a = Replica(0xA)
                let transform = AffineTransform.scale(x: 1.5, y: 1).concatenating(.translation(x: 10, y: 10))
                let zigzag = try Self.line(&a, [(10, 10), (40, 60), (70, 15), (100, 50)], appearance: Self.stroked(0, width: 8, cap: storedCap, join: storedJoin))
                try a.perform(TransformObjects([zigzag], matrix: transform, kind: .scale))
                let region = Rect(x: 0, y: 0, width: 180, height: 90)
                let before = Fixture.pixels(a.state, region: region)
                let style = ExpandStrokeCommand.style([zigzag], in: a.state)
                #expect(style.cap == cap && style.join == join)
                try #require(try a.perform(ExpandStrokeCommand([zigzag], width: 8, cap: cap, join: join, miterLimit: style.miterLimit)))
                let after = Fixture.pixels(a.state, region: region)
                #expect(CombineExpandTests.difference(before, after) < 0.002, "\(cap) \(join)")
            }
        }
    }

    @Test func aDashedStrokeExpandsAsItsDashesAndNoStrokeFillsBlack() throws {
        var a = Replica(0xA)
        let dashed = try Self.line(&a, [(0, 0), (100, 0)], appearance: Self.stroked(0, width: 2, dash: [10, 10]))
        let result = try #require(try a.perform(ExpandStrokeCommand([dashed], width: 2))?.createdObjects.first)
        #expect(Objects.localPath(result, in: a.state)?.contours.count == 5)
        let bare = try Self.line(&a, [(0, 50), (100, 50)], appearance: Wiretuner_Doc_V1_AppearanceProps())
        #expect(ExpandStrokeCommand.style([bare], in: a.state).width == 1)
        #expect(ExpandStrokeCommand.style([], in: a.state).width == 1)
        let expanded = try #require(try a.perform(ExpandStrokeCommand([bare], width: 1))?.createdObjects.first)
        #expect(Self.red(expanded, in: a.state) == 0)
        #expect(!ExpandStrokeCommand.canPerform([], in: a.state))
        #expect(try a.perform(ExpandStrokeCommand([], width: 1)) == nil)
    }

    @Test func expandVersusARemoteEditOfTheOriginal() throws {
        var pair = Pair()
        let line = try Self.line(&pair.a, [(0, 0), (100, 0)], appearance: Self.stroked(0, width: 4))
        pair.sync()
        let result = try #require(try pair.a.perform(ExpandStrokeCommand([line], width: 4))?.createdObjects.first)
        try pair.b.perform(MoveObjects([line], by: Vector(dx: 5, dy: 5)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(!pair.a.state.isLive(line) && pair.a.state.isLive(result))
        #expect(Objects.transform(of: line, in: pair.a.state) == .translation(x: 5, y: 5), "the edit is retained on the deleted original")
    }

    // MARK: Inset Path

    static func width(_ node: OpID, in state: EngineState) -> Double {
        Objects.bounds(of: node, in: state)!.width
    }

    @Test func threeUniformStepsMakeAGroupOfThreeSquares() throws {
        var a = Replica(0xA)
        let square = try Fixture.square(&a, x: 0, size: 100, level: 0.4)
        let change = try #require(try a.perform(InsetPathCommand([square], steps: 3, distance: 10)))
        #expect(change.label == "Inset Path")
        let group = try #require(change.createdObjects.first)
        #expect(a.state.nodeKind(group) == .group)
        let paths = a.state.liveChildren(group)
        let widths = paths.map { Self.width($0, in: a.state) }
        #expect(zip(widths, [100 - 20.0 / 3, 100 - 40.0 / 3, 80]).allSatisfy { abs($0 - $1) < 1e-6 }, "\(widths)")
        #expect(paths.allSatisfy { Fixture.level($0, in: a.state) == 0.4 && !a.state.props($0).path.evenOdd })
        #expect(!a.state.isLive(square))
    }

    @Test(arguments: [InsetSpacing.farther, .nearer])
    func spacingCurvesFollowTheirFormulas(_ spacing: InsetSpacing) throws {
        var a = Replica(0xA)
        let square = try Fixture.square(&a, x: 0, size: 100)
        let group = try #require(try a.perform(InsetPathCommand([square], steps: 3, spacing: spacing, distance: 10))?.createdObjects.first)
        let widths = a.state.liveChildren(group).map { Self.width($0, in: a.state) }
        let expected = (1...3).map { k -> Double in
            let fraction = Double(k) / 3
            return 100 - 20 * (spacing == .farther ? fraction.squareRoot() : fraction * fraction)
        }
        #expect(zip(widths, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "\(widths)")
    }

    @Test func aNegativeDistanceGoesOutsideAndACollapseIsReported() throws {
        var a = Replica(0xA)
        let square = try Fixture.square(&a, x: 0, size: 100)
        let outset = try #require(try a.perform(InsetPathCommand([square], distance: -10, join: .miter))?.createdObjects.first)
        #expect(abs(Self.width(outset, in: a.state) - 120) < 1e-6 && a.state.nodeKind(outset) == .path)
        let steps = try #require(try a.perform(InsetPathCommand([outset], steps: 2, distance: -10, keepOriginal: true))?.createdObjects.first)
        #expect(a.state.liveChildren(steps).map { Self.width($0, in: a.state).rounded() } == [140, 130], "outermost first")
        #expect(a.state.isLive(outset))
        let collapse = InsetPathCommand([outset], distance: 70)
        #expect(collapse.collapses(in: a.state))
        #expect(try a.perform(collapse) == nil && a.state.isLive(outset))
        #expect(!InsetPathCommand([outset], distance: 10).collapses(in: a.state))
        let open = try LayerFixture.object(PathFixture.open([(0, 0), (20, 0), (20, 20)]), on: &a)
        #expect(!InsetPathCommand.canPerform([open], in: a.state) && InsetPathCommand.canPerform([outset], in: a.state))
    }

    @Test func aStepInsideATransformedGroupStaysInPlace() throws {
        var a = Replica(0xA)
        let one = try Fixture.square(&a, x: 0, size: 100)
        let two = try Fixture.square(&a, x: 200, size: 100)
        let group = try a.perform(GroupObjects([one, two]))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: AffineTransform.translation(x: 50, y: 50), kind: .scale))
        let steps = try #require(try a.perform(InsetPathCommand([one], steps: 2, distance: 10))?.createdObjects.first)
        #expect(Objects.parent(of: steps, in: a.state) == group)
        let bounds = try #require(Objects.bounds(of: a.state.liveChildren(steps)[0], in: a.state))
        #expect(abs(bounds.minX - 55) < 1e-6 && abs(bounds.width - 90) < 1e-6)
    }

    @Test func insetVersusARemoteEditOfTheOriginal() throws {
        var pair = Pair()
        let square = try Fixture.square(&pair.a, x: 0, size: 100)
        pair.sync()
        let group = try #require(try pair.a.perform(InsetPathCommand([square], steps: 2, distance: 10))?.createdObjects.first)
        try pair.b.perform(MoveObjects([square], by: Vector(dx: 5, dy: 5)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        #expect(!pair.a.state.isLive(square) && pair.a.state.liveChildren(group).count == 2)
        #expect(Objects.transform(of: square, in: pair.a.state) == .translation(x: 5, y: 5))
    }
}

/// PRINT-060: Trap.
@Suite struct TrapCommandTests {
    typealias Fixture = CombineCommandTests

    @Test func aSpreadOfTheLighterFrontColourAlongTheEdgeInsideTheBack() throws {
        var a = Replica(0xA)
        let back = try Fixture.square(&a, x: 0, level: 0.2)
        let front = try Fixture.square(&a, x: 10, level: 0.8)
        #expect(TrapCommand.canPerform([front, back], in: a.state))
        let change = try #require(try a.perform(TrapCommand([front, back], width: 1)))
        #expect(change.label == "Trap")
        let trap = try #require(change.createdObjects.first)
        // [9.5, 20] × [0, 20] less [10.5, 20] × [0.5, 19.5].
        #expect(abs(abs(Fixture.area(trap, in: a.state)) - 29.5) < 0.01)
        let fill = try #require(a.state.props(trap).path.appearance.fills.first?.settings.basic)
        #expect(fill.overprint && abs(fill.color.inline.rgb.r - 0.9) < 1e-9, "the lighter grey at 50%")
        #expect(a.state.props(trap).path.appearance.strokes.isEmpty)
        let layer = try #require(Objects.parent(of: trap, in: a.state))
        #expect(a.state.liveChildren(layer).suffix(2) == [front, trap] && a.state.isLive(back))
    }

    @Test func reverseTakesTheDarkerAndMaximumMixesTheInks() throws {
        let light = Color(white: 0.8), dark = Color(white: 0.2)
        #expect(abs(TrapCommand.color(back: dark, front: light, method: .tintReduction(50), reverse: true).red - 0.6) < 1e-9)
        #expect(abs(TrapCommand.color(back: light, front: dark, method: .tintReduction(100), reverse: false).red - 0.8) < 1e-9, "a choke")
        let cyan = Color(cyan: 1, magenta: 0, yellow: 0, black: 0), magenta = Color(cyan: 0, magenta: 0.6, yellow: 0, black: 0.1)
        let both = TrapCommand.color(back: cyan, front: magenta, method: .maximum, reverse: false)
        #expect(both.space == .cmyk && both.components == SIMD4(1, 0.6, 0, 0.1))
        // Tint reduction keeps a CMYK colour in CMYK, its inks scaled.
        let half = TrapCommand.color(back: cyan, front: magenta, method: .tintReduction(50), reverse: false)
        #expect(half.space == .cmyk)
        #expect(abs(TrapCommand.tinted(dark, percent: .nan).red - 0.2) < 1e-9 && abs(TrapCommand.tinted(dark, percent: 0).red - 1) < 1e-9)
    }

    @Test func nothingWhenTheyDoNotMeetOrTheSelectionIsWrong() throws {
        var a = Replica(0xA)
        let back = try Fixture.square(&a, x: 0)
        let far = try Fixture.square(&a, x: 200)
        let third = try Fixture.square(&a, x: 5)
        #expect(try a.perform(TrapCommand([back, far])) == nil)
        #expect(!TrapCommand.canPerform([back, far, third], in: a.state) && !TrapCommand.canPerform([back], in: a.state))
        #expect(TrapCommand.region([back, third], width: .nan, in: a.state).isEmpty)
        #expect(TrapCommand([back]).width == TrapCommand.defaultWidth)
    }

    @Test func aConcurrentDeleteOfAnInputLeavesTheTrap() throws {
        var pair = Pair()
        let back = try Fixture.square(&pair.a, x: 0, level: 0.2)
        let front = try Fixture.square(&pair.a, x: 10, level: 0.8)
        pair.sync()
        let trap = try #require(try pair.a.perform(TrapCommand([back, front]))?.createdObjects.first)
        try pair.b.perform(CutObjects([front]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(trap) && !pair.a.state.isLive(front))
    }
}
