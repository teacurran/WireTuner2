import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// ATTR-002: the interleaved stack read-out and the attribute commands the Object panel's
/// Attributes list and kind editors perform.
@Suite struct AttributeStackTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)

    static func rows(_ node: OpID, _ state: EngineState) -> [(node: OpID, row: AppearanceRow)] {
        AppearanceEditing.stack(node, in: state).map { (node: node, row: $0) }
    }

    static func summaries(_ node: OpID, _ state: EngineState) -> [String] {
        AppearanceEditing.entries(node, in: state).map(\.summary)
    }

    @Test func theStackInterleavesTheListsByPosition() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        // A fill added with nothing selected goes on top; one added above the stroke sits between.
        try a.perform(AddAppearance.fill([rect]))
        try a.perform(AddAppearance.fill([rect], above: stroke, Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let stack = AppearanceEditing.stack(rect, in: a.state)
        #expect(stack.map(\.list) == [.strokes, .fills, .fills])
        #expect(AppearanceEditing.entries(rect, in: a.state)[1].fill.settings.basic.color == Self.red)
        // The display list paints in the same order.
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        guard case .path(let item)? = scene.displayList.items.first else { Issue.record("no item"); return }
        #expect(item.appearance.items.map { if case .fill = $0 { "fill" } else { "stroke" } } == ["stroke", "fill", "fill"])
        // Aimed at a row of another list, the per-list move still works.
        #expect(AppearanceEditing.stack(OpID(counter: 999, replica: 3), in: a.state).isEmpty)
        #expect(AppearanceEditing.entries(OpID(counter: 999, replica: 3), in: a.state).isEmpty)
    }

    @Test func hideShowAndReorderAcrossLists() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .blur
        try a.perform(AddAppearance.effect([rect], effect))
        let stack = AppearanceEditing.stack(rect, in: a.state)
        #expect(Self.summaries(rect, a.state) == ["Basic, 1 pt", "Basic", "Blur"])

        let hide = try a.perform(SetAppearanceHidden([(rect, stack[0])], hidden: true))!
        #expect(hide.label == "Hide Stroke")
        #expect(AppearanceEditing.entries(rect, in: a.state)[0].hidden)
        #expect(SetAppearanceHidden([(rect, stack[1]), (rect, stack[1])], hidden: false).label == "Show Fill of 2 objects")
        #expect(SetAppearanceHidden([], hidden: false).label == "Show Fill")
        try a.perform(SetAppearanceHidden([(rect, stack[2])], hidden: true))
        try a.perform(SetAppearanceHidden([(rect, stack[1])], hidden: true))
        #expect(AppearanceEditing.entries(rect, in: a.state).allSatisfy { $0.hidden })
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        guard case .path(let item)? = scene.displayList.items.first else { Issue.record("no item"); return }
        #expect(item.appearance.items.isEmpty, "hidden elements are skipped")

        // Reorder: the stroke to the top, above the effect, then the effect to the bottom.
        let reorder = try a.perform(ReorderAttribute([(rect, stack[0])], to: 2))!
        #expect(reorder.label == "Reorder Attributes")
        #expect(AppearanceEditing.stack(rect, in: a.state) == [stack[1], stack[2], stack[0]])
        try a.perform(ReorderAttribute([(rect, stack[2])], to: -4))
        #expect(AppearanceEditing.stack(rect, in: a.state) == [stack[2], stack[1], stack[0]])
        #expect(try a.perform(ReorderAttribute([(rect, stack[0])], to: 99)) == nil, "already on top")
        let missing = AppearanceRow(.fills, OpID(counter: 999, replica: 9))
        #expect(throws: PathEditError.unknownPoint(missing.element)) { try a.perform(ReorderAttribute([(rect, missing)], to: 0)) }
    }

    @Test func duplicateAtAnIndexForOptionDrag() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        let stack = AppearanceEditing.stack(rect, in: a.state)
        try a.perform(DuplicateAppearance(node: rect, row: stack[1], at: 0))
        let after = AppearanceEditing.stack(rect, in: a.state)
        #expect(after.map(\.list) == [.fills, .strokes, .fills] && after[0] != stack[1])
    }

    @Test func editAttributeWritesTheNamedRegistersOfEveryRow() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let rows = [one, two].map { (node: $0, row: AppearanceEditing.stack($0, in: a.state)[0]) }
        let edit = EditAttribute.stroke(rows, "Change cap", [AttributeFields.Basic.cap, AttributeFields.Basic.dash]) {
            $0.basic.cap = .round
            $0.basic.dash.lengths = [4, 2]
        }
        #expect(edit.label == "Change cap of 2 objects")
        try a.perform(edit)
        for node in [one, two] {
            let basic = AppearanceEditing.entries(node, in: a.state)[0].stroke.settings.basic
            #expect(basic.cap == .round && basic.dash.lengths == [4, 2] && basic.width == 1, "other registers are untouched")
        }
        // Clearing a register: a path with no value in the settings.
        try a.perform(EditAttribute.stroke([rows[0]], "Change dash", [AttributeFields.Basic.dash]) { _ in })
        #expect(AppearanceEditing.entries(one, in: a.state)[0].stroke.settings.basic.dash.lengths.isEmpty)
        // A fill edit on a stroke row is refused.
        let wrong = EditAttribute.fill([rows[0]], "Overprint", [AttributeFields.Basic.fillOverprint]) { $0.basic.overprint = true }
        #expect(throws: PathEditError.unknownPoint(rows[0].row.element)) { try a.perform(wrong) }
    }

    @Test func choosingALensTypeClearsTheLensOptions() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        let fill = (node: rect, row: AppearanceEditing.stack(rect, in: a.state)[1])
        try a.perform(SetAttributeKind([fill], fill: .lens))
        try a.perform(EditAttribute.fill([fill], "Objects only", [AttributeFields.Lens.objectsOnly, AttributeFields.Lens.centerpointShown]) {
            $0.lens.objectsOnly = true
            $0.lens.centerpointShown = true
        })
        let change = try a.perform(EditAttribute.lensType([fill], .magnify))!
        #expect(change.label == "Change lens")
        let lens = AppearanceEditing.entries(rect, in: a.state)[1].fill.settings.lens
        #expect(lens.type == .magnify && !lens.objectsOnly && !lens.centerpointShown && !lens.snapshot && lens.amount == 50)
    }

    @Test func kindSwitchingSeedsOnceAndKeepsTheOtherKinds() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let stroke = (node: rect, row: AppearanceEditing.stack(rect, in: a.state)[0])
        let fill = (node: rect, row: AppearanceEditing.stack(rect, in: a.state)[1])
        func entry(_ row: (node: OpID, row: AppearanceRow)) -> AttributeEntry {
            AppearanceEditing.entries(rect, in: a.state).first { $0.row == row.row }!
        }

        // Fills: every kind starts with the current colour.
        let label = SetAttributeKind([fill], fill: .custom).label
        #expect(label == "Change fill type" && SetAttributeKind([fill, fill], stroke: .basic).label == "Change stroke type of 2 objects")
        for kind in [Wiretuner_Doc_V1_FillKind.lens, .custom, .pattern, .textured, .tiled] {
            try a.perform(SetAttributeKind([fill], fill: kind))
            #expect(entry(fill).kind == .fill(kind))
        }
        let settings = entry(fill).fill.settings
        #expect(settings.lens.color == Self.red && settings.lens.amount == 50 && settings.lens.magnification == 2)
        #expect(settings.custom.pattern == .circles && settings.custom.color == Self.red && settings.custom.seed != 0 && settings.custom.count == 100)
        #expect(settings.pattern.color == Self.red && Array(settings.pattern.bitmap.rows) == SetAttributeKind.defaultBitmap)
        #expect(settings.textured.texture == .burlap && settings.textured.color == Self.red)
        #expect(settings.tiled.scaleX == 100 && settings.tiled.scaleY == 100)
        #expect(Self.summaries(rect, a.state)[1] == "Tiled")
        // Back to Basic: the colour is still there; a written kind is not reseeded.
        try a.perform(SetAttributeKind([fill], fill: .basic))
        #expect(entry(fill).fill.settings.basic.color == Self.red)
        try a.perform(EditAttribute.fill([fill], "Change color", [AttributeFields.PatternFill.color]) { $0.pattern.color = Appearances.inline(red: 0, green: 0, blue: 1) })
        try a.perform(SetAttributeKind([fill], fill: .pattern))
        #expect(entry(fill).fill.settings.pattern.color == Appearances.inline(red: 0, green: 0, blue: 1))
        #expect(throws: ObjectEditError.invalidValue("kind")) { try a.perform(SetAttributeKind([fill], fill: .gradient)) }
        #expect(throws: PathEditError.unknownPoint(stroke.row.element)) { try a.perform(SetAttributeKind([stroke], fill: .lens)) }

        // Strokes: the width and colour carry over.
        try a.perform(SetStrokeWidth([(node: rect, element: stroke.row.element)], width: 2))
        for kind in [Wiretuner_Doc_V1_StrokeKind.brush, .calligraphic, .custom, .pattern] {
            try a.perform(SetAttributeKind([stroke], stroke: kind))
            #expect(entry(stroke).kind == .stroke(kind))
            try a.perform(SetAttributeKind([stroke], stroke: .basic))
        }
        let strokeSettings = entry(stroke).stroke.settings
        #expect(strokeSettings.brush.widthPercent == 100 && strokeSettings.brush.seed != 0)
        #expect(strokeSettings.calligraphic.width == 8 && strokeSettings.calligraphic.height == 2 && strokeSettings.calligraphic.angle == 45)
        #expect(strokeSettings.custom.pattern == .arrow && strokeSettings.custom.width == 6)
        #expect(strokeSettings.pattern.width == 4)
        try a.perform(SetAttributeKind([stroke], stroke: .basic))
        #expect(entry(stroke).stroke.settings.basic.width == 2)
        // A stroke that never had Basic settings gets them seeded from its kind.
        try a.perform(AddAppearance.stroke([rect], { var s = Wiretuner_Doc_V1_Stroke(); s.settings.kind = .pattern; s.settings.pattern.width = 5; return s }()))
        let bare = (node: rect, row: AppearanceEditing.stack(rect, in: a.state).last!)
        try a.perform(SetAttributeKind([bare], stroke: .basic))
        #expect(entry(bare).stroke.settings.basic.width == 5)
        #expect(entry(bare).stroke.settings.basic.color == Appearances.inline(red: 0, green: 0, blue: 0), "a colourless kind starts black")
    }

    @Test func colorDropsWriteTheLiveKindsColour() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        let stroke = (node: rect, row: AppearanceEditing.stack(rect, in: a.state)[0])
        let fill = (node: rect, row: AppearanceEditing.stack(rect, in: a.state)[1])
        func color(_ row: (node: OpID, row: AppearanceRow)) -> Wiretuner_Doc_V1_ColorRef? {
            AttributeFields.color(AppearanceEditing.entries(rect, in: a.state).first { $0.row == row.row }!)
        }
        for kind in [Wiretuner_Doc_V1_FillKind.lens, .custom, .pattern, .textured, .basic] {
            try a.perform(SetAttributeKind([fill], fill: kind))
            try a.perform(SetAppearanceColor([fill], color: Self.red))
            #expect(color(fill) == Self.red)
        }
        for kind in [Wiretuner_Doc_V1_StrokeKind.brush, .calligraphic, .custom, .pattern, .basic] {
            try a.perform(SetAttributeKind([stroke], stroke: kind))
            try a.perform(SetAppearanceColor([stroke], color: Self.red))
            #expect(color(stroke) == Self.red)
        }
        try a.perform(SetAttributeKind([fill], fill: .tiled))
        #expect(try a.perform(SetAppearanceColor([fill], color: Self.red)) == nil, "a tiled fill has no colour")
        #expect(color(fill) == nil)
        var custom = AttributeSettings(.fills)
        custom.setColor(Self.red, at: AttributeFields.CustomFill.color2)
        #expect(custom.fill.custom.color2 == Self.red)
    }

    @Test func theDefaultAttributesAreEditedOnTheSettingsNode() throws {
        var a = Replica(0xA)
        #expect(AppearanceEditing.entries(WellKnown.settings, in: a.state).isEmpty)
        try a.perform(AddAppearance.fill([WellKnown.settings]))
        try a.perform(AddAppearance.stroke([WellKnown.settings]))
        let stack = AppearanceEditing.stack(WellKnown.settings, in: a.state)
        #expect(stack.map(\.list) == [.fills, .strokes])
        #expect(a.state.props(WellKnown.settings).settings.defaults.appearance.fills.count == 1)
        try a.perform(SetStrokeWidth([(node: WellKnown.settings, element: stack[1].element)], width: 3))
        try a.perform(SetAppearanceHidden([(WellKnown.settings, stack[0])], hidden: true))
        try a.perform(ReorderAttribute([(WellKnown.settings, stack[0])], to: 1))
        try a.perform(DuplicateAppearance(node: WellKnown.settings, row: stack[1]))
        try a.perform(RemoveAppearance(node: WellKnown.settings, row: stack[0]))
        #expect(Self.summaries(WellKnown.settings, a.state) == ["Basic, 3 pt", "Basic, 3 pt"])
        #expect(AppearanceEditing.rows(WellKnown.settings, .strokes, in: a.state).count == 2)
    }

    @Test func summariesNameEveryKind() {
        func fill(_ build: (inout Wiretuner_Doc_V1_FillSettings) -> Void) -> String {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            var fill = Wiretuner_Doc_V1_Fill()
            fill.id = OpID(counter: 1, replica: 1).elementID
            build(&fill.settings)
            appearance.fills = [fill]
            return AttributeEntry.read(AppearanceRow(.fills, OpID(counter: 1, replica: 1)), in: appearance).summary
        }
        func stroke(_ build: (inout Wiretuner_Doc_V1_StrokeSettings) -> Void) -> String {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            var stroke = Wiretuner_Doc_V1_Stroke()
            stroke.id = OpID(counter: 1, replica: 1).elementID
            build(&stroke.settings)
            appearance.strokes = [stroke]
            return AttributeEntry.read(AppearanceRow(.strokes, OpID(counter: 1, replica: 1)), in: appearance).summary
        }
        #expect(fill { $0.kind = .gradient; $0.gradient.type = .radial } == "Gradient, Radial")
        #expect(fill { $0.kind = .lens; $0.lens.type = .invert } == "Lens, Invert")
        #expect(fill { $0.kind = .custom; $0.custom.pattern = .bricks } == "Custom, Bricks")
        #expect(fill { $0.kind = .textured; $0.textured.texture = .oak } == "Textured, Oak")
        #expect(fill { $0.kind = .pattern } == "Pattern")
        #expect(fill { $0.kind = .init(rawValue: 99)! } == "Basic", "an unknown kind reads as Basic")
        #expect(stroke { $0.kind = .brush; $0.brush.widthPercent = 150 } == "Brush, 150%")
        #expect(stroke { $0.kind = .custom; $0.custom.pattern = .neon } == "Custom, Neon")
        #expect(stroke { $0.kind = .calligraphic; $0.calligraphic.width = 6; $0.calligraphic.height = 2 } == "Calligraphic, 6 pt")
        #expect(stroke { $0.kind = .pattern; $0.pattern.width = 0 } == "Pattern, Hairline")
        #expect(AttributeNames.effectKind(.unspecified) == "Effect")
        #expect(AttributeNames.fillKind(.tiled) == "Tiled" && AttributeNames.strokeKind(.unspecified) == "Basic")
        var effect = AttributeEntry.read(AppearanceRow(.effects, OpID(counter: 1, replica: 1)), in: Wiretuner_Doc_V1_AppearanceProps())
        #expect(AttributeFields.width(effect) == nil && AttributeFields.colorPath(effect) == nil)
        effect.kind = .fill(.basic)
        #expect(AttributeFields.width(effect) == nil)
    }
}

/// ATTR-002 and ATTR-006 merge behaviour.
@Suite struct AttributeMergeTests {
    @Test func reorderEditAndRemoveOnThreeReplicasConverge() throws {
        var a = Replica(0xA)
        var b = Replica(0xB)
        var c = Replica(0xC)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        b.receive(a.sent)
        c.receive(a.sent)
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        let before = (a.sent.count, b.sent.count, c.sent.count)
        try a.perform(ReorderAttribute([(rect, stroke)], to: 1))
        try b.perform(EditAttribute.stroke([(rect, stroke)], "Change cap", [AttributeFields.Basic.cap]) { $0.basic.cap = .round })
        try c.perform(RemoveAppearance(node: rect, row: stroke))
        let fromA = Array(a.sent[before.0...]), fromB = Array(b.sent[before.1...]), fromC = Array(c.sent[before.2...])
        a.receive(fromB + fromC)
        b.receive(fromA + fromC)
        c.receive(fromA + fromB)
        #expect(a.state.stateHash == b.state.stateHash && b.state.stateHash == c.state.stateHash)
        #expect(AppearanceEditing.stack(rect, in: a.state).map(\.list) == [.fills])
        let cap = RegisterPath([NodeKind.rect.rawValue, 4, 2]).element(stroke.element).appending([3, 2, 3])
        #expect(a.state.store.register(rect, cap)?.value != nil, "the tombstone carries B's edit")
    }

    @Test func undoOfAReorderLeavesARemoteReorderAlone() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        try pair.a.perform(AddAppearance.fill([rect]))
        try pair.a.perform(AddAppearance.fill([rect]))
        pair.sync()
        let stack = AppearanceEditing.stack(rect, in: pair.a.state)
        try pair.a.perform(ReorderAttribute([(rect, stack[0])], to: 2))
        pair.sync()
        try pair.b.perform(ReorderAttribute([(rect, stack[2])], to: 0))
        pair.sync()
        pair.a.undo()
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let after = AppearanceEditing.stack(rect, in: pair.a.state)
        #expect(after.firstIndex(of: stack[2])! < after.firstIndex(of: stack[1])!, "B's move stays")
        #expect(after.last != stack[0], "A's move is undone")
    }

    @Test func concurrentWidthAndDashEditsBothApply() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        let stroke = AppearanceEditing.stack(rect, in: pair.a.state)[0]
        try pair.a.perform(SetStrokeWidth([(node: rect, element: stroke.element)], width: 6))
        try pair.b.perform(EditAttribute.stroke([(rect, stroke)], "Change dash", [AttributeFields.Basic.dash]) {
            $0.basic.dash.name = "Long"
            $0.basic.dash.lengths = [8, 4]
        })
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let basic = AppearanceEditing.entries(rect, in: pair.b.state)[0].stroke.settings.basic
        #expect(basic.width == 6 && basic.dash.lengths == [8, 4])
    }
}

/// Lowering every kind to the display list (the stroke and fill pages' read-time normalizations).
@Suite struct AttributeLoweringTests {
    static func strokePaint(_ build: (inout Wiretuner_Doc_V1_StrokeSettings) -> Void) -> StrokePaint {
        var settings = Wiretuner_Doc_V1_StrokeSettings()
        build(&settings)
        return Appearances.stroke(settings)
    }

    static func fillPaint(_ build: (inout Wiretuner_Doc_V1_FillSettings) -> Void) -> FillPaint {
        var settings = Wiretuner_Doc_V1_FillSettings()
        build(&settings)
        return Appearances.fill(settings, evenOdd: false)
    }

    static let square: Wiretuner_Doc_V1_Contour = {
        var path = Wiretuner_Doc_V1_PathProps()
        path.contours = [Subtrees.proto(VectorContour(closed: true, points: PathFixture.points([(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)])))]
        return path.contours[0]
    }()

    @Test func basicStrokesClampAndCarryDashesAndArrowheads() {
        let basic = Self.strokePaint {
            $0.basic.width = 20_000
            $0.basic.miterLimit = 90
            $0.basic.dash.lengths = [3]
            $0.basic.endArrowhead.contours = [Self.square]
            $0.basic.endArrowhead.filled = true
            $0.basic.endArrowhead.pathTrim = .nan
            $0.basic.startArrowhead.contours = [Wiretuner_Doc_V1_Contour()]
        }
        #expect(basic.style.width == 16_164 && basic.style.miterLimit == 57 && basic.style.dash == [3, 3])
        #expect(basic.endArrowhead?.filled == true && basic.endArrowhead?.pathTrim == 0 && basic.startArrowhead == nil)
        #expect(Self.strokePaint { $0.basic.dash.lengths = [0, 0]; $0.basic.miterLimit = 0.5 }.style.dash.isEmpty)
        #expect(Self.strokePaint { $0.basic.miterLimit = 0.5 }.style.miterLimit == 1)
        #expect(Self.strokePaint { $0.basic.width = .nan }.style.width == 1)
    }

    @Test func everyStrokeKindLowers() throws {
        var cached = Wiretuner_Doc_V1_BasicStroke()
        cached.width = 3
        cached.color = AttributeStackTests.red
        let brush = Self.strokePaint {
            $0.kind = .brush
            $0.brush.brush.cached = try! cached.serializedData()
            $0.brush.widthPercent = 50
            $0.brush.seed = 7
        }
        #expect(brush.style.width == 3 && brush.paint == .solid(Color(red: 1, green: 0, blue: 0)))
        #expect(brush.kind == .brush(BrushStroke(brush: nil, widthPercent: 50, seed: 7)))
        let calligraphic = Self.strokePaint {
            $0.kind = .calligraphic
            $0.calligraphic.width = 8
            $0.calligraphic.height = 2
            $0.calligraphic.angle = .infinity
            $0.calligraphic.nib = [Self.square]
        }
        guard case .calligraphic(let nib) = calligraphic.kind else { Issue.record("nib"); return }
        #expect(nib.width == 8 && nib.height == 2 && nib.angle == 0 && nib.shape != nil && calligraphic.style.width == 8)
        var open = Self.square
        open.closed = false
        #expect(Self.strokePaint { $0.kind = .calligraphic; $0.calligraphic.nib = [open] }.kind == .calligraphic(CalligraphicNib(width: 0, height: 0)))
        let custom = Self.strokePaint { $0.kind = .custom; $0.custom.pattern = .star; $0.custom.width = 5; $0.custom.length = -1 }
        #expect(custom.kind == .custom(CustomStroke(pattern: .star)) && custom.style.width == 5)
        let unknown = Self.strokePaint { $0.kind = .custom; $0.custom.pattern = .init(rawValue: 99)!; $0.custom.width = 5 }
        #expect(unknown.kind == .basic && unknown.style.width == 5, "an unknown pattern draws a Basic stroke of the same width")
        let pattern = Self.strokePaint { $0.kind = .pattern; $0.pattern.width = 4; $0.pattern.bitmap.rows = Data(PatternBitmap.checker.rows) }
        #expect(pattern.paint == .pattern(PatternPaint(bitmap: .checker, color: .black)) && pattern.style.width == 4)
        #expect(Self.strokePaint { $0.kind = .pattern; $0.pattern.color.none = true }.paint == .none)
    }

    @Test func everyFillKindLowers() throws {
        let gradient = Self.fillPaint {
            $0.kind = .gradient
            $0.gradient.type = .radial
            $0.gradient.behavior = .reflect
            $0.gradient.repeatCount = 3
            $0.gradient.axis.end.x = 10
            $0.gradient.axis.end2.y = 5
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.offset = 2
            stop.color = AttributeStackTests.red
            $0.gradient.stops = [stop]
        }
        guard case .gradient(let ramp) = gradient.paint else { Issue.record("gradient"); return }
        #expect(ramp.kind == .radial && ramp.behavior == .reflect && ramp.repeatCount == 3 && ramp.axis?.end2 == Point(x: 0, y: 5))
        #expect(ramp.stops == [Gradient.Stop(offset: 1, color: Color(red: 1, green: 0, blue: 0))])
        guard case .gradient(let plain) = Self.fillPaint({ $0.kind = .gradient }).paint else { return }
        #expect(plain.kind == .linear && plain.axis == nil)

        let lens = Self.fillPaint {
            $0.kind = .lens
            $0.lens.type = .magnify
            $0.lens.magnification = 0.2
            $0.lens.centerpoint.x = 3
            $0.lens.objectsOnly = true
            $0.lens.snapshot = true
        }
        #expect(lens.paint == .lens(LensFill(type: .magnify, amount: 0, magnification: 1, centerpoint: Point(x: 3, y: 0), objectsOnly: true)))
        let unknownLens = Self.fillPaint { $0.kind = .lens; $0.lens.type = .init(rawValue: 42)!; $0.lens.color = AttributeStackTests.red }
        #expect(unknownLens.paint == .solid(Color(red: 1, green: 0, blue: 0)))

        let custom = Self.fillPaint { $0.kind = .custom; $0.custom.pattern = .hatch; $0.custom.whiteness = 150; $0.custom.count = 9 }
        #expect(custom.paint == .custom(CustomFill(pattern: .hatch, color2: .black, whiteness: 100, count: 9)), "unset colours read black")
        #expect(Self.fillPaint { $0.kind = .custom; $0.custom.pattern = .init(rawValue: 77)! }.paint == .solid(.black))
        #expect(Self.fillPaint { $0.kind = .pattern; $0.pattern.color.none = true }.paint == .none)
        let textured = Self.fillPaint { $0.kind = .textured; $0.textured.texture = .marble }
        #expect(textured.paint == .textured(TexturedFill(texture: .marble, color: .black)))
        #expect(Self.fillPaint { $0.kind = .textured; $0.textured.texture = .init(rawValue: 55)! }.paint == .solid(.black))
        #expect(Self.fillPaint { $0.kind = .textured; $0.textured.texture = .oak; $0.textured.color.none = true }.paint == .none)
        let tiled = Self.fillPaint { $0.kind = .tiled; $0.tiled.angle = 30; $0.tiled.offset.x = 2 }
        #expect(tiled.paint.isNone, "a tiled fill without a tile paints nothing")
    }

    @Test func orderedResolutionSkipsEffectsAndUnknownRows() {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        let fillID = OpID(counter: 1, replica: 1), strokeID = OpID(counter: 2, replica: 1)
        var fill = Appearances.basicFill(red: 1, green: 0, blue: 0)
        fill.id = fillID.elementID
        var stroke = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)
        stroke.id = strokeID.elementID
        appearance.fills = [fill]
        appearance.strokes = [stroke]
        let order = [AppearanceRow(.strokes, strokeID), AppearanceRow(.effects, fillID), AppearanceRow(.fills, fillID),
                     AppearanceRow(.fills, OpID(counter: 9, replica: 9))]
        let resolved = Appearances.resolve(appearance, order: order)
        #expect(resolved.items.count == 2)
        guard case .stroke = resolved.items[0], case .fill = resolved.items[1] else { Issue.record("order"); return }
        #expect(Appearances.resolve(appearance, order: order, paintsFill: false).items.count == 1)
    }
}

/// Tiles and nibs through the pasteboard (ATTR-017's Paste In and Copy Out, ATTR-015's nib).
@Suite struct SubtreeTests {
    static func payload(_ commands: [any Command]) throws -> (ClipboardPayload, Replica) {
        var a = Replica(0xA)
        var nodes: [OpID] = []
        for command in commands { nodes.append(try LayerFixture.object(command, on: &a)) }
        return (ClipboardPayload(copying: nodes, from: a.state), a)
    }

    @Test func aTileCapturesAndRendersTheCopiedArtwork() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil, x: 50), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil, x: 70), on: &a)
        try a.perform(GroupObjects([one, two]))
        let group = Objects.parent(of: one, in: a.state)!
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 4, height: 4), transform: .translation(x: 50, y: 0)), on: &a)
        let payload = ClipboardPayload(copying: [group, ellipse], from: a.state)
        let tile = try Subtrees.tile(from: payload)
        #expect(tile.nodes.map(\.parent) == [-1, 0, 0, -1])
        let items = SubtreeRendering.items(tile)
        #expect(items.count == 2)
        #expect(items.compactMap(\.bounds).map(\.minX).min().map { $0 < 1 } == true, "the tile starts at the origin")
        let back = try #require(Subtrees.payload(from: tile))
        #expect(back.nodes.count == 2 && back.nodes[0].children.count == 2 && back.bounds != nil)
        #expect(Subtrees.payload(from: Wiretuner_Doc_V1_Subtree()) == nil)
        // A tiled fill paints its tile.
        var fill = Wiretuner_Doc_V1_FillSettings()
        fill.kind = .tiled
        fill.tiled.tile = tile
        #expect(!Appearances.fill(fill, evenOdd: false).paint.isNone)
        // A lens snapshot renders from its contents.
        var lens = Wiretuner_Doc_V1_FillSettings()
        lens.kind = .lens
        lens.lens.snapshot = true
        lens.lens.snapshotContents = tile
        guard case .lens(let value) = Appearances.fill(lens, evenOdd: false).paint else { Issue.record("lens"); return }
        #expect(value.snapshot?.count == 2)
    }

    @Test func malformedSubtreesRenderTheirWellFormedPrefix() throws {
        var subtree = Wiretuner_Doc_V1_Subtree()
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.size.width = 5
        props.rect.size.height = 5
        props.rect.appearance = Appearances.standard
        var root = Wiretuner_Doc_V1_SubtreeNode()
        root.parent = -1
        root.props = try props.serializedData()
        var cycle = root
        cycle.parent = 5
        subtree.nodes = [root, cycle, root]
        #expect(SubtreeRendering.items(subtree).count == 1)
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.common.name = "Empty"
        var empty = root
        empty.props = try group.serializedData()
        var bad = root
        bad.props = Data([0xFF])
        var open = Wiretuner_Doc_V1_NodeProps()
        open.path.contours = [Subtrees.proto(VectorContour(points: PathFixture.points([(0, 0), (4, 4)])))]
        open.path.appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        var line = root
        line.props = try open.serializedData()
        subtree.nodes = [empty, line, bad, root]
        let items = SubtreeRendering.items(subtree)
        #expect(items.count == 1, "the empty group draws nothing; the bad node ends the prefix")
        guard case .path(let item)? = items.first else { Issue.record("line"); return }
        #expect(item.appearance.fills.isEmpty, "an open path does not show its fill")
        var text = Wiretuner_Doc_V1_NodeProps()
        text.text.common.name = "Text"
        var textNode = root
        textNode.props = try text.serializedData()
        subtree.nodes = [textNode]
        #expect(SubtreeRendering.items(subtree).isEmpty)
    }

    @Test func tilesRefuseExcludedArtwork() throws {
        #expect(throws: PasteInError.empty) { try Subtrees.tile(from: ClipboardPayload(nodes: [])) }
        var lensed = Wiretuner_Doc_V1_NodeProps()
        var lens = Wiretuner_Doc_V1_Fill()
        lens.settings.kind = .lens
        lensed.rect.appearance.fills = [lens]
        #expect(throws: PasteInError.excluded) { try Subtrees.tile(from: ClipboardPayload(nodes: [NodeTree(props: lensed)])) }
        var text = Wiretuner_Doc_V1_NodeProps()
        text.text.common.name = "Text"
        #expect(throws: PasteInError.excluded) { try Subtrees.tile(from: ClipboardPayload(nodes: [NodeTree(props: text)])) }
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.common.name = "Big"
        let many = NodeTree(props: group, children: Array(repeating: NodeTree(props: group), count: Subtrees.maximumNodes))
        #expect(throws: PasteInError.tooLarge) { try Subtrees.tile(from: ClipboardPayload(nodes: [many])) }
        var huge = Wiretuner_Doc_V1_NodeProps()
        huge.rect.common.note = String(repeating: "x", count: Subtrees.maximumNodeBytes)
        #expect(throws: PasteInError.tooLarge) { try Subtrees.tile(from: ClipboardPayload(nodes: [NodeTree(props: huge)])) }
        #expect(PasteInError.empty.message.contains("Copy") && PasteInError.excluded.message.contains("tile")
                && PasteInError.notOneClosedPath.message.contains("closed") && PasteInError.tooLarge.message.contains("too much"))
    }

    @Test func aNibComesFromOneClosedPath() throws {
        let (square, _) = try Self.payload([PathFixture.closed([(10, 10), (30, 10), (30, 20), (10, 20)])])
        let nib = try Subtrees.nib(from: square)
        let bounds = VectorPath(VectorPath.props(nib)).controlBounds!
        #expect(bounds == Rect(x: -0.5, y: -0.5, width: 1, height: 1))
        let (ellipse, _) = try Self.payload([CreateShape(.ellipse, size: Size(width: 8, height: 2))])
        #expect(try Subtrees.nib(from: ellipse)[0].points.count == 4)
        let (polygon, _) = try Self.payload([CreatePolygon(PolygonShape(sides: 5, radius: 4), center: Point(x: 10, y: 10))])
        #expect(try Subtrees.nib(from: polygon)[0].closed)
        let (rect, _) = try Self.payload([LayerFixture.rect(on: nil)])
        #expect(try Subtrees.nib(from: rect)[0].points.count == 4)
        #expect(throws: PasteInError.empty) { try Subtrees.nib(from: ClipboardPayload(nodes: [])) }
        let (open, _) = try Self.payload([PathFixture.open([(0, 0), (4, 4)])])
        #expect(throws: PasteInError.notOneClosedPath) { try Subtrees.nib(from: open) }
        let (two, _) = try Self.payload([LayerFixture.rect(on: nil), LayerFixture.rect(on: nil, x: 20)])
        #expect(throws: PasteInError.notOneClosedPath) { try Subtrees.nib(from: two) }
        let (flat, _) = try Self.payload([PathFixture.closed([(0, 0), (4, 0), (8, 0)])])
        #expect(throws: PasteInError.notOneClosedPath) { try Subtrees.nib(from: flat) }
        var text = Wiretuner_Doc_V1_NodeProps()
        text.text.common.name = "T"
        #expect(throws: PasteInError.notOneClosedPath) { try Subtrees.nib(from: ClipboardPayload(nodes: [NodeTree(props: text)])) }

        // Copy Out: the nib at its size and angle, or the ellipse.
        let out = Subtrees.nibPayload(nib, width: 10, height: 4, angle: 90)
        #expect(out.nodes.count == 1 && out.bounds.map { abs($0.width - 4) < 1e-9 && abs($0.height - 10) < 1e-9 } == true)
        let ellipseOut = Subtrees.nibPayload([], width: 6, height: 2, angle: .nan)
        #expect(ellipseOut.bounds.map { abs($0.width - 6) < 1e-6 && abs($0.height - 2) < 1e-6 } == true)
        #expect(try Subtrees.nib(from: out)[0].points.count == 4, "a copied-out nib pastes back in")
    }
}

extension VectorPath {
    /// Path props holding `contours`.
    static func props(_ contours: [Wiretuner_Doc_V1_Contour]) -> Wiretuner_Doc_V1_PathProps {
        var props = Wiretuner_Doc_V1_PathProps()
        props.contours = contours
        return props
    }
}

/// Built-in arrowheads copied into strokes (ATTR-006).
@Suite struct InlineShapeTests {
    @Test func displayPathsBecomeStoredContours() {
        var path = DisplayPath()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: 4, y: 0))
        path.addQuadCurve(control: Point(x: 4, y: 4), to: Point(x: 0, y: 4))
        path.addCubicCurve(control1: Point(x: -1, y: 3), control2: Point(x: -1, y: 1), to: Point(x: 0, y: 0))
        path.close()
        path.move(to: Point(x: 10, y: 10))
        path.addLine(to: Point(x: 12, y: 10))
        let contours = InlineShapes.contours(path)
        #expect(contours.count == 2 && contours[0].closed && !contours[1].closed)
        #expect(contours[0].points.count == 3, "the closing point merges into the first")
        #expect(contours[0].points[0].hasInHandle && contours[0].points[1].hasOutHandle)
        #expect(Appearances.display(contours).elements.count > 4)
        for head in Arrowhead.builtIns {
            let stored = InlineShapes.arrowhead(head)
            #expect(stored.name == head.name && stored.filled == head.filled && stored.pathTrim == head.pathTrim)
            #expect(Appearances.arrowhead(stored)?.name == head.name)
        }
        var empty = DisplayPath()
        empty.close()
        #expect(InlineShapes.contours(empty).isEmpty)
    }
}

/// The names and fallbacks of the read-out and the lowering.
@Suite struct AttributeNameTests {
    @Test func everyKindHasAName() {
        let fills: [Wiretuner_Doc_V1_FillKind] = [.basic, .gradient, .lens, .custom, .pattern, .textured, .tiled, .unspecified]
        #expect(fills.map(AttributeNames.fillKind) == ["Basic", "Gradient", "Lens", "Custom", "Pattern", "Textured", "Tiled", "Basic"])
        let strokes: [Wiretuner_Doc_V1_StrokeKind] = [.basic, .brush, .calligraphic, .custom, .pattern, .init(rawValue: 42)!]
        #expect(strokes.map(AttributeNames.strokeKind) == ["Basic", "Brush", "Calligraphic", "Custom", "Pattern", "Basic"])
        #expect(AttributeKind.stroke(normalizing: .unspecified) == .stroke(.basic) && AttributeKind.fill(normalizing: .lens) == .fill(.lens))
        #expect(AttributeNames.name(7, in: [(1, "One")], default: "Other") == "Other")
        #expect(AttributeNames.effectKind(.blur) == "Blur")
    }

    @Test func loweringFallsBackForMissingValues() throws {
        // Elements without ids paint in stored order when no stack order is given.
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        #expect(Appearances.resolve(appearance, order: []).items.isEmpty)
        // Colours with None read as the kind's fallback colour.
        var custom = Wiretuner_Doc_V1_FillSettings()
        custom.kind = .custom
        custom.custom.pattern = .bricks
        custom.custom.color.none = true
        custom.custom.color2.none = true
        #expect(Appearances.fill(custom, evenOdd: false).paint == .custom(CustomFill(pattern: .bricks, color: .black, color2: .white, whiteness: 0)))
        var lens = Wiretuner_Doc_V1_FillSettings()
        lens.kind = .lens
        lens.lens.color.none = true
        guard case .lens(let value) = Appearances.fill(lens, evenOdd: false).paint else { Issue.record("lens"); return }
        #expect(value.color == .black)
        var gradient = Wiretuner_Doc_V1_FillSettings()
        gradient.kind = .gradient
        gradient.gradient.axis.end.x = 5
        var stop = Wiretuner_Doc_V1_GradientStop()
        stop.color.none = true
        gradient.gradient.stops = [stop]
        guard case .gradient(let ramp) = Appearances.fill(gradient, evenOdd: false).paint else { Issue.record("gradient"); return }
        #expect(ramp.axis?.end2 == nil && ramp.stops[0].color == .clear)
        var dashed = Wiretuner_Doc_V1_StrokeSettings()
        dashed.basic.dash.lengths = [.nan, 2]
        dashed.basic.endArrowhead.contours = [AttributeLoweringTests.square]
        dashed.basic.endArrowhead.pathTrim = 0.5
        let stroke = Appearances.stroke(dashed)
        #expect(stroke.style.dash == [0, 2] && stroke.endArrowhead?.pathTrim == 0.5)
        var tint = Wiretuner_Doc_V1_ColorRef()
        tint.tint.percent = 100
        #expect(Appearances.color(tint) == Color(red: 0, green: 0, blue: 0))
    }
}
