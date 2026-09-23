import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Helpers of the colour tests (COLOR-002 onwards).
enum ColorFixture {
    /// The nodes `change` created, in op order.
    static func created(_ change: Wiretuner_Doc_V1_Change?) -> [OpID] {
        guard let change else { return [] }
        var ids: [OpID] = []
        var counter = change.startCounter
        for op in change.ops {
            if case .create? = op.op { ids.append(OpID(counter: counter, replica: change.replica)) }
            counter &+= EngineState.counters(op)
        }
        return ids
    }

    /// Adds a swatch on `replica` and returns its id.
    @discardableResult
    static func add(_ replica: inout Replica, _ color: Color, name: String = "", spot: Bool = false, group: String = "") throws -> OpID {
        created(try replica.perform(AddSwatch(color, name: name, spot: spot, group: group)))[0]
    }

    /// Adds a tint swatch on `replica` and returns its id.
    @discardableResult
    static func tint(_ replica: inout Replica, of base: OpID, _ percent: Double, name: String = "") throws -> OpID {
        created(try replica.perform(AddTintSwatch(of: base, percent: percent, name: name)))[0]
    }

    /// A closed square path filled with `fill` and no stroke; returns the path's id.
    @discardableResult
    static func shape(_ replica: inout Replica, fill: Wiretuner_Doc_V1_ColorRef, stroke: Wiretuner_Doc_V1_ColorRef? = nil) throws -> OpID {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        if let stroke {
            var basic = Wiretuner_Doc_V1_Stroke()
            basic.settings.kind = .basic
            basic.settings.basic.color = stroke
            basic.settings.basic.width = 1
            appearance.strokes = [basic]
        }
        var basic = Wiretuner_Doc_V1_Fill()
        basic.settings.kind = .basic
        basic.settings.basic.color = fill
        appearance.fills = [basic]
        let command = CreatePath(contours: [NewContour(closed: true, points: [0, 1, 2, 3].map { i in
            VectorPoint(anchor: Point(x: Double(i % 2) * 10, y: Double(i / 2) * 10))
        })], appearance: appearance)
        return try replica.perform(command)!.createdObjects[0]
    }

    /// A text block "Hi" with a size mark and a glyph-fill mark of `fill`; returns its id.
    @discardableResult
    static func markedText(_ replica: inout Replica, fill: Wiretuner_Doc_V1_ColorRef) throws -> OpID {
        let block = created(try replica.perform(OpsCommand("Text", ops: [Ops.create(parent: OpID.wellKnown(4), position: [0x80], props: Fixture.textBlock())])))[0]
        try replica.perform(OpsCommand("Type", ops: [Ops.textInsert(block, Fixture.text, "Hi")]))
        func mark(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Wiretuner_Doc_V1_Op {
            var mark = Wiretuner_Doc_V1_TextMark()
            mark.node = block.proto
            mark.text = Fixture.text.proto
            mark.start.char = Ops.elementID(OpID(counter: block.counter + 1, replica: block.replica))
            mark.start.before = true
            mark.end.char = Ops.elementID(OpID(counter: block.counter + 2, replica: block.replica))
            mark.value = value
            var op = Wiretuner_Doc_V1_Op()
            op.textMark = mark
            return op
        }
        var size = Wiretuner_Doc_V1_TextMarkValue()
        size.size = 12
        var color = Wiretuner_Doc_V1_TextMarkValue()
        color.fill = fill
        try replica.perform(OpsCommand("Marks", ops: [mark(size), mark(color)]))
        return block
    }

    /// The first fill's colour reference of `node`.
    static func fill(_ node: OpID, _ state: EngineState) -> Wiretuner_Doc_V1_ColorRef {
        state.props(node).path.appearance.fills.first?.settings.basic.color ?? Wiretuner_Doc_V1_ColorRef()
    }

    /// The first fill's row of `node`.
    static func fillRow(_ node: OpID, _ state: EngineState) -> AppearanceRow {
        AppearanceRow(.fills, AppearanceEditing.rows(node, .fills, in: state)[0])
    }

    /// The register path of the first fill's colour.
    static func fillPath(_ node: OpID, _ state: EngineState) -> RegisterPath {
        ColorUses.uses(of: node, in: state).first { if case .register = $0.location { return true } else { return false } }.map {
            guard case .register(let path) = $0.location else { fatalError() }
            return path
        }!
    }

    static let grape = Color(cyan: 0.5, magenta: 0.8, yellow: 0, black: 0.1)
    static let plum = Color(cyan: 0.2, magenta: 0.9, yellow: 0.1, black: 0.3)
    static let red = Color(red: 230.0 / 255, green: 57.0 / 255, blue: 70.0 / 255)
}

/// Components compare within `tolerance`.
func close(_ a: Color?, _ b: Color?, _ tolerance: Double = 1e-9) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    let d = a.components - b.components
    return a.space == b.space && max(abs(d.x), abs(d.y), abs(d.z), abs(d.w)) <= tolerance && a.spot == b.spot
}
