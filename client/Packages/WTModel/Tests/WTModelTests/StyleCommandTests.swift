import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// LIB-019 support: a document with one layer, and readers of looks.
enum StyleCommandFixture {
    /// A replica with a layer; returns it and the layer.
    static func document() throws -> (Replica, OpID) {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        return (a, layer)
    }

    /// Rectangles on `layer` in one change.
    static func objects(_ list: [(style: OpID?, fill: Double?, halftone: Bool)], layer: OpID, on replica: inout Replica) throws -> [OpID] {
        try replica.perform(CreateTrees(list.enumerated().map { index, spec in
            StyleFixture.object(on: layer, style: spec.style, fill: spec.fill, halftone: spec.halftone, key: [0x80, UInt8(index + 1)])
        }))!.createdNodes
    }

    static func look(_ object: OpID, _ state: EngineState) -> StyleStacks.Look {
        StyleStacks.look(of: object, styles: GraphicStyleResolver(state), state: state)
    }

    /// The red of the look's first fill.
    static func red(_ look: StyleStacks.Look) -> Double? {
        guard case .fill(let fill)? = look.stack.first(where: { $0.list == .fills }) else { return nil }
        return fill.settings.basic.color.inline.rgb.r
    }

    /// The width of the look's first stroke.
    static func width(_ look: StyleStacks.Look) -> Double? {
        guard case .stroke(let stroke)? = look.stack.first(where: { $0.list == .strokes }) else { return nil }
        return stroke.settings.basic.width
    }

    static func own(_ node: OpID, _ state: EngineState) -> Set<StyleCategory> {
        GraphicStyleResolver(state).ownCategories(of: node, in: state)
    }

    static func styleRef(_ object: OpID, _ state: EngineState) -> OpID? {
        GraphicStyleResolver(state).style(of: object, in: state)
    }

    /// Adds a stroke of `width` to `node`'s own stack.
    static func stroke(_ width: Double, on node: OpID, _ replica: inout Replica) throws {
        try replica.perform(AddAppearance.stroke([node], Appearances.basicStroke(red: 0, green: 0, blue: 0, width: width)))
    }

    static func setOps(_ change: Wiretuner_Doc_V1_Change?) -> [Wiretuner_Doc_V1_SetFields] {
        (change?.ops ?? []).compactMap { if case .set(let set)? = $0.op { set } else { nil } }
    }

    static func inserts(_ change: Wiretuner_Doc_V1_Change?) -> Int {
        (change?.ops ?? []).filter { if case .elementInsert? = $0.op { true } else { false } }.count
    }
}

@Suite struct StyleCommandTests {
    typealias F = StyleCommandFixture

    // MARK: New, Normal, duplicate, rename

    @Test func newFromSelectionTakesTheLookAndSwitchesTheObject() throws {
        var (a, layer) = try F.document()
        let object = try F.objects([(nil, 0.7, true)], layer: layer, on: &a)[0]
        try F.stroke(3, on: object, &a)
        let before = F.look(object, a.state)
        let hash = RestoreContent.hash(a.state)
        let change = try #require(try a.perform(CreateGraphicStyle(.selection(object), applyTo: [object])))
        #expect(change.label == "New style")
        let styles = GraphicStyleResolver(a.state)
        let style = try #require(GraphicStyleFields.styles(in: a.state, styles).first)
        #expect(styles.entries[style]?.props.common.name == "Style 1")
        #expect(styles.governs(style) == Set(StyleCategory.allCases))
        #expect(styles.entries[style]?.props.behavior == GraphicStyleFields.behavior(Set(StyleCategory.allCases)))
        #expect(F.styleRef(object, a.state) == style)
        #expect(F.own(object, a.state).isEmpty, "the overrides moved into the style")
        #expect(F.look(object, a.state) == before, "the object looks the same")
        #expect(StyleStacks.canonical(StyleStacks.entries(.style(style), in: a.state), source: style) == before.stack)
        #expect(styles.entries[style]?.props.common.halftone.frequency == 85)
        a.undo()
        #expect(RestoreContent.hash(a.state) == hash, "one change, one undo step")
        // Auto-apply off: the object keeps its own look and no style.
        try a.perform(CreateGraphicStyle(.selection(object), name: "Kept"))
        #expect(F.styleRef(object, a.state) == nil && F.own(object, a.state) == [.fills, .strokes, .halftone])
        #expect(throws: GraphicStyleError.notObject(layer)) { try a.perform(CreateGraphicStyle(.selection(layer))) }
        #expect(throws: GraphicStyleError.notObject(WellKnown.settings)) { try a.perform(CreateGraphicStyle(.selection(WellKnown.settings))) }
        #expect(throws: GraphicStyleError.invalidValue("name")) { try a.perform(CreateGraphicStyle(.defaults, name: String(repeating: "x", count: 257))) }
    }

    @Test func newFromNormalStyleAndDefaults() throws {
        var (a, _) = try F.document()
        let fromNormal = try #require(try a.perform(CreateGraphicStyle(.normal)))
        var styles = GraphicStyleResolver(a.state)
        let normal = try #require(styles.normal)
        #expect(fromNormal.createdNodes.count == 2 && fromNormal.createdNodes[0] == normal, "Normal is created in the same change")
        let child = fromNormal.createdNodes[1]
        #expect(styles.entries[normal]?.props.common.name == "Normal" && styles.role(of: normal) == .normal)
        #expect(styles.parent(of: child) == normal && styles.entries[child]?.props.common.name == "Style 1")
        #expect(GraphicStyleFields.styles(in: a.state, styles) == [normal, child], "Normal sits below the new style")
        #expect(try a.perform(CreateNormalGraphicStyle()) == nil, "Normal exists")
        #expect(!CreateNormalGraphicStyle().recordsUndo && CreateNormalGraphicStyle().label == "New style")
        let second = try #require(try a.perform(CreateGraphicStyle(.normal))).createdNodes
        #expect(second.count == 1)
        let fromStyle = try #require(try a.perform(CreateGraphicStyle(.style(child), name: "Kid"))).createdNodes[0]
        let fromDefaults = try #require(try a.perform(CreateGraphicStyle(.defaults))).createdNodes[0]
        styles.update(a.state)
        #expect(styles.parent(of: fromStyle) == child && styles.entries[second[0]]?.props.common.name == "Style 2")
        #expect(StyleStacks.canonical(StyleStacks.entries(.style(fromDefaults), in: a.state), source: fromDefaults) == StyleStacks.defaultsLook(in: a.state).stack)
        #expect(throws: GraphicStyleError.notStyle(WellKnown.settings)) { try a.perform(CreateGraphicStyle(.style(WellKnown.settings))) }
        // The document template's hook on an empty document.
        var b = Replica(0xB)
        try b.perform(CreateNormalGraphicStyle())
        #expect(GraphicStyleResolver(b.state).normal != nil)
    }

    @Test func duplicateAndRename() throws {
        var (a, _) = try F.document()
        let ids = try StyleFixture.create([StyleFixture.props("Base"), StyleFixture.props("Callout", behavior: [.fills, .halftone], fill: 0.4, halftone: 45),
                                           StyleFixture.props("Body", kind: .paragraph)], on: &a)
        try a.perform(OpsCommand("Parent", ops: [StyleFixture.setParent(ids[1], ids[0])]))
        let change = try #require(try a.perform(DuplicateGraphicStyle(ids[1])))
        #expect(change.label == "Duplicate style")
        let copy = change.createdNodes[0]
        let styles = GraphicStyleResolver(a.state)
        let props = try #require(styles.entries[copy]?.props)
        #expect(props.common.name == "Callout copy" && styles.parent(of: copy) == ids[0] && styles.governs(copy) == [.fills, .halftone])
        #expect(props.common.halftone.frequency == 45 && props.appearance.fills.count == 1)
        #expect(try a.perform(RenameGraphicStyle(copy, to: "Note"))?.label == "Rename style")
        #expect(GraphicStyleResolver(a.state).entries[copy]?.props.common.name == "Note")
        #expect(throws: GraphicStyleError.invalidValue("name")) { try a.perform(RenameGraphicStyle(copy, to: "")) }
        #expect(throws: GraphicStyleError.notStyle(ids[2])) { try a.perform(RenameGraphicStyle(ids[2], to: "X")) }
        #expect(throws: GraphicStyleError.notStyle(ids[2])) { try a.perform(DuplicateGraphicStyle(ids[2])) }
        // A duplicate of a parentless style has no parent.
        let plain = try #require(try a.perform(DuplicateGraphicStyle(ids[0]))).createdNodes[0]
        #expect(GraphicStyleResolver(a.state).parent(of: plain) == nil)
    }

    // MARK: Apply

    @Test func applyClearsOverridesInGovernedCategoriesWithTheClearToUnsetForm() throws {
        var (a, layer) = try F.document()
        let style = try StyleFixture.create([StyleFixture.props("Fill", behavior: [.fills, .halftone], fill: 0.2, halftone: 30)], on: &a)[0]
        let objects = try F.objects([(nil, 0.9, true), (nil, 0.9, false)], layer: layer, on: &a)
        try F.stroke(4, on: objects[0], &a)
        let change = try #require(try a.perform(ApplyGraphicStyle(style, to: objects + [layer], in: a.state)))
        #expect(change.label == "Apply style Fill")
        let sets = F.setOps(change)
        // Reference written, halftone listed with no value (cleared) -- also where none is seen.
        #expect(sets[0].paths.count == 2 && !sets[0].values.rect.common.hasHalftone && sets[0].values.rect.common.hasStyle)
        #expect(sets.count == 2 && sets[1].paths.count == 2)
        #expect(F.own(objects[0], a.state) == [.strokes], "the ungoverned stroke is kept")
        #expect(F.red(F.look(objects[0], a.state)) == 0.2 && F.width(F.look(objects[0], a.state)) == 4)
        #expect(F.look(objects[0], a.state).halftone?.frequency == 30)
        #expect(a.state.register(objects[0], RegisterPath([NodeKind.rect.rawValue, 1, 11]))?.isSet == false)
        #expect(ApplyGraphicStyle(style, to: []).label == "Apply style")
        #expect(throws: GraphicStyleError.notStyle(layer)) { try a.perform(ApplyGraphicStyle(layer, to: objects)) }
        // Overrides after applying, then re-clicking the style removes them.
        try a.perform(AddAppearance.fill([objects[1]], Appearances.basicFill(red: 0.6, green: 0, blue: 0)))
        #expect(GraphicStyleDefaults.overrides(of: objects[1], in: a.state) == [.fills])
        try a.perform(ApplyGraphicStyle(style, to: [objects[1]]))
        #expect(GraphicStyleDefaults.overrides(of: objects[1], in: a.state).isEmpty)
        #expect(GraphicStyleDefaults.overrides(of: layer, in: a.state).isEmpty)
    }

    // MARK: Redefine

    @Test func redefineFromAnObjectEditsInPlaceAndTakesItsOverrides() throws {
        var (a, layer) = try F.document()
        let style = try StyleFixture.create([StyleFixture.props("Line", fill: 0.1, stroke: 1)], on: &a)[0]
        let objects = try F.objects([(style, nil, false), (style, nil, false)], layer: layer, on: &a)
        let strokeElement = try #require(a.state.liveElements(style, RegisterPath([154, 6, 2])).first)
        try a.perform(ApplyGraphicStyle(style, to: [objects[0]]))
        try F.stroke(3, on: objects[0], &a)
        #expect(F.width(F.look(objects[1], a.state)) == 1)
        let hash = RestoreContent.hash(a.state)
        let change = try #require(try a.perform(RedefineGraphicStyle(style, from: .object(objects[0]), in: a.state)))
        #expect(change.label == "Redefine style Line")
        #expect(F.inserts(change) == 0, "the stroke is edited in place")
        let sets = F.setOps(change)
        #expect(sets.first?.paths.map { RegisterPath($0) } == [RegisterPath([154, 6, 2]).element(strokeElement).appending([3, 2, 2])])
        #expect(a.state.liveElements(style, RegisterPath([154, 6, 2])) == [strokeElement])
        #expect(F.width(F.look(objects[1], a.state)) == 3, "every object using the style changes")
        #expect(F.own(objects[0], a.state).isEmpty, "the source object's overrides became the redefinition")
        a.undo()
        #expect(RestoreContent.hash(a.state) == hash)
        #expect(RedefineGraphicStyle(style, from: .defaults).label == "Redefine style")
        #expect(throws: GraphicStyleError.notObject(layer)) { try a.perform(RedefineGraphicStyle(style, from: .object(layer))) }
        // A redefinition that changes nothing writes nothing.
        #expect(try a.perform(RedefineGraphicStyle(style, from: .object(objects[1]))) == nil)
    }

    @Test func redefineReplacesInsertsAndDeletesWhereKindsOrCountsDiffer() throws {
        var (a, layer) = try F.document()
        var props = StyleFixture.props("S", fill: 0.1, stroke: 1)
        props.style.appearance.strokes.append(Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 9))
        let ids = try StyleFixture.create([props, StyleFixture.props("Other", fill: 0.3)], on: &a)
        let style = ids[0]
        // Another style's look (one fill, no stroke of its own; strokes from the defaults are not
        // part of a style's look): the fill is edited, both strokes go.
        let change = try #require(try a.perform(RedefineGraphicStyle(style, from: .style(ids[1]))))
        #expect(F.inserts(change) == 0)
        #expect(a.state.liveElements(style, RegisterPath([154, 6, 2])).isEmpty)
        #expect(F.red(StyleStacks.look(chain: [style], styles: GraphicStyleResolver(a.state), state: a.state).look) == 0.3)
        // An object whose fill is a gradient and which has two strokes: the fill is replaced (kind
        // differs), the strokes are inserted above.
        var gradient = Wiretuner_Doc_V1_Fill()
        gradient.settings.kind = .gradient
        var stop = Wiretuner_Doc_V1_GradientStop()
        stop.offset = 0.5
        gradient.settings.gradient.stops = [stop]
        func shape(_ fill: Wiretuner_Doc_V1_Fill, key: UInt8) -> (OpID, [UInt8], Wiretuner_Doc_V1_NodeProps) {
            var (parent, position, props) = StyleFixture.object(on: layer, style: nil, key: [0x90, key])
            props.rect.appearance.fills = [fill]
            props.rect.appearance.strokes = [2.0, 5.0].map { Appearances.basicStroke(red: 0, green: 0, blue: 0, width: $0) }
            return (parent, position, props)
        }
        var moved = gradient
        moved.settings.gradient.stops[0].offset = 0.25
        let shapes = try #require(try a.perform(CreateTrees([shape(gradient, key: 1), shape(moved, key: 2)]))).createdNodes
        let (object, second) = (shapes[0], shapes[1])
        let fill = try #require(a.state.liveElements(style, RegisterPath([154, 6, 1])).first)
        let replaced = try #require(try a.perform(RedefineGraphicStyle(style, from: .object(object))))
        #expect(F.inserts(replaced) == 4, "the gradient fill, its stop and two strokes")
        let fills = a.state.liveElements(style, RegisterPath([154, 6, 1]))
        #expect(fills.count == 1 && fills[0] != fill)
        let look = StyleStacks.look(chain: [style], styles: GraphicStyleResolver(a.state), state: a.state).look
        #expect(look.stack.map(\.list) == [.fills, .strokes, .strokes])
        #expect(F.width(look) == 2)
        guard case .fill(let stored)? = look.stack.first else { Issue.record("no fill"); return }
        #expect(stored.settings.gradient.stops.map(\.offset) == [0.5])
        // A second object like it whose stop sits elsewhere: the nested sequence differs, so the
        // fill is replaced again; the strokes match and stay.
        let again = try #require(try a.perform(RedefineGraphicStyle(style, from: .object(second))))
        #expect(F.inserts(again) == 2, "the fill and its stop")
    }

    @Test func redefineKeepsInheritedCategoriesAndAttachedEffects() throws {
        var (a, layer) = try F.document()
        let ids = try StyleFixture.create([StyleFixture.props("Parent", fill: 0.5, stroke: 2), StyleFixture.props("Child")], on: &a)
        try a.perform(OpsCommand("Parent", ops: [StyleFixture.setParent(ids[1], ids[0])]))
        // Redefining the child from its parent changes nothing: it keeps inheriting.
        #expect(try a.perform(RedefineGraphicStyle(ids[1], from: .style(ids[0]))) == nil)
        // An object with a fill and an effect attached to it: the child takes both, the effect
        // attached to the child's copy of the fill.
        let object = try F.objects([(nil, 0.8, false)], layer: layer, on: &a)[0]
        let fillRow = try #require(a.state.liveElements(object, RegisterPath([NodeKind.rect.rawValue, 4, 1])).first)
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .bend
        effect.attachedTo = Ops.elementID(fillRow)
        try a.perform(AddAppearance.effect([object], effect))
        try a.perform(RedefineGraphicStyle(ids[1], from: .object(object)))
        let own = a.state.props(ids[1]).style.appearance
        #expect(own.fills.count == 1 && own.effects.count == 1)
        #expect(OpID(element: own.effects[0].attachedTo) == OpID(element: own.fills[0].id))
        // Redefining again with the effect detached edits the attachment in place.
        let effectRow = try #require(a.state.liveElements(object, RegisterPath([NodeKind.rect.rawValue, 4, 3])).first)
        var detached = Wiretuner_Doc_V1_Effect()
        detached.id = Ops.elementID(effectRow)
        try a.perform(OpsCommand("Detach", ops: [Ops.set(object, [RegisterPath([NodeKind.rect.rawValue, 4, 3]).element(effectRow).child(3)],
                                                         values: Wiretuner_Doc_V1_NodeProps.with { $0.rect.appearance.effects = [detached] })]))
        let change = try #require(try a.perform(RedefineGraphicStyle(ids[1], from: .object(object))))
        #expect(F.inserts(change) == 0)
        #expect(!a.state.props(ids[1]).style.appearance.effects[0].hasAttachedTo)
    }

    // MARK: Remove

    @Test func removeBakesLooksReparentsChildrenAndDeletes() throws {
        var (a, layer) = try F.document()
        let ids = try StyleFixture.create([StyleFixture.props("P", stroke: 2), StyleFixture.props("S", behavior: [.fills, .halftone], fill: 0.3, halftone: 50),
                                           StyleFixture.props("C", behavior: [.strokes, .effects])], on: &a)
        let (p, s, c) = (ids[0], ids[1], ids[2])
        try a.perform(OpsCommand("Parents", ops: [StyleFixture.setParent(s, p), StyleFixture.setParent(c, s)]))
        let objects = try F.objects([(s, nil, false), (s, 0.9, false), (c, nil, false), (nil, nil, false)], layer: layer, on: &a)
        let looks = objects.map { F.look($0, a.state) }
        let hash = RestoreContent.hash(a.state)
        let change = try #require(try a.perform(RemoveGraphicStyle(s, in: a.state)))
        #expect(change.label == "Remove style S")
        let styles = GraphicStyleResolver(a.state)
        #expect(!a.state.isLive(s))
        #expect(objects.map { F.look($0, a.state) } == looks, "every look is kept")
        #expect(F.styleRef(objects[0], a.state) == p && F.own(objects[0], a.state) == [.fills, .halftone])
        #expect(F.own(objects[1], a.state) == [.fills, .halftone], "an existing override is kept, not rewritten")
        #expect(styles.parent(of: c) == p)
        #expect(styles.governs(c) == [.fills, .strokes, .effects, .halftone], "the child governs what it took over")
        #expect(F.red(StyleStacks.look(chain: [c], styles: styles, state: a.state).look) == 0.3)
        #expect(F.styleRef(objects[3], a.state) == nil)
        a.undo()
        #expect(RestoreContent.hash(a.state) == hash)
        #expect(RemoveGraphicStyle(s).label == "Remove style")
    }

    @Test func removeFallsBackToNormalOrNoStyleAndNeverRemovesNormal() throws {
        var (a, layer) = try F.document()
        let solo = try StyleFixture.create([StyleFixture.props("Solo", fill: 0.4)], on: &a)[0]
        let objects = try F.objects([(solo, nil, false)], layer: layer, on: &a)
        try a.perform(RemoveGraphicStyle(solo))
        #expect(F.styleRef(objects[0], a.state) == nil && F.red(F.look(objects[0], a.state)) == 0.4)
        // A node without an attribute stack naming a style is left as it is.
        let kept = try StyleFixture.create([StyleFixture.props("Kept", fill: 0.5)], on: &a)[0]
        var placed = Wiretuner_Doc_V1_NodeProps()
        placed.placedFile.common.style.id = kept.proto
        let file = try #require(try a.perform(CreateTrees([(layer, [0x90], placed)]))).createdNodes[0]
        try a.perform(RemoveGraphicStyle(kept))
        #expect(GraphicStyleResolver(a.state).style(of: file, in: a.state) == kept)
        try a.perform(CreateNormalGraphicStyle())
        let normal = try #require(GraphicStyleResolver(a.state).normal)
        let other = try StyleFixture.create([StyleFixture.props("Other", fill: 0.6)], on: &a)[0]
        let more = try F.objects([(other, nil, false)], layer: layer, on: &a)
        try a.perform(RemoveGraphicStyle(other))
        #expect(F.styleRef(more[0], a.state) == normal && F.red(F.look(more[0], a.state)) == 0.6)
        #expect(throws: GraphicStyleError.normal) { try a.perform(RemoveGraphicStyle(normal)) }
        #expect(throws: GraphicStyleError.notStyle(other)) { try a.perform(RemoveGraphicStyle(other)) }
    }

    @Test func removeUnusedKeepsUsedStylesTheirAncestorsAndNormal() throws {
        var (a, layer) = try F.document()
        try a.perform(CreateNormalGraphicStyle())
        let ids = try StyleFixture.create([StyleFixture.props("Root"), StyleFixture.props("Used"), StyleFixture.props("Idle"), StyleFixture.props("IdleKid")], on: &a)
        try a.perform(OpsCommand("Parents", ops: [StyleFixture.setParent(ids[1], ids[0]), StyleFixture.setParent(ids[3], ids[2])]))
        let group = try F.objects([(ids[1], nil, false)], layer: layer, on: &a)
        #expect(RemoveUnusedGraphicStyles.unused(in: a.state) == [ids[2], ids[3]])
        let change = try #require(try a.perform(RemoveUnusedGraphicStyles()))
        #expect(change.label == "Remove unused styles")
        #expect(!a.state.isLive(ids[2]) && !a.state.isLive(ids[3]) && a.state.isLive(ids[0]) && a.state.isLive(ids[1]))
        #expect(try a.perform(RemoveUnusedGraphicStyles()) == nil)
        _ = group
    }

    // MARK: Parent and behaviour

    @Test func setParentRefusesLoopsAndNormalAndDetachKeepsTheLook() throws {
        var (a, _) = try F.document()
        try a.perform(CreateNormalGraphicStyle())
        let normal = try #require(GraphicStyleResolver(a.state).normal)
        let ids = try StyleFixture.create([StyleFixture.props("A", fill: 0.2, stroke: 3, halftone: 70), StyleFixture.props("B", behavior: [.strokes]),
                                           StyleFixture.props("C")], on: &a)
        let (sa, sb, sc) = (ids[0], ids[1], ids[2])
        #expect(try a.perform(SetGraphicStyleParent(sb, parent: sa))?.label == "Style behavior")
        try a.perform(SetGraphicStyleParent(sc, parent: sb))
        #expect(throws: GraphicStyleError.loop(sc)) { try a.perform(SetGraphicStyleParent(sa, parent: sc)) }
        #expect(throws: GraphicStyleError.loop(sa)) { try a.perform(SetGraphicStyleParent(sa, parent: sa)) }
        #expect(throws: GraphicStyleError.normal) { try a.perform(SetGraphicStyleParent(normal, parent: sa)) }
        #expect(throws: GraphicStyleError.notStyle(WellKnown.settings)) { try a.perform(SetGraphicStyleParent(sa, parent: WellKnown.settings)) }
        #expect(SetGraphicStyleParent.candidates(for: sa, in: a.state) == [normal])
        #expect(Set(SetGraphicStyleParent.candidates(for: sc, in: a.state)) == [normal, sa, sb])
        // Detaching C (governs everything, sets nothing) folds in what it inherited.
        let styles = GraphicStyleResolver(a.state)
        let before = StyleStacks.look(chain: styles.chain(of: sc), styles: styles, state: a.state).look
        try a.perform(SetGraphicStyleParent(sc, parent: nil))
        let after = GraphicStyleResolver(a.state)
        #expect(after.parent(of: sc) == nil)
        #expect(StyleStacks.look(chain: [sc], styles: after, state: a.state).look == before)
        // Detaching B (governs strokes only) folds in the fill and halftone too, and governs them.
        try a.perform(SetGraphicStyleParent(sb, parent: nil))
        #expect(GraphicStyleResolver(a.state).governs(sb) == [.fills, .strokes, .halftone], "nobody sets effects: nothing to take over")
        #expect(a.state.props(sb).style.common.halftone.frequency == 70)
        // A style whose behaviour is all-false governs everything already: nothing to turn on.
        let open = try StyleFixture.create([StyleFixture.props("Open", behavior: [])], on: &a)[0]
        try a.perform(SetGraphicStyleParent(open, parent: sa))
        try a.perform(SetGraphicStyleParent(open, parent: nil))
        #expect(a.state.props(open).style.behavior == Wiretuner_Doc_V1_StyleBehavior())
        #expect(F.red(StyleStacks.look(chain: [open], styles: GraphicStyleResolver(a.state), state: a.state).look) == 0.2)
    }

    @Test func setBehaviorWritesOnlyTheCategoriesThatChange() throws {
        var (a, _) = try F.document()
        let style = try StyleFixture.create([StyleFixture.props("S")], on: &a)[0]
        let change = try #require(try a.perform(SetGraphicStyleBehavior(style, governs: [.strokes, .effects])))
        #expect(change.label == "Style behavior")
        #expect(F.setOps(change)[0].paths.map { RegisterPath($0) } == [RegisterPath([154, 5, 1]), RegisterPath([154, 5, 4])])
        #expect(GraphicStyleResolver(a.state).governs(style) == [.strokes, .effects])
        #expect(try a.perform(SetGraphicStyleBehavior(style, governs: [.strokes, .effects])) == nil)
        #expect(throws: GraphicStyleError.invalidValue("governs")) { try a.perform(SetGraphicStyleBehavior(style, governs: [])) }
    }

    // MARK: Defaults and plus signs

    @Test func selectingAStyleSetsTheDefaultsAndThePlusSignFollowsEdits() throws {
        var (a, _) = try F.document()
        #expect(GraphicStyleDefaults.style(in: a.state) == nil && !GraphicStyleDefaults.isModified(in: a.state))
        let style = try StyleFixture.create([StyleFixture.props("S", fill: 0.3, stroke: 2)], on: &a)[0]
        #expect(try a.perform(SelectGraphicStyleAsDefaults(style))?.label == "Default attributes")
        #expect(GraphicStyleDefaults.style(in: a.state) == style)
        #expect(!GraphicStyleDefaults.isModified(in: a.state))
        #expect(F.red(StyleStacks.defaultsLook(in: a.state)) == 0.3)
        try a.perform(AddAppearance.fill([WellKnown.settings], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        #expect(GraphicStyleDefaults.isModified(in: a.state))
        // Redefining from the defaults commits them and clears the plus sign.
        try a.perform(RedefineGraphicStyle(style, from: .defaults))
        #expect(!GraphicStyleDefaults.isModified(in: a.state))
        // Removing the mirrored style: the defaults mirror Normal (none here).
        try a.perform(RemoveGraphicStyle(style))
        #expect(GraphicStyleDefaults.style(in: a.state) == nil)
    }
}
