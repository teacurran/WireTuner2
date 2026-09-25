import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Copies keep the attribute stack's interleaving (copying.adoc; attribute-stack.adoc "Data
/// model"): Paste, Clone and Duplicate insert the stack as one run in the source's order, with
/// each attached effect attached to the copy of its element.
@Suite struct NodeCopierStackTests {
    /// A rectangle whose stack is stroke (with a Ragged effect attached), fill -- bottom first: a copy
    /// positioning each list on its own would put the fill at the bottom.
    static func interleaved(_ replica: inout Replica) throws -> OpID {
        let layer = try NavigationFixture.layer(&replica)
        let rect = try NavigationFixture.rect(&replica, on: layer)
        try replica.perform(AddAppearance.fill([rect], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        let stroke = try #require(AppearanceEditing.stack(rect, in: replica.state).first { $0.list == .strokes })
        try replica.perform(AddEffect([rect], kind: .ragged, attachTo: [rect: stroke]))
        return rect
    }

    /// The stack of `node` as lists, bottom first, and whether each effect is attached to a stroke.
    static func shape(_ node: OpID, in state: EngineState) -> (lists: [AppearanceList], attachedToStroke: Bool) {
        let rows = AppearanceEditing.stack(node, in: state)
        let appearance = state.props(node).rect.appearance
        let strokes = Set(appearance.strokes.compactMap { OpID(element: $0.id) })
        let attached = appearance.effects.allSatisfy { OpID(element: $0.attachedTo).map(strokes.contains) ?? false }
        return (rows.map(\.list), attached && !appearance.effects.isEmpty)
    }

    @Test func cloneAndDuplicateKeepTheInterleavedOrder() throws {
        var replica = Replica(1)
        let rect = try Self.interleaved(&replica)
        let source = Self.shape(rect, in: replica.state)
        #expect(source.lists == [.strokes, .effects, .fills] && source.attachedToStroke)
        let clone = try #require(try replica.perform(DuplicateObjects.clone([rect]))).createdObjects[0]
        #expect(Self.shape(clone, in: replica.state) == source)
        let duplicate = try #require(try replica.perform(DuplicateObjects.duplicate([rect]))).createdObjects[0]
        #expect(Self.shape(duplicate, in: replica.state) == source)
        #expect(replica.state.props(duplicate).rect.appearance.fills.map(\.settings) == replica.state.props(rect).rect.appearance.fills.map(\.settings))
    }

    @Test func pasteKeepsTheOrderThroughThePasteboardEncoding() throws {
        var replica = Replica(1)
        let rect = try Self.interleaved(&replica)
        let payload = ClipboardPayload(copying: [rect], from: replica.state)
        #expect(payload.nodes[0].stackOrder == [.strokes, .effects, .fills])
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded.nodes[0].stackOrder == payload.nodes[0].stackOrder)
        let pasted = try #require(try replica.perform(Paste(decoded))).createdObjects[0]
        #expect(Self.shape(pasted, in: replica.state) == Self.shape(rect, in: replica.state))
    }

    @Test func aTreeWithoutAMatchingOrderStacksFillsStrokesThenEffects() throws {
        var replica = Replica(1)
        let rect = try Self.interleaved(&replica)
        var tree = NodeTree(rect, state: replica.state)
        tree.stackOrder = [.strokes]
        var builder = ChangeBuilder(replica: 9, startCounter: 1)
        let layer = try #require(Objects.parent(of: rect, in: replica.state))
        try NodeCopier.create(tree, parent: layer, position: [0x01], schema: replica.state.schema, builder: &builder)
        #expect(tree.stack?.map(\.list) == [.fills, .strokes, .effects])
        tree.stackOrder = nil
        #expect(tree.stack?.map(\.list) == [.fills, .strokes, .effects])
        // An effect attached to an element the tree does not hold is left at the object level.
        var orphan = tree
        orphan.props.rect.appearance.effects[0].attachedTo = Ops.elementID(OpID(counter: 999, replica: 9))
        guard case .effect(let effect)? = orphan.stack?.last else { Issue.record("effect"); return }
        #expect(!effect.hasAttachedTo)
        // A kind without a stack, or an empty stack, copies as before.
        #expect(NodeTree(props: Wiretuner_Doc_V1_NodeProps.with { $0.layer.common.name = "L" }).stack == nil)
        #expect(NodeTree(props: Wiretuner_Doc_V1_NodeProps.with { $0.rect.size.width = 1 }).stack == nil)
    }

    @Test func aPasteboardOrderWithAnUnknownListIsDropped() throws {
        var tree = NodeTree(props: Wiretuner_Doc_V1_NodeProps.with { $0.rect.size.width = 1 })
        tree.stackOrder = [.fills]
        let bytes = ClipboardPayload(nodes: [tree]).encoded()
        #expect(ClipboardPayload(decoding: bytes)?.nodes[0].stackOrder == [.fills])
        // Rewrite the order byte (list 1) as an unknown list 9.
        var patched = bytes
        let index = try #require(patched.lastIndex(of: 1))
        patched[index] = 9
        #expect(ClipboardPayload(decoding: patched)?.nodes[0].stackOrder == nil)
    }

    @Test func newKindsKeepTheirTransformsWhenCopied() {
        for kind in [NodeKind.text, .blend, .extrude, .image, .svgAnimation] {
            var tree = NodeTree(props: NodeValues.common(kind: kind) { $0.name = "n" })
            #expect(tree.kind == kind)
            tree.transform = .translation(x: 4, y: 5)
            #expect(tree.transform == .translation(x: 4, y: 5))
            tree.transform = .identity
            #expect(NodeValues.common(tree.props)?.hasTransform == false)
        }
    }
}
