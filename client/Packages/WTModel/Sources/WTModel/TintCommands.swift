import WTCRDT
import WTProto
import WTRender

/// Adds a named tint of `base` (tints.adoc; COLOR-009): a swatch with `parent` set (its cache
/// the base's colour now) and `tint_percent`, listed under its base.  An empty name shows the
/// derived `40% Grape`, which follows renames of the base with no write.
public struct AddTintSwatch: Command {
    public var base: OpID
    public var percent: Double
    public var name: String

    public init(of base: OpID, percent: Double, name: String = "") {
        self.base = base
        self.percent = percent
        self.name = name
    }

    public var label: String { "Add tint" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let base = try Swatches.live(self.base, list)
        let name = Swatches.clean(self.name)
        if !name.isEmpty, list.isTaken(name) {
            throw SwatchError.nameTaken(name)
        }
        let after = list.tints(of: base.id).last ?? base.id
        builder.append(Swatches.create({ swatch in
            swatch.common.name = name
            swatch.parent = list.resolver.nodeRef(base.id)
            swatch.tintPercent = ColorResolver.percent(percent)
        }, at: try Swatches.position(after: after, in: state)))
    }
}

/// Sets a tint swatch's percentage (1...100).
public struct SetTintPercent: Command {
    public var tint: OpID
    public var percent: Double

    public init(_ tint: OpID, percent: Double) {
        self.tint = tint
        self.percent = percent
    }

    public var label: String { "Set tint percentage" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let swatch = try Tints.tint(tint, SwatchList(state))
        let percent = ColorResolver.percent(percent)
        guard swatch.props.tintPercent != percent else { return }
        builder.append(Ops.set(tint, [SwatchFields.tintPercent], values: SwatchFields.values { $0.tintPercent = percent }))
    }
}

/// Re-bases a tint swatch onto another swatch (the Tints panel's kbd:[Option]-drop), caching
/// the new base's colour.  Refused onto the tint itself or one of its own tints; a loop only
/// arises from concurrent re-basing, and the resolver cuts it.
public struct RebaseTint: Command {
    public var tint: OpID
    public var base: OpID

    public init(_ tint: OpID, onto base: OpID) {
        self.tint = tint
        self.base = base
    }

    public var label: String { "Re-base tint" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let swatch = try Tints.tint(tint, list)
        _ = try Swatches.live(base, list)
        guard base != tint, !list.tints(of: tint).contains(base) else { throw SwatchError.loop(base) }
        guard swatch.base != base || swatch.baseRemoved else { return }
        builder.append(Ops.set(tint, [SwatchFields.parent], values: SwatchFields.values { $0.parent = list.resolver.nodeRef(base) }))
    }
}

/// Turns a tint swatch into a colour of the colour it shows (tints.adoc, "`value` on a tint"):
/// `parent` and the percentage cleared and `value` written in the same change, with the base's
/// spot flag.  A tint showing its derived name keeps it as a stored name.
public struct FlattenTint: Command {
    public var tint: OpID

    public init(_ tint: OpID) {
        self.tint = tint
    }

    public var label: String { "Flatten tint" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let swatch = try Tints.tint(tint, SwatchList(state))
        var paths = [SwatchFields.parent, SwatchFields.tintPercent, SwatchFields.value, SwatchFields.spot]
        let values = SwatchFields.values { props in
            props.value = ColorValues.stored(swatch.color)
            props.spot = swatch.isSpot
            if swatch.props.common.name.isEmpty {
                props.common.name = swatch.plainName
            }
        }
        if swatch.props.common.name.isEmpty {
            paths.append(SwatchFields.name)
        }
        builder.append(Ops.set(tint, paths, values: values))
    }
}

enum Tints {
    /// The live, unprotected tint swatch `id`.
    static func tint(_ id: OpID, _ list: SwatchList) throws -> Swatch {
        let swatch = try Swatches.ordinary(id, list)
        guard swatch.isTint else { throw SwatchError.notATint(id) }
        return swatch
    }
}

/// *Make Spot* / *Make Process* (spot-process.adoc; COLOR-005): writes `spot` on each selected
/// colour.  Protected swatches keep their roles' kinds and tints follow their bases, so both are
/// skipped; a swatch already of that kind is not written.
public struct SetSwatchSpot: Command {
    public var swatches: [OpID]
    public var spot: Bool

    public init(_ swatches: [OpID], spot: Bool) {
        self.swatches = swatches
        self.spot = spot
    }

    public var label: String { spot ? "Make Spot" : "Make Process" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        for id in swatches {
            let swatch = try Swatches.live(id, list)
            guard !swatch.isProtected, !swatch.isTint, swatch.props.spot != spot else { continue }
            builder.append(Ops.set(id, [SwatchFields.spot], values: SwatchFields.values { $0.spot = spot }))
        }
    }
}

/// *Convert to* sRGB, Display P3 or CMYK (spot-process.adoc; COLOR-005): one write of each
/// colour's `value` in the target space -- sRGB and Display P3 through the CSS Color 4 gamut
/// mapping (`WTColor.Gamut`), CMYK through the conversion protocol.  Tints of a converted base
/// need no write.  A swatch still named by its values is renamed with them when `autoRename`.
public struct ConvertSwatchSpace: Command {
    public var swatches: [OpID]
    public var target: Color.Space
    public var autoRename: Bool
    public var converter: any ColorConverting
    /// The name for a one-swatch label.
    public var name: String

    public init(_ swatches: [OpID], to target: Color.Space, autoRename: Bool = true, converter: any ColorConverting = FormulaColorConversion(),
                name: String = "") {
        self.swatches = swatches
        self.target = target
        self.autoRename = autoRename
        self.converter = converter
        self.name = name
    }

    /// The *Convert to* targets, in menu order.
    public static let targets: [Color.Space] = [.sRGB, .displayP3, .cmyk]

    /// The target's menu name.
    public static func title(_ space: Color.Space) -> String {
        switch space {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .cmyk: return "CMYK"
        case .lab: return "Lab"
        case .oklab: return "OKLab"
        }
    }

    /// Whether the *Convert to* item for `target` is enabled for `swatch`: a named colour (not a
    /// tint), unprotected, not already in `target`.
    public static func canConvert(_ swatch: Swatch, to target: Color.Space) -> Bool {
        targets.contains(target) && !swatch.isProtected && !swatch.isTint && swatch.value.space != target
    }

    public var label: String {
        swatches.count == 1 && !name.isEmpty ? "Convert \(Swatches.quoted(name)) to \(Self.title(target))"
            : "Convert \(Swatches.count(swatches.count)) to \(Self.title(target))"
    }

    /// `color` converted into `target`.
    public func converted(_ color: Color) -> Color {
        target.isRGB ? WTColor.Gamut.map(color, into: target) : converter.convert(color, to: target)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        var taken: Set<String> = []
        for id in swatches {
            let swatch = try Swatches.live(id, list)
            guard Self.canConvert(swatch, to: target) else { continue }
            let color = converted(swatch.value)
            var paths = [SwatchFields.value]
            var name = ""
            if autoRename, swatch.hasDefaultName {
                name = Swatches.defaultName(color, list, taken: taken, except: id)
                taken.insert(name)
                paths.append(SwatchFields.name)
            }
            builder.append(Ops.set(id, paths, values: SwatchFields.values { props in
                props.value = ColorValues.stored(color)
                props.common.name = name
            }))
        }
    }
}
