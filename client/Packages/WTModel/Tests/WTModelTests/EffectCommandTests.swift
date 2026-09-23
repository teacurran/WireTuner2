import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-002: the effect stack commands, the effect read-out and the lowering of effects into the
/// display list.
@Suite struct EffectCommandTests {
    static func effects(_ node: OpID, _ state: EngineState) -> [EffectEntry] {
        EffectReading.entries(node, in: state)
    }

    static func item(_ state: EngineState, _ node: OpID) -> DisplayItem? {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state).object(node)?.item
    }

    @Test func addEffectWritesTheKindsDefaultsAtTheChosenLevel() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        let change = try a.perform(AddEffect([rect], kind: .bend))!
        #expect(change.label == "Add Bend effect")
        try a.perform(AddEffect([rect], kind: .ragged, attachTo: [rect: stroke]))
        try a.perform(AddEffect([rect], kind: .blur, attachTo: [rect: stroke]))
        let entries = Self.effects(rect, a.state)
        #expect(entries.map(\.kind) == [.ragged, .blur, .bend], "attached effects sit directly above their element, the object's on top")
        #expect(entries[0].attachment == .element(stroke) && entries[2].attachment == .object)
        #expect(entries[2].effect.settings.bend.size == 20 && entries[0].effect.settings.ragged.seed != 0)
        #expect(AppearanceEditing.stack(rect, in: a.state).map(\.list) == [.strokes, .effects, .effects, .effects])
        // Above a chosen row at the object level.
        try a.perform(AddEffect([rect], kind: .shadow, above: [rect: stroke]))
        #expect(AppearanceEditing.stack(rect, in: a.state)[1].list == .effects && Self.effects(rect, a.state)[0].kind == .shadow)
        // Every kind has defaults and a name.
        for (kind, name) in AttributeNames.effectKinds {
            let settings = EffectDefaults.settings(kind, seed: 7)
            #expect(settings.kind == kind && !EffectDefaults.isEmpty(settings, kind), "\(name)")
            #expect(AddEffect([rect], kind: kind).label == "Add \(name) effect")
        }
        #expect(EffectDefaults.isEmpty(EffectDefaults.settings(.unspecified, seed: 1), .unspecified))
        #expect(throws: ObjectEditError.invalidValue("kind")) { try a.perform(AddEffect([rect], kind: .unspecified)) }
        let effect = AppearanceEditing.stack(rect, in: a.state).first { $0.list == .effects }!
        #expect(throws: PathEditError.unknownPoint(effect.element)) { try a.perform(AddEffect([rect], kind: .bend, attachTo: [rect: effect])) }
    }

    @Test func removeReorderAndHide() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        let fill = AppearanceEditing.stack(rect, in: a.state)[1]
        try a.perform(AddEffect([rect], kind: .bend))
        try a.perform(AddEffect([rect], kind: .sketch))
        try a.perform(AddEffect([rect], kind: .blur, attachTo: [rect: stroke]))
        var entries = Self.effects(rect, a.state)
        let (blur, bend, sketch) = (entries[0].row, entries[1].row, entries[2].row)
        #expect(entries.map(\.kind) == [.blur, .bend, .sketch])

        // Within the object level.
        let reorder = try a.perform(ReorderEffect(node: rect, row: sketch, to: 0))!
        #expect(reorder.label == "Reorder effects")
        #expect(EffectReading.group(rect, target: nil, in: a.state).map(\.row) == [sketch, bend])
        #expect(try a.perform(ReorderEffect(node: rect, row: sketch, to: 0)) == nil, "already there")
        // Onto the fill: attached, directly above it.
        try a.perform(ReorderEffect(node: rect, row: bend, to: 5, attachTo: fill))
        entries = Self.effects(rect, a.state)
        #expect(entries.first { $0.row == bend }?.attachment == .element(fill))
        let stack = AppearanceEditing.stack(rect, in: a.state)
        #expect(stack.firstIndex(of: bend) == stack.firstIndex(of: fill)! + 1)
        // Into the stroke's group ahead of the blur, then back to the object level at the end.
        try a.perform(ReorderEffect(node: rect, row: sketch, to: 0, attachTo: stroke))
        #expect(EffectReading.group(rect, target: stroke, in: a.state).map(\.row) == [sketch, blur])
        try a.perform(ReorderEffect(node: rect, row: sketch, to: 9))
        #expect(EffectReading.group(rect, target: nil, in: a.state).map(\.row) == [sketch])
        #expect(AppearanceEditing.stack(rect, in: a.state).last == sketch)
        // The object level empty: the top of the stack.
        try a.perform(ReorderEffect(node: rect, row: bend, to: 0))
        try a.perform(ReorderEffect(node: rect, row: sketch, to: 0, attachTo: fill))
        try a.perform(ReorderEffect(node: rect, row: bend, to: 0, attachTo: fill))
        try a.perform(ReorderEffect(node: rect, row: bend, to: 0))
        #expect(AppearanceEditing.stack(rect, in: a.state).last == bend)
        #expect(throws: PathEditError.unknownPoint(bend.element)) { try a.perform(ReorderEffect(node: rect, row: sketch, to: 0, attachTo: bend)) }
        #expect(throws: PathEditError.unknownPoint(fill.element)) { try a.perform(ReorderEffect(node: rect, row: fill, to: 0)) }

        // Hide and remove; undo restores.
        try a.perform(SetAppearanceHidden([(rect, blur)], hidden: true))
        #expect(Self.effects(rect, a.state)[0].effect.hidden)
        let remove = try a.perform(RemoveEffect([(rect, blur)]))!
        #expect(remove.label == "Remove effect" && !Self.effects(rect, a.state).contains { $0.row == blur })
        a.undo()
        #expect(Self.effects(rect, a.state).contains { $0.row == blur })
    }

    @Test func kindChangeSeedsOnceAndKeepsTheOtherKinds() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddEffect([rect], kind: .bend))
        let row = Self.effects(rect, a.state)[0].row
        try a.perform(EditEffect([(rect, row)], label: "Change size", fields: [EffectFields.field(.bend, 1)]) { $0.bend.size = -12 })
        let change = try a.perform(SetEffectKind([(rect, row)], kind: .ragged))!
        #expect(change.label == "Change effect to Ragged")
        var entry = Self.effects(rect, a.state)[0]
        #expect(entry.kind == .ragged && entry.effect.settings.ragged.size == 4 && entry.effect.settings.bend.size == -12)
        try a.perform(SetEffectKind([(rect, row)], kind: .bend))
        entry = Self.effects(rect, a.state)[0]
        #expect(entry.kind == .bend && entry.effect.settings.bend.size == -12, "switching back finds the old settings")
        #expect(throws: ObjectEditError.invalidValue("kind")) { try a.perform(SetEffectKind([(rect, row)], kind: .unspecified)) }
    }

    @Test func editReseedAndCornerPoints() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil, x: 20), on: &a)
        try a.perform(AddEffect([one, two], kind: .ragged))
        let rows = [one, two].map { (node: $0, row: Self.effects($0, a.state)[0].row) }
        let edit = EditEffect(rows, label: "Change size", fields: [EffectFields.field(.ragged, 1)]) { $0.ragged.size = 9 }
        #expect(edit.label == "Change size of 2 objects")
        try a.perform(edit)
        #expect(rows.allSatisfy { Self.effects($0.node, a.state)[0].effect.settings.ragged.size == 9 })
        let before = Self.effects(one, a.state)[0].effect.settings.ragged.seed
        let reseed = try a.perform(ReseedEffect(rows))!
        #expect(reseed.label == "Reseed of 2 objects")
        let seeds = rows.map { Self.effects($0.node, a.state)[0].effect.settings.ragged.seed }
        #expect(seeds[0] != before && seeds[0] != seeds[1] && !seeds.contains(0))
        #expect(EffectFields.seed(.sketch) == [14, 4] && EffectFields.color(.shadow) == [22, 2] && EffectFields.color(.bevelEmboss) == [20, 2])
        #expect(EffectFields.seed(.bend) == nil && EffectFields.color(.bend) == nil)

        // Sketch reseeds too; kinds without a seed are left alone.
        try a.perform(SetEffectKind([rows[0]], kind: .sketch))
        let sketchSeed = Self.effects(one, a.state)[0].effect.settings.sketch.seed
        try a.perform(ReseedEffect([rows[0]]))
        #expect(Self.effects(one, a.state)[0].effect.settings.sketch.seed != sketchSeed)
        try a.perform(SetEffectKind([rows[0]], kind: .bend))
        #expect(try a.perform(ReseedEffect([rows[0]])) == nil)

        // Corners: points are a SET, never written by EditEffect.
        try a.perform(SetEffectKind([rows[1]], kind: .corners))
        let points = [OpID(counter: 5, replica: 9), OpID(counter: 6, replica: 9)]
        let add = try a.perform(SetCornerPoints([rows[1]], points: points, adding: true))!
        #expect(add.label == "Change corners")
        #expect(Self.effects(two, a.state)[0].effect.settings.corners.points.count == 2)
        try a.perform(SetCornerPoints([rows[1]], points: [points[0]], adding: false))
        #expect(Self.effects(two, a.state)[0].effect.settings.corners.points.map { OpID(element: $0) } == [points[1]])
        #expect(try a.perform(SetCornerPoints([rows[1]], points: [], adding: true)) == nil)
        #expect(throws: ObjectEditError.invalidValue("points")) {
            try a.perform(EditEffect([rows[1]], label: "x", fields: [EffectFields.field(.corners, 3)]) { _ in })
        }
        let stroke = AppearanceEditing.stack(one, in: a.state)[0]
        #expect(throws: PathEditError.unknownPoint(stroke.element)) { try a.perform(ReseedEffect([(one, stroke)])) }
    }

    @Test func theReadOutNormalizesAttachmentAndUnknownKinds() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([rect]))
        let fill = AppearanceEditing.stack(rect, in: a.state)[1]
        try a.perform(AddEffect([rect], kind: .combine, attachTo: [rect: fill]))
        let row = Self.effects(rect, a.state)[0].row
        #expect(EffectReading.notice(Self.effects(rect, a.state)[0], node: rect, in: a.state) == EffectNames.combineNotice)
        // The fill it is attached to goes: the effect reads as skipped, not as the object's.
        try a.perform(RemoveAppearance(node: rect, row: fill))
        #expect(Self.effects(rect, a.state)[0].attachment == .skipped)
        #expect(EffectReading.group(rect, target: nil, in: a.state).isEmpty)
        // An unknown kind (a newer client's) is listed as unsupported.
        try a.perform(EditEffect([(rect, row)], label: "x", fields: [EffectFields.kind]) { $0.kind = .UNRECOGNIZED(99) })
        let entry = Self.effects(rect, a.state)[0]
        #expect(entry.kind == nil && entry.title == EffectNames.unsupported && EffectReading.notice(entry, node: rect, in: a.state) == nil)
        #expect(EffectReading.entries(OpID(counter: 999, replica: 9), in: a.state).isEmpty)
        #expect(EffectFields.settingsField(.unspecified) == nil && EffectFields.seeded(.unspecified).isEmpty)
        // Combine at the object level of a group is fine.
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 30), on: &a)
        let group = try a.perform(GroupObjects([rect, other]))!.createdObjects[0]
        try a.perform(AddEffect([group], kind: .combine))
        let combine = Self.effects(group, a.state)[0]
        #expect(combine.title == "Combine" && EffectReading.notice(combine, node: group, in: a.state) == nil)
    }

    @Test func effectsReachTheDisplayList() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii(topLeft: 4, topRight: 4, bottomRight: 4, bottomLeft: 4)),
                                                       size: Size(width: 20, height: 10)), on: &a)
        let stroke = AppearanceEditing.stack(rect, in: a.state)[0]
        try a.perform(AddEffect([rect], kind: .bend))
        try a.perform(AddEffect([rect], kind: .blur, attachTo: [rect: stroke]))
        guard case .path(let item)? = Self.item(a.state, rect) else { Issue.record("no item"); return }
        #expect(item.appearance.effects.map(\.target) == [.element(0), .object])
        #expect(item.appearance.effects[1].effect == .bend(LiveEffect.Bend(size: 20)))
        #expect(item.appearance.raster == RasterSettings())
        // A Corners effect on a rectangle takes over its radii: the derived path has sharp corners.
        let rounded = item.path
        try a.perform(AddEffect([rect], kind: .corners))
        guard case .path(let cornered)? = Self.item(a.state, rect) else { Issue.record("no item"); return }
        #expect(cornered.path != rounded && cornered.path.elements.count == 6, "a move, four lines and a close")
        // Hiding the stroke drops the effect attached to it.
        try a.perform(SetAppearanceHidden([(rect, stroke)], hidden: true))
        guard case .path(let hidden)? = Self.item(a.state, rect) else { Issue.record("no item"); return }
        #expect(hidden.appearance.effects.allSatisfy { $0.target == .object })

        // Raster resolution: the object's own, else the document's.
        var settings = Wiretuner_Doc_V1_NodeProps()
        settings.settings.rasterEffects.resolutionPpi = 300
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let write = try a.perform(OpsCommand("Resolution", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 90, 1])], values: settings)]))!
        let (scene, _) = builder.apply(write, state: a.state, origin: .local)
        guard case .path(let document)? = scene.object(rect)?.item else { Issue.record("no item"); return }
        #expect(document.appearance.raster.resolution == 300, "a raster settings change rebuilds cached items")
        var own = Wiretuner_Doc_V1_NodeProps()
        own.rect.appearance.rasterDpi = 150
        try a.perform(OpsCommand("Own", ops: [Ops.set(rect, [RegisterPath([21, 4, 4])], values: own)]))
        guard case .path(let object)? = Self.item(a.state, rect) else { Issue.record("no item"); return }
        #expect(object.appearance.raster.resolution == 150)
    }

    @Test func cornersPointsGroupsAndOpenPaths() throws {
        var a = Replica(0xA)
        let (path, contour) = PathFixture.ids(try a.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)])), in: a.state)
        let points = a.path(path).contours[0].drawn.map(\.id)
        try a.perform(AddEffect([path], kind: .corners))
        let row = Self.effects(path, a.state)[0].row
        try a.perform(SetCornerPoints([(path, row)], points: [points[2], OpID(counter: 999, replica: 9)], adding: true))
        guard case .path(let item)? = Self.item(a.state, path), case .corners(let corners) = item.appearance.effects[0].effect else {
            Issue.record("no corners"); return
        }
        #expect(corners.points == [CornerPoint(contour: 0, anchor: 2)], "dangling members drop out")
        _ = contour
        // Every member dangling: no corner is treated (not every corner).
        try a.perform(SetCornerPoints([(path, row)], points: [points[2]], adding: false))
        guard case .path(let none)? = Self.item(a.state, path), case .corners(let empty) = none.appearance.effects[0].effect else { return }
        #expect(empty.points == [CornerPoint(contour: -1, anchor: -1)])

        // A group's own effects travel on its item.
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 30), on: &a)
        let group = try a.perform(GroupObjects([path, other]))!.createdObjects[0]
        try a.perform(AddEffect([group], kind: .shadow))
        guard case .group(let groupItem)? = Self.item(a.state, group) else { Issue.record("no group"); return }
        #expect(groupItem.appearance.effects.count == 1)

        // An open path with a fill splits into one item per attribute; effects follow.
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let split = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (5, 0), (5, 5)])),
                                                                   NewContour(points: PathFixture.points([(10, 0), (20, 0)]))],
                                                        appearance: appearance), on: &a)
        let splitStroke = AppearanceEditing.stack(split, in: a.state).first { $0.list == .strokes }!
        try a.perform(AddEffect([split], kind: .bend))
        try a.perform(AddEffect([split], kind: .blur, attachTo: [split: splitStroke]))
        guard case .group(let parts)? = Self.item(a.state, split) else { Issue.record("no split"); return }
        #expect(parts.appearance.effects.map(\.target) == [.object])
        let attached = parts.children.compactMap { child -> [EffectElement]? in
            if case .path(let item) = child { return item.appearance.effects }
            return nil
        }
        #expect(attached.flatMap { $0 }.map(\.target) == [.element(0)])
    }

    @Test func everyKindLowers() {
        func lowered(_ build: (inout Wiretuner_Doc_V1_EffectSettings) -> Void) -> LiveEffect {
            var settings = Wiretuner_Doc_V1_EffectSettings()
            build(&settings)
            return EffectLowering.effect(settings)
        }
        #expect(lowered { $0.kind = .duet; $0.duet.mode = .rotate; $0.duet.copies = 6 } == .duet(LiveEffect.Duet(mode: .rotate, copies: 6)))
        #expect(lowered { $0.kind = .expandPath; $0.expandPath.direction = .inside; $0.expandPath.cap = .round; $0.expandPath.join = .bevel }
            == .expandPath(LiveEffect.ExpandPath(direction: .inside, cap: .round, join: .bevel)))
        #expect(lowered { $0.kind = .expandPath; $0.expandPath.direction = .outside } == .expandPath(LiveEffect.ExpandPath(direction: .outside)))
        #expect(lowered { $0.kind = .ragged; $0.ragged.smooth = true; $0.ragged.seed = 3 } == .ragged(LiveEffect.Ragged(smooth: true, seed: 3)))
        #expect(lowered { $0.kind = .sketch; $0.sketch.closed = true } == .sketch(LiveEffect.Sketch(closed: true, seed: 0)))
        #expect(lowered { $0.kind = .transform; $0.transform.rotate = 30; $0.transform.move.x = 5 }
            == .transform(LiveEffect.Transform(rotate: 30, move: Point(x: 5, y: 0))))
        #expect(lowered { $0.kind = .corners; $0.corners.style = .chamfer } == .corners(LiveEffect.Corners(style: .chamfer)))
        #expect(lowered { $0.kind = .corners; $0.corners.style = .invertedRound } == .corners(LiveEffect.Corners(style: .invertedRound)))
        #expect(lowered { $0.kind = .combine; $0.combine.op = .exclude } == .combine(LiveEffect.Combine(operation: .exclude)))
        let bevel = lowered { $0.kind = .bevelEmboss; $0.bevelEmboss.style = .outerBevel; $0.bevelEmboss.edgeShape = .ring; $0.bevelEmboss.buttonPreset = .inset }
        #expect(bevel == .bevelEmboss(LiveEffect.BevelEmboss(style: .outerBevel, edgeShape: .ring, buttonPreset: .inset)))
        let colored = lowered { $0.kind = .bevelEmboss; $0.bevelEmboss.color = Appearances.inline(red: 1, green: 0, blue: 0) }
        #expect(colored == .bevelEmboss(LiveEffect.BevelEmboss(color: Color(red: 1, green: 0, blue: 0))))
        #expect(lowered { $0.kind = .blur; $0.blur.style = .basic; $0.blur.radius = 3 } == .blur(LiveEffect.Blur(style: .basic, radius: 3)))
        #expect(lowered { $0.kind = .shadow; $0.shadow.style = .innerGlow; $0.shadow.color = ColorResolver.none }
            == .shadow(LiveEffect.Shadow(style: .innerGlow, color: .clear)))
        #expect(lowered { $0.kind = .sharpen; $0.sharpen.style = .unsharpMask; $0.sharpen.threshold = 4 }
            == .sharpen(LiveEffect.Sharpen(style: .unsharpMask, threshold: 4)))
        let mask = lowered { settings in
            settings.kind = .transparency
            settings.transparency.style = .gradientMask
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.color = Appearances.inline(red: 0, green: 0, blue: 0)
            settings.transparency.mask.stops = [stop]
        }
        guard case .transparency(let transparency) = mask else { Issue.record("not transparency"); return }
        #expect(transparency.style == .gradientMask && transparency.mask?.stops.count == 1)
        #expect(lowered { $0.kind = .transparency; $0.transparency.style = .feather } == .transparency(LiveEffect.Transparency(style: .feather)))
        #expect(lowered { $0.kind = .UNRECOGNIZED(77) } == .unsupported)
        #expect(Seeds.allocate(replica: 0, counter: 0) != 0 && Seeds.allocate(replica: 1, counter: 2) != Seeds.allocate(replica: 2, counter: 1))
    }

    @Test func defaultsLowerAndStraysAreSkipped() throws {
        for (kind, name) in AttributeNames.effectKinds {
            #expect(EffectLowering.effect(EffectDefaults.settings(kind, seed: 1)) != .unsupported, "\(name)")
        }
        var shadow = Wiretuner_Doc_V1_EffectSettings()
        shadow.kind = .shadow
        #expect(EffectLowering.effect(shadow) == .shadow(LiveEffect.Shadow(color: .black)))
        var corners = EffectDefaults.settings(.corners, seed: 1)
        corners.corners.points = [OpID(counter: 3, replica: 3).elementID]
        guard case .corners(let lowered) = EffectLowering.effect(corners) else { Issue.record("not corners"); return }
        #expect(lowered.points == [CornerPoint(contour: -1, anchor: -1)])
        // An effect attached to an element the stack does not hold is skipped.
        var appearance = Appearances.standard
        var stray = Wiretuner_Doc_V1_Effect()
        stray.settings = EffectDefaults.settings(.blur, seed: 1)
        stray.attachedTo = OpID(counter: 77, replica: 7).elementID
        appearance.effects = [stray]
        #expect(Appearances.resolve(appearance).effects.isEmpty)
        // Without a resolver a Corners effect's members all drop out.
        var cornered = Wiretuner_Doc_V1_Effect()
        cornered.settings = corners
        appearance.effects = [cornered]
        guard case .corners(let unresolved)? = Appearances.resolve(appearance).effects.first?.effect else { Issue.record("no corners"); return }
        #expect(unresolved.points == [CornerPoint(contour: -1, anchor: -1)])
        #expect(EffectReading.elementID([1, 2, 3]) == nil)
    }

    @Test func duplicatesGetSeedsOfTheirOwn() throws {
        var a = Replica(0xA)
        // The document's default attributes (the settings node) and a Custom fill.
        var custom = Appearances.basicFill(red: 0, green: 0, blue: 0)
        custom.settings.kind = .custom
        custom.settings.custom.seed = 5
        try a.perform(AddAppearance.fill([WellKnown.settings], custom))
        let row = AppearanceEditing.stack(WellKnown.settings, in: a.state).first { $0.list == .fills }!
        try a.perform(DuplicateAppearance(node: WellKnown.settings, row: row))
        let seeds = AppearanceEditing.entries(WellKnown.settings, in: a.state).filter { $0.row.list == .fills }.map(\.fill.settings.custom.seed)
        #expect(seeds.count == 2 && seeds.contains(5) && !seeds.allSatisfy { $0 == 5 })
    }

    // MARK: Merges

    @Test func concurrentAddsKeepBothInOneOrder() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.a.perform(AddEffect([rect], kind: .bend))
        try pair.b.perform(AddEffect([rect], kind: .ragged))
        pair.sync()
        let kinds = Self.effects(rect, pair.a.state).map(\.kind)
        #expect(Set(kinds) == [.bend, .ragged])
        #expect(kinds == Self.effects(rect, pair.b.state).map(\.kind), "both replicas order them alike")
    }

    @Test func removeVersusEditAndKindVersusEdit() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        try pair.a.perform(AddEffect([rect], kind: .bend))
        try pair.a.perform(AddEffect([rect], kind: .transform))
        pair.sync()
        let rows = Self.effects(rect, pair.a.state).map(\.row)
        // Remove vs. edit: deleted, and restoring brings the edit back.
        try pair.a.perform(RemoveEffect([(rect, rows[0])]))
        try pair.b.perform(EditEffect([(rect, rows[0])], label: "Size", fields: [EffectFields.field(.bend, 1)]) { $0.bend.size = 33 })
        pair.sync()
        #expect(Self.effects(rect, pair.a.state).map(\.row) == [rows[1]] && Self.effects(rect, pair.b.state).map(\.row) == [rows[1]])
        pair.a.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(Self.effects(rect, replica.state).first { $0.row == rows[0] }?.effect.settings.bend.size == 33)
        }
        // Kind change vs. edit of the old kind: both kept.
        try pair.a.perform(SetEffectKind([(rect, rows[1])], kind: .sketch))
        try pair.b.perform(EditEffect([(rect, rows[1])], label: "Rotate", fields: [EffectFields.field(.transform, 6)]) { $0.transform.rotate = 45 })
        pair.sync()
        for replica in [pair.a, pair.b] {
            let entry = Self.effects(rect, replica.state).first { $0.row == rows[1] }!
            #expect(entry.kind == .sketch && entry.effect.settings.transform.rotate == 45)
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}
