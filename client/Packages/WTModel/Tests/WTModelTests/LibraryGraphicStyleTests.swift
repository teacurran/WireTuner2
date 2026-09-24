import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

enum StyleFixture {
    static let styles = GraphicStyleResolver.collection
    static let basedOn = RegisterPath([154, 4])
    static let behavior = RegisterPath([154, 5])
    static let objectStyle = RegisterPath([NodeKind.rect.rawValue, 1, 7])

    static func props(_ name: String, role: Wiretuner_Doc_V1_StyleRole = .unspecified, kind: Wiretuner_Doc_V1_StyleKind = .graphic,
                      behavior: [StyleCategory]? = nil, fill: Double? = nil, stroke: Double? = nil, halftone: Double? = nil) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = name
        props.style.role = role
        props.style.kind = kind
        let governed = behavior ?? StyleCategory.allCases
        props.style.behavior.fills = governed.contains(.fills)
        props.style.behavior.strokes = governed.contains(.strokes)
        props.style.behavior.effects = governed.contains(.effects)
        props.style.behavior.halftone = governed.contains(.halftone)
        if let fill { props.style.appearance.fills = [Appearances.basicFill(red: fill, green: 0, blue: 0)] }
        if let stroke { props.style.appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: stroke)] }
        if let halftone { props.style.common.halftone.frequency = halftone }
        return props
    }

    /// Creates styles (each its own position) on `replica`; returns their ids.
    static func create(_ list: [Wiretuner_Doc_V1_NodeProps], on replica: inout Replica) throws -> [OpID] {
        try replica.perform(CreateTrees(list.enumerated().map { (styles, [0x40, UInt8($0.offset + 1)], $0.element) }))!.createdNodes
    }

    static func setParent(_ style: OpID, _ parent: OpID?) -> Wiretuner_Doc_V1_Op {
        var values = Wiretuner_Doc_V1_NodeProps()
        if let parent { values.style.basedOn.id = parent.proto }
        return Ops.set(style, [basedOn], values: values)
    }

    /// A rectangle on `layer` using `style`, with its own fill when `fill` is given.
    static func object(on layer: OpID, style: OpID?, fill: Double? = nil, halftone: Bool = false, key: [UInt8] = [0x80])
        -> (OpID, [UInt8], Wiretuner_Doc_V1_NodeProps) {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.size.width = 10
        props.rect.size.height = 10
        if let style { props.rect.common.style.id = style.proto }
        if let fill { props.rect.appearance.fills = [Appearances.basicFill(red: fill, green: 1, blue: 0)] }
        if halftone { props.rect.common.halftone.frequency = 85 }
        return (layer, key, props)
    }
}

/// Creates node trees (sequences included, through `NodeCopier`) in one change.
struct CreateTrees: Command {
    var trees: [(parent: OpID, key: [UInt8], props: Wiretuner_Doc_V1_NodeProps)]
    var label: String { "Create" }

    init(_ trees: [(OpID, [UInt8], Wiretuner_Doc_V1_NodeProps)]) {
        self.trees = trees.map { (parent: $0.0, key: $0.1, props: $0.2) }
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for tree in trees {
            try NodeCopier.create(NodeTree(props: tree.props), parent: tree.parent, position: tree.key, schema: state.schema, builder: &builder)
        }
    }
}

@Suite struct LibraryGraphicStyleTests {
    @Test func chainsLoopsAndDanglingParents() throws {
        var a = Replica(0xA)
        let ids = try StyleFixture.create([StyleFixture.props("A"), StyleFixture.props("B"), StyleFixture.props("C"),
                                           StyleFixture.props("Text", kind: .paragraph), StyleFixture.props("Gone")], on: &a)
        let (sa, sb, sc, text, gone) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        try a.perform(OpsCommand("Loop", ops: [StyleFixture.setParent(sa, sb), StyleFixture.setParent(sb, sa), StyleFixture.setParent(sc, sb)]))
        var resolver = GraphicStyleResolver(a.state)
        // The loop A ↔ B is cut at A (the smaller id): A has no parent, B's parent is A.
        #expect(resolver.chain(of: sa) == [sa])
        #expect(resolver.chain(of: sb) == [sb, sa])
        #expect(resolver.chain(of: sc) == [sc, sb, sa])
        // A dangling, text, deleted or unknown parent reads as unset.
        try a.perform(OpsCommand("Parents", ops: [StyleFixture.setParent(sa, text), StyleFixture.setParent(sb, OpID(counter: 999, replica: 9)),
                                                  StyleFixture.setParent(sc, gone), Ops.setDeleted(gone)]))
        resolver.update(a.state)
        #expect(resolver.parent(of: sa) == nil && resolver.parent(of: sb) == nil && resolver.parent(of: sc) == nil)
        #expect(resolver.resolved(text) == nil && !resolver.isGraphic(text) && !resolver.isGraphic(OpID(counter: 5, replica: 5)))
        try a.perform(OpsCommand("Clear", ops: [StyleFixture.setParent(sa, nil)]))
        resolver.update(a.state)
        #expect(resolver.parent(of: sa) == nil)
        #expect(resolver.governs(OpID(counter: 5, replica: 5)).isEmpty)
    }

    @Test func behaviorMasksAndResolutionDownTheChain() throws {
        var a = Replica(0xA)
        let ids = try StyleFixture.create([
            StyleFixture.props("Root", fill: 0.5, stroke: 2, halftone: 60),
            StyleFixture.props("Child", behavior: [.strokes], fill: 0.9, stroke: 4),
            StyleFixture.props("None", behavior: []),
        ], on: &a)
        try a.perform(OpsCommand("Parent", ops: [StyleFixture.setParent(ids[1], ids[0]), StyleFixture.setParent(ids[2], ids[1])]))
        let resolver = GraphicStyleResolver(a.state)
        #expect(resolver.governs(ids[1]) == [.strokes])
        #expect(resolver.governs(ids[2]) == Set(StyleCategory.allCases))
        let child = try #require(resolver.resolved(ids[1]))
        // Child governs strokes only: its fill is ignored and the root's shows; its stroke wins.
        #expect(child.sources == [.fills: ids[0], .strokes: ids[1], .halftone: ids[0]])
        #expect(child.appearance.fills[0].settings.basic.color.inline.rgb.r == 0.5)
        #expect(child.appearance.strokes[0].settings.basic.width == 4)
        #expect(child.halftone?.frequency == 60)
        #expect(resolver.resolved(ids[2])?.chain == [ids[2], ids[1], ids[0]])
    }

    @Test func objectsResolveThroughTheirStyleAndOverrides() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        let ids = try StyleFixture.create([StyleFixture.props("Fills", behavior: [.fills], fill: 0.2),
                                           StyleFixture.props("Text", kind: .character)], on: &a)
        let change = try a.perform(CreateTrees([
            StyleFixture.object(on: layer, style: ids[0], key: [0x81]),
            StyleFixture.object(on: layer, style: ids[0], fill: 0.7, halftone: true, key: [0x82]),
            StyleFixture.object(on: layer, style: nil, key: [0x83]),
            StyleFixture.object(on: layer, style: ids[1], key: [0x84]),
            StyleFixture.object(on: layer, style: layer, key: [0x85]),
        ]))!
        let objects = change.createdNodes
        var resolver = GraphicStyleResolver(a.state)
        let plain = resolver.effective(of: objects[0], in: a.state)
        #expect(plain.style == ids[0] && plain.overridden.isEmpty)
        #expect(plain.sources == [.fills: .style(ids[0]), .strokes: .defaults, .effects: .defaults, .halftone: .defaults])
        #expect(plain.appearance.fills[0].settings.basic.color.inline.rgb.r == 0.2)
        // No defaults set: the built-in 1 pt black stroke.
        #expect(plain.appearance.strokes == Appearances.standard.strokes && plain.halftone == nil)
        let overridden = resolver.effective(of: objects[1], in: a.state)
        #expect(overridden.overridden == [.fills])
        #expect(overridden.sources[.halftone] == .own && overridden.halftone?.frequency == 85)
        #expect(overridden.appearance.fills[0].settings.basic.color.inline.rgb.r == 0.7)
        // No style, a text style, a non-style node: unset.
        #expect(resolver.effective(of: objects[2], in: a.state).style == nil)
        #expect(resolver.style(of: objects[3], in: a.state) == nil)
        #expect(resolver.style(of: objects[4], in: a.state) == nil)
        #expect(resolver.index(in: a.state) == [ids[0]: [objects[0], objects[1]]])
        // A removed style still present resolves through its registers.
        try a.perform(OpsCommand("Remove", ops: [Ops.setDeleted(ids[0])]))
        resolver.update(a.state)
        #expect(resolver.effective(of: objects[0], in: a.state).sources[.fills] == .style(ids[0]))
        #expect(!resolver.isLive(ids[0]))
        // Document defaults apply where nothing else does.
        var defaults = Wiretuner_Doc_V1_NodeProps()
        defaults.settings.defaults.appearance.fills = [Appearances.basicFill(red: 0, green: 0, blue: 1)]
        try a.perform(OpsCommand("Defaults", ops: [Ops.elementInsert(WellKnown.settings, RegisterPath([2, 10, 1, 1]), positions: [[0x80]], values: defaults)]))
        resolver.update(a.state)
        let fallback = resolver.effective(of: objects[2], in: a.state)
        #expect(fallback.sources[.fills] == .defaults && fallback.appearance.fills.count == 1 && fallback.appearance.strokes.isEmpty)
    }

    @Test func duplicateRolesAndDeletedNormal() throws {
        var a = Replica(0xA)
        let ids = try StyleFixture.create([StyleFixture.props("Normal", role: .normal), StyleFixture.props("Normal 2", role: .normal),
                                           StyleFixture.props("Normal Text", role: .normalText, kind: .paragraph),
                                           StyleFixture.props("Other Text", role: .normalText, kind: .paragraph)], on: &a)
        try a.perform(OpsCommand("Delete Normal", ops: [Ops.setDeleted(ids[0]), Ops.setDeleted(ids[1])]))
        let resolver = GraphicStyleResolver(a.state)
        #expect(resolver.normal == ids[0] && resolver.normalText == ids[2])
        #expect(resolver.role(of: ids[0]) == .normal && resolver.role(of: ids[1]) == .unspecified)
        #expect(resolver.role(of: ids[2]) == .normalText && resolver.role(of: ids[3]) == .unspecified)
        #expect(resolver.role(of: OpID(counter: 9, replica: 9)) == .unspecified)
        #expect(resolver.isLive(ids[0]) && !resolver.isLive(ids[1]) && !resolver.isLive(OpID(counter: 9, replica: 9)))
    }

    @Test func aRedefineRebuildsOnlyTheStyleAndItsDescendants() throws {
        var a = Replica(0xA)
        let ids = try StyleFixture.create([StyleFixture.props("Root"), StyleFixture.props("Child"), StyleFixture.props("Other")], on: &a)
        try a.perform(OpsCommand("Parent", ops: [StyleFixture.setParent(ids[1], ids[0])]))
        var resolver = GraphicStyleResolver(a.state)
        #expect(resolver.rebuilt == 3)
        resolver.update(a.state)
        #expect(resolver.rebuilt == 0)
        var values = Wiretuner_Doc_V1_NodeProps()
        values.style.behavior.fills = false
        try a.perform(OpsCommand("Redefine", ops: [Ops.set(ids[0], [StyleFixture.behavior.child(1)], values: values)]))
        resolver.update(a.state)
        #expect(resolver.rebuilt == 2)
    }

    /// The full volume in a perf run; 2,000 objects otherwise.
    static let count = PerfBudget.isMeasuring ? 50_000 : 2_000

    @Test func resolvingFiftyThousandObjectsAfterARedefine() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["L"], on: &a)[0]
        // 200 styles: 20 chains of 10.
        var list: [Wiretuner_Doc_V1_NodeProps] = []
        for index in 0..<200 { list.append(StyleFixture.props("S\(index)", fill: Double(index % 10) / 10, stroke: index % 3 == 0 ? 1 : nil)) }
        let styles = try StyleFixture.create(list, on: &a)
        try a.perform(OpsCommand("Chains", ops: styles.indices.filter { $0 % 10 != 0 }.map { StyleFixture.setParent(styles[$0], styles[$0 - 1]) }))
        let keys = try PathEditing.keys(between: nil, and: nil, count: Self.count)
        for start in stride(from: 0, to: Self.count, by: 5_000) {
            let ops = (start..<min(start + 5_000, Self.count)).map { index in
                StyleFixture.object(on: layer, style: styles[index % 200], fill: index % 10 == 0 ? 0.3 : nil, key: keys[index])
            }
            try a.perform(CreateTrees(ops))
        }
        let objects = a.state.liveChildren(layer)
        var resolver = GraphicStyleResolver(a.state)
        var values = Wiretuner_Doc_V1_NodeProps()
        values.style.behavior.strokes = false
        try a.perform(OpsCommand("Redefine", ops: [Ops.set(styles[0], [StyleFixture.behavior.child(2)], values: values)]))
        let clock = ContinuousClock()
        var own = 0
        let elapsed = clock.measure {
            resolver.update(a.state)
            for object in objects where resolver.sources(of: object, in: a.state).sources[.fills] == .own { own += 1 }
        }
        #expect(resolver.rebuilt == 10)
        #expect(own == Self.count / 10)
        PerfBudget.expect(elapsed, within: .milliseconds(20), "resolve \(Self.count) objects across 200 styles after one redefine")
    }
}
