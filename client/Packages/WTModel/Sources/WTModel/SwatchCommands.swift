import Foundation
import WTCRDT
import WTProto
import WTRender

/// Why a swatch command was refused (swatches.adoc; COLOR-003).
public enum SwatchError: Error, Equatable, Sendable {
    /// Not a live swatch.
    case notASwatch(OpID)
    /// White, Black and Registration cannot be removed, renamed or redefined.
    case protected(OpID)
    /// Another swatch holds the name (the rename field shakes and stays open).
    case nameTaken(String)
    /// A colour needs a name (a tint may leave it empty for the derived one).
    case emptyName
    /// Not a tint swatch.
    case notATint(OpID)
    /// Re-basing a tint onto itself or one of its own tints.
    case loop(OpID)
}

/// Shared pieces of the swatch commands.
enum Swatches {
    /// `"Grape"` for labels.
    static func quoted(_ name: String) -> String { "\"\(name)\"" }

    /// "color" or "N colors".
    static func count(_ n: Int) -> String { n == 1 ? "color" : "\(n) colors" }

    /// The live swatch `id` in `list`, or a refusal.
    static func live(_ id: OpID, _ list: SwatchList) throws -> Swatch {
        guard let swatch = list[id] else { throw SwatchError.notASwatch(id) }
        return swatch
    }

    /// A live, unprotected swatch.
    static func ordinary(_ id: OpID, _ list: SwatchList) throws -> Swatch {
        let swatch = try live(id, list)
        guard !swatch.isProtected else { throw SwatchError.protected(id) }
        return swatch
    }

    /// A name as stored: trimmed of surrounding space and cut to the stored length.
    static func clean(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SwatchFields.maxName))
    }

    /// A key directly after the swatch node `after` in the collection (at the end when nil).
    static func position(after: OpID?, in state: EngineState) throws -> [UInt8] {
        guard let after, state.store.placement(after)?.parent == SwatchFields.collection else {
            return try PathEditing.topPosition(in: SwatchFields.collection, state: state)
        }
        let (lo, hi) = SwatchList.neighbours(after, in: state)
        return try PathEditing.keys(between: lo, and: hi, count: 1)[0]
    }

    /// The default name of `color`, `-N` suffixed past the names `list` (and `taken`) hold.
    static func defaultName(_ color: Color, _ list: SwatchList, taken: Set<String> = [], except: OpID? = nil) -> String {
        ColorText.unique(ColorText.defaultName(color)) { list.isTaken($0, except: except) || taken.contains($0) }
    }

    /// The `CreateNode` of a swatch at `position`.
    static func create(_ build: (inout Wiretuner_Doc_V1_SwatchProps) -> Void, at position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        Ops.create(parent: SwatchFields.collection, position: position, props: SwatchFields.values(build))
    }
}

/// Adds a named colour (swatches.adoc, "Adding colors"): from the Mixer, the Tints panel, a drop
/// or the Object panel's *Add to Swatches…*.  An empty name takes the default name (`-N`
/// suffixed); a typed name another swatch holds is refused.  `relink` names `ColorRef`
/// registers (an object's fill, say) to point at the new swatch in the same change, as *Add to
/// Swatches…* does for the colour it names.
public struct AddSwatch: Command {
    public var color: Color
    public var name: String
    public var spot: Bool
    public var group: String
    /// The swatch the new one is placed after; nil adds it at the end of the list.
    public var after: OpID?
    public var library: String
    public var libraryKey: String
    public var relink: [(node: OpID, path: RegisterPath)]

    public init(_ color: Color, name: String = "", spot: Bool = false, group: String = "", after: OpID? = nil, library: String = "",
                libraryKey: String = "", relink: [(node: OpID, path: RegisterPath)] = []) {
        self.color = color
        self.name = name
        self.spot = spot
        self.group = group
        self.after = after
        self.library = library
        self.libraryKey = libraryKey
        self.relink = relink
    }

    public var label: String {
        let name = Swatches.clean(self.name)
        return "Add color \(Swatches.quoted(name.isEmpty ? ColorText.defaultName(color) : name))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        var name = Swatches.clean(self.name)
        if name.isEmpty {
            name = Swatches.defaultName(color, list)
        } else if list.isTaken(name) {
            throw SwatchError.nameTaken(name)
        }
        let id = builder.append(Swatches.create({ swatch in
            swatch.common.name = name
            swatch.value = ColorValues.stored(color)
            swatch.spot = spot
            swatch.group = String(group.prefix(SwatchFields.maxLabel))
            swatch.library = String(library.prefix(SwatchFields.maxLabel))
            swatch.libraryKey = String(libraryKey.prefix(SwatchFields.maxLabel))
        }, at: try Swatches.position(after: after, in: state)))
        var ref = Wiretuner_Doc_V1_ColorRef()
        ref.swatch.id = id.proto
        ref.swatch.cached = ColorValues.cached(color)
        for target in relink {
            builder.append(ColorUses.write(ref, at: target.path, of: target.node))
        }
    }
}

/// Removes swatches (swatches.adoc, "Removing colors"): each selected swatch and every tint
/// listed under it, in one change.  Nothing that used them changes look: references keep
/// pointing at the removed swatch and read their cache (so *Restore* re-links them with no
/// write), and a reference whose cache is older than the swatch's current colour gets its cache
/// refreshed in the same change.  `unusedOnly` (the sheet's *Remove Unused Only*) keeps every
/// selected swatch that it, or a tint under it, is used by something a user sees.
public struct RemoveSwatches: Command {
    public var swatches: [OpID]
    public var unusedOnly: Bool
    /// The panel's index, when it has one (read instead of indexing the document again).
    public var index: SwatchIndex?
    /// The names for the label (`Remove color "Grape"`).
    public var names: [String]

    public init(_ swatches: [OpID], unusedOnly: Bool = false, index: SwatchIndex? = nil, names: [String] = []) {
        self.swatches = swatches
        self.unusedOnly = unusedOnly
        self.index = index
        self.names = names
    }

    public var label: String {
        names.count == 1 && swatches.count == 1 ? "Remove color \(Swatches.quoted(names[0]))" : "Remove \(Swatches.count(swatches.count))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = self.index ?? SwatchIndex(state)
        let list = SwatchList(state)
        var selected: [OpID] = []
        for id in swatches where !selected.contains(id) {
            _ = try Swatches.ordinary(id, list)
            selected.append(id)
        }
        if unusedOnly {
            selected = selected.filter { id in
                !([id] + list.tints(of: id)).contains { tint in
                    index.liveDependents(of: tint, in: state).contains { $0.location != .tintBase }
                }
            }
        }
        var removed: [OpID] = []
        for id in selected {
            for member in [id] + list.tints(of: id) where !removed.contains(member) {
                removed.append(member)
            }
        }
        let removing = Set(removed)
        for id in removed {
            let cache = ColorValues.cached(list[id]!.color)
            for use in index.liveDependents(of: id, in: state) where !removing.contains(use.node) {
                guard case .register(let path) = use.location else { continue }
                var ref = use.ref
                switch ref.ref {
                case .swatch(var swatch)? where swatch.cached != cache:
                    swatch.cached = cache
                    ref.swatch = swatch
                case .tint(var tint)? where tint.base.cached != cache:
                    tint.base.cached = cache
                    ref.tint = tint
                default:
                    continue
                }
                builder.append(ColorUses.write(ref, at: path, of: use.node))
            }
        }
        for id in removed {
            builder.append(Ops.setDeleted(id))
        }
    }
}

/// Renames a swatch; the protected swatches cannot be renamed, and a name another swatch holds
/// is refused.  A tint may be renamed to "" to show its derived name again.
public struct RenameSwatch: Command {
    public var swatch: OpID
    public var name: String
    /// The current name, for the label (`Rename "Grape" to "Plum"`).
    public var previousName: String

    public init(_ swatch: OpID, to name: String, from previousName: String = "") {
        self.swatch = swatch
        self.name = name
        self.previousName = previousName
    }

    public var label: String {
        previousName.isEmpty ? "Rename color to \(Swatches.quoted(Swatches.clean(name)))"
            : "Rename \(Swatches.quoted(previousName)) to \(Swatches.quoted(Swatches.clean(name)))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let current = try Swatches.ordinary(swatch, list)
        let name = Swatches.clean(self.name)
        guard name != current.props.common.name else { return }
        if name.isEmpty {
            guard current.isTint else { throw SwatchError.emptyName }
        } else if list.isTaken(name, except: swatch) {
            throw SwatchError.nameTaken(name)
        }
        builder.append(Ops.set(swatch, [SwatchFields.name], values: SwatchFields.values { $0.common.name = name }))
    }
}

/// Redefines a swatch (editing-colors.adoc, "Redefine swatch"; a colour dropped on a swatch):
/// one write of `value`; a tint dropped on becomes a colour (its `parent` and percentage cleared
/// in the same change).  With *Auto-rename colors* on, a swatch still named by its old values is
/// renamed to the new ones.  Refused for the protected swatches.
public struct RedefineSwatch: Command {
    public var swatch: OpID
    public var color: Color
    public var autoRename: Bool
    /// The current name, for the label.
    public var name: String

    public init(_ swatch: OpID, to color: Color, autoRename: Bool = true, name: String = "") {
        self.swatch = swatch
        self.color = color
        self.autoRename = autoRename
        self.name = name
    }

    public var label: String { name.isEmpty ? "Redefine color" : "Redefine \(Swatches.quoted(name))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let current = try Swatches.ordinary(swatch, list)
        let stored = ColorValues.stored(color)
        var paths: [RegisterPath] = []
        var values = Wiretuner_Doc_V1_SwatchProps()
        if current.isTint {
            paths += [SwatchFields.parent, SwatchFields.tintPercent]
        }
        if current.isTint || current.props.value != stored {
            paths.append(SwatchFields.value)
            values.value = stored
        }
        if autoRename, !paths.isEmpty, current.hasDefaultName || (current.isTint && current.props.common.name.isEmpty) {
            paths.append(SwatchFields.name)
            values.common.name = Swatches.defaultName(color, list, except: swatch)
        }
        guard !paths.isEmpty else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.swatch = values
        builder.append(Ops.set(swatch, paths, values: props))
    }
}

/// *Duplicate*: a copy named `Copy of <name>` just below the original, with its colour (or its
/// tint of the same base), spot flag, group and origin; the copy is never protected.
public struct DuplicateSwatch: Command {
    public var swatch: OpID
    public var name: String

    public init(_ swatch: OpID, name: String = "") {
        self.swatch = swatch
        self.name = name
    }

    public var label: String { name.isEmpty ? "Duplicate color" : "Duplicate \(Swatches.quoted(name))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let original = try Swatches.live(swatch, list)
        let name = ColorText.unique(String("Copy of \(original.plainName)".prefix(SwatchFields.maxName))) { list.isTaken($0) }
        var props = original.props
        props.common = Wiretuner_Doc_V1_CommonProps()
        props.common.name = name
        props.role = .unspecified
        if props.hasParent {
            props.parent = list.resolver.nodeRef(OpID(props.parent.id))
        }
        builder.append(Swatches.create({ $0 = props }, at: try Swatches.position(after: swatch, in: state)))
    }
}

/// Puts swatches under a group header (`""` ungroups).  Protected swatches stay ungrouped.
public struct SetSwatchGroup: Command {
    public var swatches: [OpID]
    public var group: String

    public init(_ swatches: [OpID], group: String) {
        self.swatches = swatches
        self.group = group
    }

    public var label: String {
        group.isEmpty ? "Ungroup \(Swatches.count(swatches.count))" : "Move \(Swatches.count(swatches.count)) to \(Swatches.quoted(group))"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let list = SwatchList(state)
        let group = String(self.group.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SwatchFields.maxLabel))
        for id in swatches {
            let swatch = try Swatches.live(id, list)
            guard !swatch.isProtected, swatch.props.group != group else { continue }
            builder.append(Ops.set(id, [SwatchFields.group], values: SwatchFields.values { $0.group = group }))
        }
    }
}

/// *Restore Deleted Colors…*: brings removed swatches back (`deleted = false`), each with the
/// removed bases of its tint chain so it does not come back dangling.  Objects whose references
/// still name them pick them up with no write.
public struct RestoreSwatches: Command {
    public var swatches: [OpID]

    public init(_ swatches: [OpID]) {
        self.swatches = swatches
    }

    public var label: String { "Restore \(Swatches.count(swatches.count))" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let resolver = ColorResolver(state)
        var restored: Set<OpID> = []
        for id in swatches {
            guard resolver.props(id) != nil else { throw SwatchError.notASwatch(id) }
            var current: OpID? = id
            while let node = current, !resolver.isSwatch(node), let props = resolver.props(node), restored.insert(node).inserted {
                builder.append(Ops.setDeleted(node, false))
                current = props.hasParent ? OpID(props.parent.id) : nil
            }
        }
    }
}

/// *Delete > Unused Named Colors*: every unprotected swatch that nothing a user sees uses --
/// no object, no text, and no tint that is itself kept -- removed in one change.  Computed
/// against the local state when it runs; never refused (swatches.adoc, "Delete Unused Named
/// Colors and concurrent use").
public struct DeleteUnusedSwatches: Command {
    public var index: SwatchIndex?

    public init(index: SwatchIndex? = nil) {
        self.index = index
    }

    public var label: String { "Delete unused colors" }

    /// The swatches the command removes, in list order (the preview sheet's list).
    public static func unused(in state: EngineState, index: SwatchIndex? = nil) -> [OpID] {
        let index = index ?? SwatchIndex(state)
        let list = index.list
        var removing: Set<OpID> = []
        var changed = true
        while changed {
            changed = false
            for swatch in list.swatches where !swatch.isProtected && !removing.contains(swatch.id) {
                let used = index.liveDependents(of: swatch.id, in: state).contains { $0.location != .tintBase || !removing.contains($0.node) }
                if !used {
                    removing.insert(swatch.id)
                    changed = true
                }
            }
        }
        return list.swatches.map(\.id).filter(removing.contains)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for id in Self.unused(in: state, index: index) {
            builder.append(Ops.setDeleted(id))
        }
    }
}

/// *Name All Colors*: every unnamed colour and unnamed tint used on a live object becomes a
/// swatch -- or the existing swatch holding exactly that colour -- and each such reference is
/// rewritten to point at it, in one change.  Colours inside ATOMIC messages and text marks are
/// listed by the index but not rewritten here.
public struct NameAllColors: Command {
    public var index: SwatchIndex?

    public init(index: SwatchIndex? = nil) {
        self.index = index
    }

    public var label: String { "Name All Colors" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = self.index ?? SwatchIndex(state)
        let list = index.list
        var named: [Wiretuner_Doc_V1_Color: (id: OpID, color: Color)] = [:]
        for swatch in list.swatches where !swatch.isTint && !swatch.isProtected {
            if named[swatch.props.value] == nil { named[swatch.props.value] = (swatch.id, swatch.color) }
        }
        var tints: [OpID: [Double: (id: OpID, color: Color)]] = [:]
        for swatch in list.swatches where swatch.isTint && !swatch.baseRemoved && swatch.props.common.name.isEmpty {
            if tints[swatch.base!]?[swatch.tintPercent] == nil { tints[swatch.base!, default: [:]][swatch.tintPercent] = (swatch.id, swatch.color) }
        }
        var taken: Set<String> = []
        var previous = state.store.children(SwatchFields.collection).last.flatMap { state.store.placement($0)?.position }
        func nextKey() throws -> [UInt8] {
            let key = try PathEditing.keys(between: previous, and: nil, count: 1)[0]
            previous = key
            return key
        }
        for use in index.unnamedUses(in: state) {
            guard case .register(let path) = use.location else { continue }
            let target: (id: OpID, color: Color)
            if case .inline(let stored)? = use.ref.ref {
                if let existing = named[stored] {
                    target = existing
                } else {
                    let color = ColorValues.color(stored)
                    let name = Swatches.defaultName(color, list, taken: taken)
                    taken.insert(name)
                    let id = builder.append(Swatches.create({ swatch in
                        swatch.common.name = name
                        swatch.value = stored
                    }, at: try nextKey()))
                    target = (id, color)
                    named[stored] = target
                }
            } else {
                // The index lists inline colours and unnamed tints only.
                let tint = use.ref.tint
                let base = OpID(tint.base.id)
                let percent = ColorResolver.percent(tint.percent)
                if let existing = tints[base]?[percent] {
                    target = existing
                } else if list.resolver.isSwatch(base) {
                    let color = list.resolver.color(ofSwatch: base)!.tinted(percent / 100)
                    let id = builder.append(Swatches.create({ swatch in
                        swatch.parent = list.resolver.nodeRef(base)
                        swatch.tintPercent = percent
                    }, at: try nextKey()))
                    target = (id, color)
                    tints[base, default: [:]][percent] = target
                } else {
                    let color = list.resolver.color(use.ref) ?? .black
                    let stored = ColorValues.stored(color)
                    if let existing = named[stored] {
                        target = existing
                    } else {
                        let name = Swatches.defaultName(color, list, taken: taken)
                        taken.insert(name)
                        let id = builder.append(Swatches.create({ swatch in
                            swatch.common.name = name
                            swatch.value = stored
                        }, at: try nextKey()))
                        target = (id, color)
                        named[stored] = target
                    }
                }
            }
            var ref = Wiretuner_Doc_V1_ColorRef()
            ref.swatch.id = target.id.proto
            ref.swatch.cached = ColorValues.cached(target.color)
            builder.append(ColorUses.write(ref, at: path, of: use.node))
        }
    }
}

/// Creates the protected default swatches a document starts with (swatches.adoc, "Default
/// colors"): White (process C0 M0 Y0 K0), Black (K100, listed as spot) and Registration (100%
/// of every ink, spot), in that order at the head of the list, with their `role` set.  A role
/// the document already has is skipped, so running it on an existing document adds nothing.
/// Belongs in the first change of every new document (the document template).
public struct CreateDefaultSwatches: Command {
    public init() {}

    public var label: String { "Default colors" }

    /// The defaults' names, colours and spot flags, by role.
    public static let defaults: [(role: Wiretuner_Doc_V1_SwatchRole, name: String, color: Color, spot: Bool)] = [
        (.white, "White", Color(cyan: 0, magenta: 0, yellow: 0, black: 0), false),
        (.black, "Black", Color(cyan: 0, magenta: 0, yellow: 0, black: 1), true),
        (.registration, "Registration", Color(cyan: 1, magenta: 1, yellow: 1, black: 1), true),
    ]

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let resolver = ColorResolver(state)
        let missing = Self.defaults.filter { resolver.swatch(role: $0.role) == nil }
        guard !missing.isEmpty else { return }
        let first = state.store.children(SwatchFields.collection).first.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: nil, and: first, count: missing.count)
        for (entry, key) in zip(missing, keys) {
            builder.append(Swatches.create({ swatch in
                swatch.common.name = entry.name
                swatch.value = ColorValues.stored(entry.color)
                swatch.spot = entry.spot
                swatch.role = entry.role
            }, at: key))
        }
    }
}
