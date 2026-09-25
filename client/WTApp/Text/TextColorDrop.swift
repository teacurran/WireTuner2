import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Colours dropped on text (text-color.adoc, "Dropping color on text"; TYPE-030): on a block the
/// Text tool has a selection in, the characters take it (a `fill` mark); otherwise a drop on the
/// block's border colours its stroke and one inside it its fill (`block_appearance`, adding the
/// row when the block has none).  Every other drop is the canvas colour drop's.  One change.
@MainActor
struct TextColorDrop {
    /// Where a drop on text goes.
    enum Target: Equatable {
        case characters(node: OpID, range: Range<Int>)
        case border(OpID)
        case interior(OpID)
    }

    let window: DocumentWindowController

    /// The text target under `viewPoint`, nil when no text block is there.
    func target(at viewPoint: Point) -> Target? {
        let hits = window.selection.hitTester(viewport: window.viewport, subselect: false).hitTest(viewPoint: viewPoint)
        let state = window.documentHandle.state
        for hit in hits {
            guard let id = window.documentHandle.selectionID(atItemPath: hit.itemPath) else { continue }
            guard state.nodeKind(id.opID) == .text else { return nil }
            if let session = window.objectEditing.textSession, session.node == id.opID, !session.selectedRange.isEmpty {
                return .characters(node: id.opID, range: session.selectedRange)
            }
            if case .stroke = hit.kind { return .border(id.opID) }
            return .interior(id.opID)
        }
        return nil
    }

    /// The command writing `color` at `target`.
    static func command(_ target: Target, color: Wiretuner_Doc_V1_ColorRef, in state: EngineState) -> (any WTModel.Command)? {
        switch target {
        case .characters(let node, let range):
            guard let text = state.textNode(node), range.upperBound <= text.length else { return nil }
            return TextColor.fill(node: node, from: text.anchor(at: range.lowerBound), to: text.anchor(at: range.upperBound), color)
        case .border(let node), .interior(let node):
            let list: AppearanceList = if case .border = target { .strokes } else { .fills }
            if let row = TextBlockAppearance.rows(node, in: state).last(where: { $0.list == list }) {
                return SetTextBlockAppearance.color(node: node, row: row, color)
            }
            if list == .strokes {
                var stroke = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)
                stroke.settings.basic.color = color
                return AddTextBlockAppearance.stroke(node, stroke)
            }
            var fill = Appearances.basicFill(red: 0, green: 0, blue: 0)
            fill.settings.basic.color = color
            return AddTextBlockAppearance.fill(node, fill)
        }
    }

    /// The drop: false when no text is under the pointer or the pasteboard holds no colour.
    func drop(_ pasteboard: NSPasteboard, at viewPoint: Point, defaultSpace: RenderColor.Space = .displayP3) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let payload = ColorDrag.read(from: pasteboard, defaultSpace: defaultSpace), let target = target(at: viewPoint) else { return nil }
        let document = window.documentHandle
        let editing = window.objectEditing
        return Task { @MainActor in
            let ref = await ColorDrop.reference(for: payload, in: document)
            guard let command = Self.command(target, color: ref, in: document.state) else { return nil }
            return await editing.perform(command).value
        }
    }
}
