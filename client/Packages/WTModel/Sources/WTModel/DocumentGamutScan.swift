import WTCRDT
import WTInterchange
import WTRender

/// CMS-015's document gamut scan (color-profiles.adoc, "Client"; `WTColor.OutputContext.widestSpaceUsed`):
/// how far the document's resolved colours reach -- every colour use of every live object
/// (fills, strokes, gradient stops, effects, text marks; `ColorUses`) resolved through the
/// swatches -- kept as the reach of each node whose colours go beyond sRGB.  The scan is cached
/// and invalidated by the `SwatchIndex`: a change re-resolves the nodes it names, and a change to a
/// swatch re-resolves every use the dependents index lists for it (through tint swatches to their
/// own users), so recolouring a swatch -- *Convert to sRGB* on it, say -- moves the reach without a
/// full scan.  Liveness is read when asked, so deleting a group or a layer takes its colours out.
/// Swatches themselves are not scanned: an unused wide swatch draws nothing.
public struct DocumentGamutScan: Sendable {
    public typealias Reach = WTColor.OutputContext.GamutReach

    /// The reach of each node with a colour outside sRGB (live or not).
    private var wide: [OpID: Reach] = [:]

    /// The scan of `state`, read in full through `index` (which must be `state`'s).
    public init(_ state: EngineState, index: SwatchIndex) {
        let resolver = ColorResolver(state)
        for node in index.nodesWithUses { scan(node, in: state, index: index, resolver: resolver) }
    }

    /// Updates the scan for a change the document applied, after `index` took it.
    public mutating func apply(_ event: DocumentEvent, index: SwatchIndex) {
        guard event.origin != .reload else {
            self = DocumentGamutScan(event.after, index: index)
            return
        }
        refresh(ColorUses.touched(by: event.change), in: event.after, index: index)
    }

    /// Re-resolves `nodes` and every use that reads a colour through a swatch among them.
    public mutating func refresh(_ nodes: Set<OpID>, in state: EngineState, index: SwatchIndex) {
        var affected = nodes
        var swatches = nodes.filter { state.store.kind($0) == SwatchFields.kind }.sorted()
        while let swatch = swatches.popLast() {
            for use in index.dependents(of: swatch) where affected.insert(use.node).inserted && use.location == .tintBase {
                swatches.append(use.node)
            }
        }
        let resolver = ColorResolver(state)
        for node in affected { scan(node, in: state, index: index, resolver: resolver) }
    }

    private mutating func scan(_ node: OpID, in state: EngineState, index: SwatchIndex, resolver: ColorResolver) {
        let colors = state.store.kind(node) == SwatchFields.kind ? [] : index.uses(on: node).compactMap { resolver.color($0.ref) }
        let reach = WTColor.OutputContext.widestSpace(of: colors)
        wide[node] = reach > .sRGB ? reach : nil
    }

    /// How far the live objects' colours reach.
    public func widestSpaceUsed(in state: EngineState) -> Reach {
        var widest = Reach.sRGB
        for (node, reach) in wide where reach > widest && state.isEffectivelyLive(node) {
            widest = reach
        }
        return widest
    }
}
