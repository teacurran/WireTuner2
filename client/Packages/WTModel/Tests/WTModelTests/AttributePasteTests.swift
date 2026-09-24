import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Copy Attributes and Paste Attributes (OBJ-014, copying.adoc "Copying attributes").
@Suite struct AttributePasteTests {
    /// A rectangle with, bottom first: a red fill, a 3 pt blue stroke, a green fill, and a Ragged
    /// effect attached to the stroke.
    static func source(on a: inout Replica) throws -> OpID {
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        for row in AppearanceEditing.stack(rect, in: a.state) {
            try a.perform(RemoveAppearance(node: rect, row: row))
        }
        try a.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        try a.perform(AddAppearance.stroke([rect], Appearances.basicStroke(red: 0, green: 0, blue: 1, width: 3)))
        try a.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 0, green: 1, blue: 0)))
        let stroke = AppearanceEditing.stack(rect, in: a.state)[1]
        try a.perform(AddEffect([rect], kind: .ragged, attachTo: [rect: stroke]))
        return rect
    }

    /// The stack of `node` with element ids replaced by stack places (as a payload holds it) and
    /// nested element ids cleared, for comparing stacks across objects.
    static func look(_ node: OpID, in state: EngineState) -> [AttributePayload.Element]? {
        AttributePayload(copying: node, from: state)?.stack?.map { element in
            switch element {
            case .fill(var fill):
                for index in fill.settings.gradient.stops.indices { fill.settings.gradient.stops[index].clearID() }
                return .fill(fill)
            default:
                return element
            }
        }
    }

    @Test func pastingOntoThreeKindsWritesEachStackInOneChange() throws {
        var a = Replica(0xA)
        let source = try Self.source(on: &a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 40), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 8, height: 8)), on: &a)
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (5, 8)]), on: &a)
        let payload = try #require(AttributePayload(copying: source, from: a.state))
        #expect(payload.stack?.count == 4 && payload.textAttributes == nil)
        let command = PasteAttributes(payload, to: [rect, ellipse, path], in: a.state)
        let change = try #require(try a.perform(command))
        #expect(change.label == "Paste attributes to 3 objects")
        let expected = Self.look(source, in: a.state)
        for target in [rect, ellipse, path] {
            #expect(Self.look(target, in: a.state) == expected)
        }
        // The effect is attached to the target's own copy of the stroke.
        let rows = AppearanceEditing.stack(path, in: a.state)
        let effect = a.state.props(path).path.appearance.effects[0]
        #expect(OpID(element: effect.attachedTo) == rows[1].element)
        #expect(rows.map(\.list) == AppearanceEditing.stack(source, in: a.state).map(\.list))
        // One undo step takes all three back.
        a.undo()
        #expect(AppearanceEditing.stack(path, in: a.state).count == 1)
        #expect(PasteAttributes(payload, to: [rect]).label == "Paste attributes")
        #expect(PasteAttributes(payload, to: [rect, path]).label == "Paste attributes to 2 objects")
    }

    @Test func gradientStopsComeWithTheirFill() throws {
        var a = Replica(0xA)
        let source = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(AddAppearance.fill([source]))
        let fill = AppearanceEditing.stack(source, in: a.state).first { $0.list == .fills }!
        try a.perform(ChooseGradient([(source, fill)]))
        let target = try LayerFixture.object(LayerFixture.rect(on: nil, x: 30), on: &a)
        let payload = try #require(AttributePayload(copying: source, from: a.state))
        try a.perform(PasteAttributes(payload, to: [target]))
        let copied = a.state.props(target).rect.appearance.fills[0].settings.gradient.stops
        #expect(copied.count == 2)
        #expect(Self.look(target, in: a.state) == Self.look(source, in: a.state))
    }

    @Test func thePayloadRoundTripsThroughThePasteboardEncoding() throws {
        var a = Replica(0xA)
        let source = try Self.source(on: &a)
        let payload = try #require(AttributePayload(copying: source, from: a.state))
        let bytes = payload.clipboard(sourceDocument: "D1").encoded()
        let decoded = try #require(ClipboardPayload(decoding: bytes))
        #expect(decoded.sourceDocument == "D1")
        #expect(AttributePayload(decoded) == payload)
        // Text attributes with a stack ride on the text node's block appearance.
        let both = AttributePayload(stack: payload.stack, textAttributes: [.with { $0.size = 12 }])
        #expect(AttributePayload(ClipboardPayload(decoding: both.clipboard().encoded())!) == both)
        // An object copy is not an attribute copy.
        #expect(AttributePayload(ClipboardPayload(nodes: [])) == nil)
        #expect(AttributePayload(ClipboardPayload(nodes: [NodeTree(props: .with { $0.group.kind = .group })])) == nil)
        #expect(AttributePayload(ClipboardPayload(nodes: [NodeTree(props: .with { $0.path = .init() }, children: [NodeTree(props: .init())])])) == nil)
        #expect(AttributePayload.pasteboardType != ClipboardPayload.pasteboardType)
    }

    @Test func textTakesTypeAttributesAndPathsIgnoreThem() throws {
        var a = Replica(0xA)
        var red = Wiretuner_Doc_V1_TextMarkValue()
        red.fill = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        let source = try LayerFixture.object(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "Hello",
                                                             marks: [.with { $0.size = 24 }, .with { $0.fontFamily = "Helvetica" }, red,
                                                                     .with { $0.link = "https://example.com" }]), on: &a)
        let target = try LayerFixture.object(CreateTextBlock(.point(Point(x: 0, y: 50)), text: "World",
                                                             marks: [.with { $0.baselineShift = 3 }, .with { $0.size = 9 }, .with { $0.feature.tag = "liga" }]), on: &a)
        let empty = try LayerFixture.object(CreateTextBlock(.point(Point(x: 0, y: 90))), on: &a)
        let path = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (5, 8)]), on: &a)
        let payload = try #require(AttributePayload(copying: source, from: a.state))
        #expect(payload.stack == nil)
        #expect(payload.textAttributes?.count == 3)   // the link belongs to the words
        let change = try #require(try a.perform(PasteAttributes(payload, to: [target, empty, path], in: a.state)))
        #expect(change.label == "Paste attributes to 2 objects")
        let values = try #require(a.state.textNode(target)).values(at: 0)
        #expect(values.contains { if case .size(24)? = $0.value { true } else { false } })
        #expect(values.contains { if case .fontFamily("Helvetica")? = $0.value { true } else { false } })
        #expect(values.contains(red))
        #expect(!values.contains { if case .baselineShift? = $0.value { true } else { false } })
        #expect(!values.contains { if case .feature? = $0.value { true } else { false } })
        // A text-only payload round-trips without a stack.
        #expect(AttributePayload(ClipboardPayload(decoding: payload.clipboard().encoded())!) == payload)
        // A chart has neither a stack nor text: nothing to copy.
        let chart = try a.perform(OpsCommand("chart", ops: [Ops.create(parent: Objects.parent(of: path, in: a.state)!, position: [0xF0],
                                                                       props: .with { $0.chart = .init() })]))!.createdNodes[0]
        #expect(AttributePayload(copying: chart, from: a.state) == nil)
        // The path kept its own stack.
        #expect(AppearanceEditing.stack(path, in: a.state).count == 1)
        // A path's stack is ignored by text; a chart-less group has a stack of its own.
        let pathPayload = try #require(AttributePayload(copying: path, from: a.state))
        #expect(try a.perform(PasteAttributes(pathPayload, to: [target])) == nil)
        #expect(AttributePayload(copying: OpID(counter: 999, replica: 9), from: a.state) == nil)
    }

    @Test func nothingIsPastedOntoALockedObjectOrFromAnEmptyStack() throws {
        var a = Replica(0xA)
        let source = try Self.source(on: &a)
        let locked = try LayerFixture.object(LayerFixture.rect(on: nil, x: 40), on: &a)
        try a.perform(SetLocked([locked], locked: true))
        let payload = try #require(AttributePayload(copying: source, from: a.state))
        #expect(try a.perform(PasteAttributes(payload, to: [locked], in: a.state)) == nil)
        #expect(PasteAttributes(payload, to: [locked], in: a.state).label == "Paste attributes to 0 objects")
        // An empty stack clears the target's.
        let bare = try LayerFixture.object(LayerFixture.rect(on: nil, x: 80), on: &a)
        try a.perform(PasteAttributes(AttributePayload(stack: []), to: [bare]))
        #expect(AppearanceEditing.stack(bare, in: a.state).isEmpty)
        // Pasting an empty stack onto an empty stack writes nothing.
        #expect(try a.perform(PasteAttributes(AttributePayload(stack: []), to: [bare])) == nil)
        // An effect attached to an element the payload does not hold is pasted unattached.
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .ragged
        effect.attachedTo = Ops.elementID(OpID(counter: 9, replica: 0))
        try a.perform(PasteAttributes(AttributePayload(stack: [.effect(effect)]), to: [bare]))
        #expect(!a.state.props(bare).rect.appearance.effects[0].hasAttachedTo)
        // An effect attached to a removed stroke reads unattached and copies unattached.
        let attached = try AttributePasteTests.source(on: &a)
        let stroke = AppearanceEditing.stack(attached, in: a.state).first { $0.list == .strokes }!
        try a.perform(RemoveAppearance(node: attached, row: stroke))
        let copied = try #require(AttributePayload(copying: attached, from: a.state)?.stack)
        #expect(copied.contains { if case .effect(let effect) = $0 { !effect.hasAttachedTo || effect.attachedTo == .init() } else { false } })
    }
}

/// OBJ-014's merge test.
@Suite struct AttributePasteMergeTests {
    @Test func aRemoteRecolorOfAReplacedElementStaysOnTheTombstoneAndReturnsOnUndo() throws {
        var pair = Pair()
        let source = try AttributePasteTests.source(on: &pair.a)
        let target = try LayerFixture.object(LayerFixture.rect(on: nil, x: 40), on: &pair.a)
        pair.sync()
        let stroke = AppearanceEditing.stack(target, in: pair.b.state).first { $0.list == .strokes }!
        let orange = ColorResolver.inline(Color(red: 1, green: 0.5, blue: 0))
        try pair.b.perform(SetAppearanceColor([(target, stroke)], color: orange))
        let payload = try #require(AttributePayload(copying: source, from: pair.a.state))
        try pair.a.perform(PasteAttributes(payload, to: [target]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let path = AppearanceEditing.sequence(.rect, .strokes)!
        #expect(pair.a.state.store.element(target, path.element(stroke.element))?.isDeleted == true)
        #expect(AttributePasteTests.look(target, in: pair.a.state) == AttributePasteTests.look(source, in: pair.a.state))
        // Undo of the paste brings the element back with B's colour.
        pair.a.undo()
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let restored = pair.a.state.props(target).rect.appearance.strokes
        #expect(restored.count == 1 && OpID(element: restored[0].id) == stroke.element)
        #expect(restored[0].settings.basic.color == orange)
    }
}
