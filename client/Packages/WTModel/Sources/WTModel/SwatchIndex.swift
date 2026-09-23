import struct Foundation.Date
import Observation
import WTCRDT
import WTProto

/// The swatch index of swatches.adoc ("Client") and the `SwatchDependents` index of
/// applying-color.adoc: the colour list as read (`SwatchList`: name → node) and swatch → every
/// place that refers to it, kept from applied changes, local and remote.  "Is this used", "N
/// objects use this" and name lookups read dictionaries; `apply(_:)` re-reads only the nodes a
/// change names, so a merged state reached in any order gives the same index as a full read.
public struct SwatchIndex: Sendable {
    /// The colour list.
    public private(set) var list: SwatchList
    /// Every colour use by node.
    private var usesByNode: [OpID: [ColorUse]] = [:]
    /// Swatch → the uses naming it (live or not; liveness is read at query time).
    private var dependents: [OpID: [ColorUse.Key: ColorUse]] = [:]

    /// The index of `state`, read in full.
    public init(_ state: EngineState) {
        list = SwatchList(state)
        for node in state.store.nodes {
            store(ColorUses.uses(of: node, in: state), for: node)
        }
    }

    /// Updates the index for a change the document applied; a reload reads everything again.
    public mutating func apply(_ event: DocumentEvent) {
        guard event.origin != .reload else {
            self = SwatchIndex(event.after)
            return
        }
        refresh(ColorUses.touched(by: event.change), in: event.after)
    }

    /// Re-reads `nodes` from `state` (and the colour list when any of them is a swatch).
    public mutating func refresh(_ nodes: Set<OpID>, in state: EngineState) {
        for node in nodes {
            store(ColorUses.uses(of: node, in: state), for: node)
        }
        if nodes.contains(where: { $0 == SwatchFields.collection || state.store.kind($0) == SwatchFields.kind }) {
            list = SwatchList(state)
        }
    }

    private mutating func store(_ uses: [ColorUse], for node: OpID) {
        for old in usesByNode[node] ?? [] {
            guard let swatch = old.swatch else { continue }
            dependents[swatch]?[old.key] = nil
            if dependents[swatch]?.isEmpty == true { dependents[swatch] = nil }
        }
        usesByNode[node] = uses.isEmpty ? nil : uses
        for use in uses {
            guard let swatch = use.swatch else { continue }
            dependents[swatch, default: [:]][use.key] = use
        }
    }

    /// Every colour use recorded on `node`.
    public func uses(on node: OpID) -> [ColorUse] {
        usesByNode[node] ?? []
    }

    /// Every recorded use naming `swatch` (as a swatch reference, an unnamed tint's base or a
    /// tint swatch's base), in node order -- live or not.
    public func dependents(of swatch: OpID) -> [ColorUse] {
        (dependents[swatch] ?? [:]).values.sorted { $0.node != $1.node ? $0.node < $1.node : "\($0.location)" < "\($1.location)" }
    }

    /// The uses naming `swatch` that a user sees: on live objects, and tint swatches that are
    /// live.
    public func liveDependents(of swatch: OpID, in state: EngineState) -> [ColorUse] {
        dependents(of: swatch).filter { isVisible($0, in: state) }
    }

    private func isVisible(_ use: ColorUse, in state: EngineState) -> Bool {
        use.location == .tintBase ? list.resolver.isSwatch(use.node) : state.isEffectivelyLive(use.node)
    }

    /// Whether anything a user sees refers to `swatch` (swatches.adoc: a fill, a stroke, text,
    /// a guide, or another swatch -- a tint).
    public func isUsed(_ swatch: OpID, in state: EngineState) -> Bool {
        (dependents[swatch] ?? [:]).values.contains { isVisible($0, in: state) }
    }

    /// The live objects (not swatches) that use any of `swatches`: the removal sheet's "N
    /// objects use them".
    public func users(of swatches: some Sequence<OpID>, in state: EngineState) -> Set<OpID> {
        var result: Set<OpID> = []
        for swatch in swatches {
            for use in (dependents[swatch] ?? [:]).values where use.location != .tintBase && state.isEffectivelyLive(use.node) {
                result.insert(use.node)
            }
        }
        return result
    }

    /// Every use on a live object of an unnamed colour (`inline`) or unnamed tint, in node
    /// order: what *Name All Colors* names.
    public func unnamedUses(in state: EngineState) -> [ColorUse] {
        usesByNode.keys.sorted().flatMap { node -> [ColorUse] in
            guard state.isEffectivelyLive(node) else { return [] }
            return usesByNode[node]!.filter { use in
                switch use.ref.ref {
                case .inline?, .tint?: return use.location != .tintBase
                default: return false
                }
            }
        }
    }
}

/// The colour list for the panels (COLOR-007 onwards): an observable view model over a
/// `Document` that keeps a `SwatchIndex` current on every change the document applies -- local,
/// undo, redo, remote or a reload -- so views bind to `list` and re-render when `revision`
/// moves.  Commands still go through `Document.perform`.
@MainActor @Observable
public final class SwatchesModel {
    /// The index (list, dependents).
    public private(set) var index: SwatchIndex
    /// Counts the changes the document applied since the model was made; views re-read on it.
    public private(set) var revision = 0
    @ObservationIgnored public let document: Document
    @ObservationIgnored private var token: Document.ObservationToken?

    public init(document: Document) {
        self.document = document
        index = SwatchIndex(document.state)
        token = document.observe { [weak self] event in
            self?.apply(event)
        }
    }

    /// Stops following the document.
    public func stop() {
        if let token { document.stopObserving(token) }
        token = nil
    }

    private func apply(_ event: DocumentEvent) {
        index.apply(event)
        revision += 1
    }

    /// The colour list.
    public var list: SwatchList { index.list }

    /// The removed swatches *Restore Deleted Colors…* lists.
    public func deleted(now: Date = Date()) -> [DeletedSwatch] {
        SwatchList.deleted(document.state, now: now)
    }

    /// How many live objects use any of `swatches`.
    public func userCount(of swatches: some Sequence<OpID>) -> Int {
        index.users(of: swatches, in: document.state).count
    }
}
