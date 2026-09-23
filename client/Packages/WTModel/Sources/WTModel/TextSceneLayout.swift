import WTCRDT
import WTRender
import WTText

/// How a scene lays out and draws its text nodes (creating-text, "Layout"): through one document's
/// `TextLayoutEngine` (`DocumentFontIndex.layoutEngine`), whose font and paragraph caches are
/// main-actor state.  `DocumentDisplayListBuilder` stays `Sendable` and builds wherever its owner
/// does; a builder given a `TextSceneLayout` must build on the main actor -- the app's document
/// does -- and one without (export, baking, previews) draws no text.  A font activation reaches
/// the drawn text through `DocumentDisplayListBuilder.invalidate` with the nodes
/// `DocumentFontIndex.fontsChanged` names.
public struct TextSceneLayout: @unchecked Sendable {
    /// The engine; only touched on the main actor.
    private let engine: TextLayoutEngine

    @MainActor
    public init(engine: TextLayoutEngine) {
        self.engine = engine
    }

    /// The display item of text node `node` (`TextLayoutReading.item`): its laid-out block in
    /// pasteboard space through the node's own transform; nil when it draws nothing.  Traps off
    /// the main actor.
    public func item(_ node: OpID, state: EngineState) -> DisplayItem? {
        MainActor.assumeIsolated { TextLayoutReading.item(node, in: state, engine: engine) }
    }
}
