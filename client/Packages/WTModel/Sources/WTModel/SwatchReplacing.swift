import WTCRDT
import WTProto

/// The Swatches panel's *Replace…* (editing-colors.adoc, "Replacing a color"; COLOR-015), one
/// change labelled `Replace "Grape" with "Plum"`.
///
/// * From the colour list (A → B): every live reference to A -- fill, stroke, gradient stop,
///   effect colour and text mark, as a swatch reference or an unnamed tint's base -- is rewritten
///   to B with B's colour cached; tint swatches of A are re-based onto B (`parent`); A is deleted.
///   A reference written concurrently by someone else dangles and draws A's cached colour.
///   Colours inside ATOMIC messages are not rewritable one by one and keep naming A (they dangle
///   to their cache, as after *Remove*).
/// * From a library: A takes the library colour's value, name, kind (`spot`) and origin
///   (`library`, `library_key`) in one `SetFields`; a tint swatch stops being a tint.  Everything
///   using A follows because it is the same swatch.
///
/// White, Black and Registration are refused (`SwatchError.protected`); *None* is not a swatch.
public struct ReplaceSwatch: Command {
    public enum Source: Hashable, Sendable {
        /// Another swatch of this document.
        case swatch(OpID)
        /// A colour of a colour library; `origin` is what the swatch's `library` records.
        case library(Wiretuner_Lib_V1_LibraryColor, origin: String)
    }

    public var swatch: OpID
    public var source: Source
    /// The panel's index, when it has one (read instead of indexing the document again).
    public var index: SwatchIndex?
    public let label: String

    public init(_ swatch: OpID, with source: Source, in state: EngineState, index: SwatchIndex? = nil) {
        self.swatch = swatch
        self.source = source
        self.index = index
        let list = index?.list ?? SwatchList(state)
        let from = list[swatch]?.plainName ?? "color"
        let to: String = switch source {
        case .swatch(let id): list[id]?.plainName ?? "color"
        case .library(let color, _): color.name.isEmpty ? color.key : color.name
        }
        label = "Replace \(Swatches.quoted(from)) with \(Swatches.quoted(to))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = index?.list ?? SwatchList(state)
        let original = try Swatches.ordinary(swatch, list)
        switch source {
        case .swatch(let target):
            try replace(original, with: target, list: list, state: state, builder: &builder)
        case .library(let color, let origin):
            replace(original, with: color, origin: origin, list: list, builder: &builder)
        }
    }

    private func replace(_ original: Swatch, with target: OpID, list: SwatchList, state: EngineState, builder: inout ChangeBuilder) throws {
        _ = try Swatches.live(target, list)
        // B must not be A or a tint of A: re-basing A's tints onto B would make B its own base.
        var base: OpID? = target
        while let current = base {
            if current == original.id { throw SwatchError.loop(target) }
            base = list[current]?.base
        }
        let index = self.index ?? SwatchIndex(state)
        let replacement = list.resolver.nodeRef(target)
        for use in index.liveDependents(of: original.id, in: state) {
            switch use.location {
            case .tintBase:
                builder.append(Ops.set(use.node, [SwatchFields.parent], values: SwatchFields.values { $0.parent = replacement }))
            case .register(let path) where !ColorRegisterWalker.isLive(path, of: use.node, in: state):
                continue
            case .register, .mark:
                var ref = use.ref
                switch ref.ref {
                case .swatch?: ref.swatch = replacement
                case .tint(var tint)?:
                    tint.base = replacement
                    ref.tint = tint
                default: continue
                }
                if let op = ColorRegisterWalker.write(ref, at: use, in: state) { builder.append(op) }
            case .nested:
                continue
            }
        }
        builder.append(Ops.setDeleted(original.id))
    }

    private func replace(_ original: Swatch, with color: Wiretuner_Lib_V1_LibraryColor, origin: String, list: SwatchList,
                         builder: inout ChangeBuilder) {
        let base = ColorValues.color(color.value)
        let resolved = ColorLibraries.isTint(color) ? base.tinted(ColorResolver.percent(color.tintPercent) / 100) : base
        var paths = [SwatchFields.value, SwatchFields.spot, SwatchFields.library, SwatchFields.libraryKey]
        if original.isTint { paths += [SwatchFields.parent, SwatchFields.tintPercent] }
        let name = Swatches.clean(color.name.isEmpty ? color.key : color.name)
        if !name.isEmpty, !list.isTaken(name, except: original.id) { paths.append(SwatchFields.name) }
        builder.append(Ops.set(original.id, paths, values: SwatchFields.values { props in
            props.value = ColorValues.stored(resolved)
            props.spot = color.spot
            props.library = String(origin.prefix(SwatchFields.maxLabel))
            props.libraryKey = String(color.key.prefix(SwatchFields.maxLabel))
            props.common.name = name
        }))
    }
}
