import AppKit
import Foundation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Attribute stacks for test objects.
enum TestAppearance {
    /// A white fill under the default 1 pt black stroke: hit anywhere inside.
    static var filled: Wiretuner_Doc_V1_AppearanceProps {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 1, blue: 1)]
        return appearance
    }
}

extension DocumentHandle {
    /// Adds a rectangle per `rects` (pasteboard space) and waits until they are drawn; returns
    /// their ids in order.
    @discardableResult
    func addRectangles(_ rects: [Rect], filled: Bool = true) async -> [SelectionID] {
        var ids: [SelectionID] = []
        for rect in rects {
            let command = CreateShape(
                .rectangle(CornerRadii()), size: Size(width: rect.width, height: rect.height),
                transform: .translation(x: rect.minX, y: rect.minY), appearance: filled ? TestAppearance.filled : Appearances.standard
            )
            if let node = await perform(command).value?.createdObjects.first { ids.append(SelectionID(node)) }
        }
        await settle()
        return ids
    }

    /// Adds an open or closed path through `points` and waits until it is drawn.
    @discardableResult
    func addPath(_ points: [Point], closed: Bool = false, filled: Bool = false) async -> SelectionID? {
        let command = CreatePath(
            contours: [NewContour(closed: closed, points: points.map { VectorPoint(anchor: $0) })],
            appearance: filled ? TestAppearance.filled : Appearances.standard
        )
        let node = await perform(command).value?.createdObjects.first
        await settle()
        return node.map { SelectionID($0) }
    }

    /// The typed path of `id`, when it is a drawn path, rectangle or ellipse.
    func path(_ id: SelectionID) -> VectorPath? {
        object(for: id)?.path
    }
}

/// Many rectangles in one change on a new visible layer, for canvas performance tests: built
/// with a `DocumentCore` synchronously, so no actor hop per object.
struct DenseRectangles: WTModel.Command {
    struct Item {
        var rect: Rect
        /// A fill of this colour, or (nil) the default 1 pt black stroke.
        var fill: (red: Double, green: Double, blue: Double)?
    }

    let items: [Item]
    var label: String { "Dense" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var layer = Wiretuner_Doc_V1_NodeProps()
        layer.layer.visible = true
        let parent = builder.append(Ops.create(parent: WellKnown.layers, position: [0x80], props: layer))
        var previous: [UInt8]?
        for (index, item) in items.enumerated() {
            let position = try FractionalIndex.between(previous, nil, suffix: UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
            previous = position
            var props = Wiretuner_Doc_V1_NodeProps()
            props.rect.size.width = item.rect.width
            props.rect.size.height = item.rect.height
            props.rect.common.transform.a = 1
            props.rect.common.transform.d = 1
            props.rect.common.transform.tx = item.rect.minX
            props.rect.common.transform.ty = item.rect.minY
            let node = builder.append(Ops.create(parent: parent, position: position, props: props))
            var values = Wiretuner_Doc_V1_NodeProps()
            if let fill = item.fill {
                values.rect.appearance.fills = [Appearances.basicFill(red: fill.red, green: fill.green, blue: fill.blue)]
                builder.append(Ops.elementInsert(node, RegisterPath([21, 4, 1]), positions: [[0x80]], values: values))
            } else {
                values.rect.appearance.strokes = Appearances.standard.strokes
                builder.append(Ops.elementInsert(node, RegisterPath([21, 4, 2]), positions: [[0x80]], values: values))
            }
        }
    }

    /// A memory document holding `items`.
    @MainActor
    static func document(title: String, _ items: [Item]) throws -> DocumentHandle {
        var core = DocumentCore(state: EngineState(), replica: 0xD5)
        _ = try core.perform(DenseRectangles(items: items), recording: DocumentCore.Recording(limit: 1, now: Date()))
        return DocumentHandle(title: title, model: WTModel.Document(memory: core))
    }
}
