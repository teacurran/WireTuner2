import WTCRDT
import WTProto
import WTRender

/// Colour libraries in the document (spot-process.adoc, "Library files"; exporting-colors.adoc;
/// COLOR-013's and COLOR-021's WTModel half): importing a `ColorLibrary`'s colours as swatches
/// that remember their origin (`library`, `library_key`), classifying swatches against a newer
/// version of their library, *Update from Library…*, and a list of swatches as a library for
/// exports and cross-document drags.
public enum ColorLibraries {
    /// The `library` value of a swatch added from a team library: `team:<document id>`.
    public static func teamOrigin(_ documentID: String) -> String { "team:\(documentID)" }

    /// A library's colours by key (the first of a repeated key wins).
    static func byKey(_ library: Wiretuner_Lib_V1_ColorLibrary) -> [String: Wiretuner_Lib_V1_LibraryColor] {
        var result: [String: Wiretuner_Lib_V1_LibraryColor] = [:]
        for color in library.colors where result[color.key] == nil {
            result[color.key] = color
        }
        return result
    }

    /// Whether a library colour is a tint.
    static func isTint(_ color: Wiretuner_Lib_V1_LibraryColor) -> Bool {
        color.tintPercent > 0
    }

    /// The keys of `library` already in the document from `origin` (the sheet's ticks).
    public static func present(_ library: Wiretuner_Lib_V1_ColorLibrary, origin: String, in list: SwatchList) -> Set<String> {
        let keys = Set(library.colors.map(\.key))
        return Set(list.swatches.filter { $0.library == origin && keys.contains($0.libraryKey) }.map(\.libraryKey))
    }

    /// The live swatches from `origin`, by key (the smallest node id of a repeated key).
    static func swatches(from origin: String, in list: SwatchList) -> [String: Swatch] {
        var result: [String: Swatch] = [:]
        for swatch in list.swatches where swatch.library == origin && !swatch.libraryKey.isEmpty {
            if result[swatch.libraryKey].map({ swatch.id < $0.id }) ?? true {
                result[swatch.libraryKey] = swatch
            }
        }
        return result
    }

    /// `swatches` (with the tints listed under them, protected ones left out) as a library named
    /// `name`: each colour's key is its library key when it came from a library, else its name;
    /// a tint carries its base's colour and, when the base is in the library too, `tint_of`.
    public static func library(named name: String, swatches: [OpID], list: SwatchList) -> Wiretuner_Lib_V1_ColorLibrary {
        var ids: [OpID] = []
        for id in swatches {
            for member in [id] + list.tints(of: id) where !ids.contains(member) {
                ids.append(member)
            }
        }
        let members = ids.compactMap { list[$0] }.filter { !$0.isProtected }
        let keys = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.libraryKey.isEmpty ? $0.plainName : $0.libraryKey) })
        var library = Wiretuner_Lib_V1_ColorLibrary()
        library.name = String(name.prefix(256))
        for swatch in members {
            var color = Wiretuner_Lib_V1_LibraryColor()
            color.key = String(keys[swatch.id]!.prefix(SwatchFields.maxLabel))
            color.name = String(swatch.plainName.prefix(256))
            color.spot = swatch.isSpot
            color.group = swatch.section
            if let base = swatch.base {
                color.tintPercent = swatch.tintPercent
                if let baseKey = keys[base] {
                    color.tintOf = baseKey
                }
                let baseColor = list.resolver.color(ofSwatch: base) ?? ColorValues.cachedColor(swatch.props.parent.cached) ?? .black
                color.value = ColorValues.stored(baseColor)
            } else {
                color.value = swatch.props.value
            }
            library.colors.append(color)
        }
        return library
    }
}

/// Adds colours of a library as swatches (`ImportLibraryColors`; the library sheet, *Team
/// Libraries*, cross-document drops): each selected colour -- with the base of a selected tint
/// -- becomes a swatch in a group named after the library, its origin recorded as `library` and
/// its key.  A colour already present from the same library and key adds nothing (import never
/// writes to an existing swatch).  A tint whose base is in the library becomes a tint of that
/// swatch; one whose base is not becomes a colour of the tinted value.  A name another swatch
/// holds is replaced by the colour's mix values.
public struct ImportLibraryColors: Command {
    public var library: Wiretuner_Lib_V1_ColorLibrary
    /// The `library` value written (the library's name, or `team:<id>`).
    public var origin: String
    /// The keys to import; nil imports every colour.
    public var keys: [String]?
    /// The group the colours land in; nil uses the library's name.
    public var group: String?

    public init(_ library: Wiretuner_Lib_V1_ColorLibrary, origin: String? = nil, keys: [String]? = nil, group: String? = nil) {
        self.library = library
        self.origin = origin ?? library.name
        self.keys = keys
        self.group = group
    }

    public var label: String {
        "Import \(Swatches.count(keys?.count ?? library.colors.count)) from \(Swatches.quoted(library.name))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let byKey = ColorLibraries.byKey(library)
        var wanted = Set(keys ?? library.colors.map(\.key))
        for key in wanted {
            if let color = byKey[key], ColorLibraries.isTint(color), byKey[color.tintOf] != nil { wanted.insert(color.tintOf) }
        }
        var targets: [String: (id: OpID, color: Color)] = ColorLibraries.swatches(from: origin, in: list).mapValues { ($0.id, $0.color) }
        let group = String((self.group ?? library.name).prefix(SwatchFields.maxLabel))
        var taken: Set<String> = []
        var previous = state.store.children(SwatchFields.collection).last.flatMap { state.store.placement($0)?.position }
        var done: Set<String> = []
        // Colours before tints, so a tint finds its base whatever the library's order.
        let ordered = library.colors.filter { !ColorLibraries.isTint($0) } + library.colors.filter(ColorLibraries.isTint)
        for color in ordered where wanted.contains(color.key) && done.insert(color.key).inserted && targets[color.key] == nil {
            let base = ColorValues.color(color.value)
            let isTint = ColorLibraries.isTint(color)
            let tintBase = isTint ? targets[color.tintOf] : nil
            let resolved = isTint ? base.tinted(ColorResolver.percent(color.tintPercent) / 100) : base
            var name = Swatches.clean(color.name.isEmpty ? color.key : color.name)
            if name.isEmpty || list.isTaken(name) || taken.contains(name) {
                name = Swatches.defaultName(resolved, list, taken: taken)
            }
            taken.insert(name)
            let key = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
            previous = key
            let id = builder.append(Swatches.create({ swatch in
                swatch.common.name = name
                swatch.spot = color.spot
                swatch.group = group
                swatch.library = String(origin.prefix(SwatchFields.maxLabel))
                swatch.libraryKey = String(color.key.prefix(SwatchFields.maxLabel))
                if let tintBase {
                    swatch.parent.id = tintBase.id.proto
                    swatch.parent.cached = ColorValues.cached(tintBase.color)
                    swatch.tintPercent = ColorResolver.percent(color.tintPercent)
                } else {
                    swatch.value = ColorValues.stored(resolved)
                }
            }, at: key))
            targets[color.key] = (id, resolved)
        }
    }
}

/// How a swatch from a library stands against a version of that library (*Update from
/// Library…*'s three-way listing).  Whether the swatch was edited here is read from the
/// registers themselves: an import or an update writes `library_key` in the same op as the
/// colour, name and spot, so a colour register written by a later op was edited locally.
public struct LibraryUpdate: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Matches the library.
        case unchanged
        /// Differs from the library and was not edited here since it was added or updated: the
        /// library changed.
        case libraryChanged
        /// Differs from the library and was edited here since.
        case editedLocally
        /// Its key is no longer in the library.
        case removedFromLibrary
    }

    public let swatch: OpID
    public let key: String
    public let status: Status
    /// The library's colour for the key, if it still has it.
    public let libraryColor: Wiretuner_Lib_V1_LibraryColor?

    /// Every live swatch from `origin`, in list order, classified against `library`.
    public static func classify(_ state: EngineState, library: Wiretuner_Lib_V1_ColorLibrary, origin: String) -> [LibraryUpdate] {
        let list = SwatchList(state)
        let byKey = ColorLibraries.byKey(library)
        return list.swatches.filter { $0.library == origin && !$0.libraryKey.isEmpty }.map { swatch in
            guard let color = byKey[swatch.libraryKey] else {
                return LibraryUpdate(swatch: swatch.id, key: swatch.libraryKey, status: .removedFromLibrary, libraryColor: nil)
            }
            let differing = Self.differing(swatch, color, names: true, spot: true)
            guard !differing.isEmpty else {
                return LibraryUpdate(swatch: swatch.id, key: swatch.libraryKey, status: .unchanged, libraryColor: color)
            }
            let stamp = state.store.register(swatch.id, SwatchFields.libraryKey)?.op ?? .zero
            let edited = differing.contains { (state.store.register(swatch.id, $0)?.op ?? .zero) > stamp }
            return LibraryUpdate(swatch: swatch.id, key: swatch.libraryKey, status: edited ? .editedLocally : .libraryChanged, libraryColor: color)
        }
    }

    /// The registers of `swatch` that differ from `color`.
    static func differing(_ swatch: Swatch, _ color: Wiretuner_Lib_V1_LibraryColor, names: Bool, spot: Bool) -> [RegisterPath] {
        var paths: [RegisterPath] = []
        if ColorLibraries.isTint(color), swatch.isTint {
            if swatch.tintPercent != ColorResolver.percent(color.tintPercent) { paths.append(SwatchFields.tintPercent) }
        } else if swatch.isTint || swatch.props.value != Self.value(color) {
            paths.append(SwatchFields.value)
        }
        let name = color.name.isEmpty ? color.key : color.name
        if names, swatch.props.common.name != name, !(swatch.isTint && swatch.props.common.name.isEmpty && swatch.plainName == name) {
            paths.append(SwatchFields.name)
        }
        if spot, !swatch.isTint, swatch.props.spot != color.spot { paths.append(SwatchFields.spot) }
        return paths
    }

    /// The stored colour a library colour stands for (a tint's tinted value).
    static func value(_ color: Wiretuner_Lib_V1_LibraryColor) -> Wiretuner_Doc_V1_Color {
        guard ColorLibraries.isTint(color) else { return color.value }
        return ColorValues.stored(ColorValues.color(color.value).tinted(ColorResolver.percent(color.tintPercent) / 100))
    }
}

/// *Update from Library…* (exporting-colors.adoc, `UpdateSwatchesFromLibrary`): for each chosen
/// swatch from `origin` whose key the library still has, writes the library's colour (a tint's
/// percentage) -- and its name and spot flag when ticked -- together with `library` and
/// `library_key`, in one change.  Two people updating from one version write identical values.
public struct UpdateSwatchesFromLibrary: Command {
    public var library: Wiretuner_Lib_V1_ColorLibrary
    public var origin: String
    /// The swatches to update; nil updates every swatch from `origin`.
    public var swatches: [OpID]?
    public var names: Bool
    public var spot: Bool

    public init(_ library: Wiretuner_Lib_V1_ColorLibrary, origin: String? = nil, swatches: [OpID]? = nil, names: Bool = false, spot: Bool = false) {
        self.library = library
        self.origin = origin ?? library.name
        self.swatches = swatches
        self.names = names
        self.spot = spot
    }

    public var label: String { "Update colors from \(Swatches.quoted(library.name))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let byKey = ColorLibraries.byKey(library)
        let chosen = swatches.map(Set.init)
        for swatch in list.swatches where swatch.library == origin && !swatch.isProtected && chosen.map({ $0.contains(swatch.id) }) ?? true {
            guard let color = byKey[swatch.libraryKey] else { continue }
            var paths = LibraryUpdate.differing(swatch, color, names: names, spot: spot)
            let name = Swatches.clean(color.name.isEmpty ? color.key : color.name)
            if paths.contains(SwatchFields.name), name.isEmpty || list.isTaken(name, except: swatch.id) {
                paths.removeAll { $0 == SwatchFields.name }
            }
            guard !paths.isEmpty else { continue }
            if paths.contains(SwatchFields.value), swatch.isTint {
                paths += [SwatchFields.parent, SwatchFields.tintPercent]
            }
            paths += [SwatchFields.library, SwatchFields.libraryKey]
            builder.append(Ops.set(swatch.id, paths, values: SwatchFields.values { props in
                props.value = LibraryUpdate.value(color)
                if ColorLibraries.isTint(color), swatch.isTint {
                    props.tintPercent = ColorResolver.percent(color.tintPercent)
                }
                props.common.name = name
                props.spot = color.spot
                props.library = swatch.library
                props.libraryKey = swatch.libraryKey
            }))
        }
    }
}
