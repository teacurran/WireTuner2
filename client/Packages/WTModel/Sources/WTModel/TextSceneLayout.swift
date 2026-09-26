import WTCRDT
import WTGeometry
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

    /// The text overrides `instance` draws (LIB-025/026; library.adoc, "Override resolution"):
    /// each text block of `artwork` whose text a live `TEXT` override supplies, laid out from the
    /// override's characters, marks and paragraph registers in the master block's geometry (its
    /// block, inset, columns and transform) and placed through the groups between it and the
    /// symbol, so the items are in symbol space as the master's are; with the nodes that drawing
    /// reads (`TextLayoutReading.sources` of each master).  Traps off the main actor.
    public func overrides(of instance: OpID, artwork: ResolvedArtwork?, state: EngineState) -> (overrides: [InstanceOverride], sources: [OpID]) {
        guard let artwork else { return ([], []) }
        var overrides: [InstanceOverride] = []
        var sources: [OpID] = []
        for master in artwork.textBlocks {
            guard let resolved = artwork.texts[master], resolved.isOverride, let element = resolved.element,
                  let text = TextNode(master, text: instance, field: SymbolFields.overrideText(element), in: state) else { continue }
            let parent = state.store.placement(master)?.parent
            let groups = parent.flatMap { Symbols.symbolSpaceTransform(of: $0, in: artwork.symbol, state: state) } ?? .identity
            let item = MainActor.assumeIsolated { TextLayoutReading.item(text, in: state, engine: engine) }
            overrides.append(.text(NodeID(master), item.map { [$0.transformed(by: groups)] } ?? []))
            sources += TextLayoutReading.sources(master, in: state)
        }
        return (overrides, sources)
    }

    /// `item(_:state:)` with a data-merge record applied (`RecordSubstitution`; nil draws the
    /// text as stored).
    public func item(_ node: OpID, state: EngineState, substitution: RecordSubstitution?) -> DisplayItem? {
        guard let substitution else { return item(node, state: state) }
        return MainActor.assumeIsolated { DataPreviewScene.item(node, in: state, engine: engine, substitution: substitution) }
    }
}
