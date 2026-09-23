import WTCRDT
import WTProto
import WTRender

/// Which spot ink each swatch stands for (spot-process.adoc, tints.adoc; PRINT-007): the render
/// side carries resolved colours only, so a colour resolved from a spot swatch keeps the ink's
/// identity on `Color.spot` and a separation puts it on the ink's own plate.
///
/// A swatch is spot when the base at the end of its `parent` chain is spot (a tint's own `spot`
/// register is ignored); the ink is that base, named by its `CommonProps.name`, at the product of
/// the chain's `tint_percent`s (unset or zero reads as 100%).  A chain that loops, or runs through
/// a deleted or non-swatch node, reads as process (its cached colour), as the tint resolver does
/// for a dangling base.  The Registration swatch (`SWATCH_ROLE_REGISTRATION`) resolves to
/// `Color.registration` (100% on every plate).  Resolution happens while `DocumentDisplayListBuilder`
/// builds (`SpotInks.current`); outside a build, swatches resolve to their cached colours alone.
public struct SpotInks: Hashable, Sendable {
    public enum Resolution: Hashable, Sendable {
        case ink(SpotInk)
        case registration
    }

    /// Swatch → its ink; process swatches are absent.
    public let swatches: [OpID: Resolution]

    public init(swatches: [OpID: Resolution] = [:]) {
        self.swatches = swatches
    }

    /// Reads every swatch under the well-known `swatches` node (and its groups).
    public init(_ state: EngineState) {
        var props: [OpID: Wiretuner_Doc_V1_SwatchProps] = [:]
        var pending = [WellKnown.swatches]
        while let next = pending.popLast() {
            for child in state.liveChildren(next) {
                if case .swatch(let swatch)? = state.props(child).kind {
                    props[child] = swatch
                }
                pending.append(child)
            }
        }
        var result: [OpID: Resolution] = [:]
        for (id, swatch) in props {
            if let resolution = Self.resolve(id, swatch, in: props) {
                result[id] = resolution
            }
        }
        swatches = result
    }

    private static func resolve(_ id: OpID, _ swatch: Wiretuner_Doc_V1_SwatchProps, in props: [OpID: Wiretuner_Doc_V1_SwatchProps]) -> Resolution? {
        var current = (id: id, swatch: swatch)
        var visited: Set<OpID> = [id]
        var tint = 1.0
        while current.swatch.hasParent {
            let percent = current.swatch.tintPercent
            tint *= percent > 0 && percent.isFinite ? min(percent, 100) / 100 : 1
            let parent = OpID(current.swatch.parent.id)
            guard let base = props[parent], visited.insert(parent).inserted else { return nil }
            current = (parent, base)
        }
        if current.swatch.role == .registration {
            return .registration
        }
        guard current.swatch.spot else { return nil }
        return .ink(SpotInk(swatch: NodeID(current.id), name: current.swatch.common.name, tint: tint))
    }

    /// `color` (a swatch's resolved colour) as `swatch`'s ink, when it is spot or Registration,
    /// at `amount` of the swatch's tint.
    public func color(_ color: Color, swatch: OpID, amount: Double = 1) -> Color {
        switch swatches[swatch] {
        case .ink(let ink)?: return color.asSpot(ink.tinted(amount))
        case .registration?: return amount >= 1 ? .registration : color.asSpot(SpotInk.registration.tinted(amount))
        case nil: return color
        }
    }

    /// The table in force while a scene is built.
    @TaskLocal public static var current = SpotInks()
}
