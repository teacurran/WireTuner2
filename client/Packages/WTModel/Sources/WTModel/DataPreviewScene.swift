import Foundation
import WTCRDT
import WTProto
import WTRender
import WTText

// DATA-016 (model half): the preview on the canvas.  `DocumentDisplayListBuilder.substitution`
// draws placeholders with a record's values, bound barcodes with the bound value and skips
// objects a visibility binding hides; setting it invalidates only the nodes that read a field.

/// Drawing with a record applied.
public enum DataPreviewScene {
    /// The display item of text node `node` with `substitution` applied (placeholders replaced
    /// before layout), as `TextLayoutReading.item` draws the stored text.
    @MainActor
    public static func item(_ node: OpID, in state: EngineState, engine: TextLayoutEngine, substitution: RecordSubstitution) -> DisplayItem? {
        guard let text = TextNode(node, in: state) else { return nil }
        let colors = ColorResolver.current ?? ColorResolver(state)
        let layout = engine.layout(substitution.content(text, state: state, colors: colors), in: [TextLayoutReading.container(text)])
        let items = layout.displayItems(forContainer: 0)
        return items.isEmpty ? nil : .group(GroupItem(children: items))
    }

    /// The nodes whose drawing depends on the record: text nodes with placeholders or a binding,
    /// bound barcodes and every node with a visibility binding.
    public static func dependentNodes(in state: EngineState) -> Set<OpID> {
        var nodes: Set<OpID> = []
        for node in DataBindings.liveNodes(in: state) {
            if DataBindings.stored(state.props(node)) != nil {
                nodes.insert(node)
            } else if let text = TextNode(node, in: state), !DataModel.placeholderRuns(text).isEmpty {
                nodes.insert(node)
            }
        }
        return nodes
    }
}

extension DocumentDisplayListBuilder {
    /// Turns the preview on (a record), steps it, or turns it off (nil): a view invalidation of
    /// the nodes that read a field -- no op is written, so the outbox stays empty.
    public mutating func preview(_ substitution: RecordSubstitution?, state: EngineState) -> (DocumentScene, ChangeSummary) {
        self.substitution = substitution
        return invalidate(DataPreviewScene.dependentNodes(in: state), state: state)
    }
}
