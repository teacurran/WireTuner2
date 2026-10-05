// Derived drawing that depends on other nodes (DRAW-035/037, LIB-010/026): a connector is
// drawn from the bounds of the objects it joins, a symbol instance from its symbol's artwork.
// Neither is written when those nodes change, so a change summary names the moved object or
// the edited master node, not the connector or the instance.  `DependencyIndex` is the reverse
// index WTModel maintains from the merged state (node → nodes derived from it); expanding a
// summary through it touches every dependent, so the builder rebuilds them and REND-004
// repaints where they were and are.

import WTGeometry

/// Node → the nodes whose drawing derives from it.
public struct DependencyIndex: Hashable, Sendable {
    private var dependents: [NodeID: Set<NodeID>] = [:]

    public init() {}

    /// Records that `dependent` is drawn from `source`.
    public mutating func add(_ dependent: NodeID, dependsOn source: NodeID) {
        guard dependent != source else { return }
        dependents[source, default: []].insert(dependent)
    }

    /// Forgets every dependency of `dependent` (it was deleted or re-attached).
    public mutating func remove(dependent: NodeID) {
        for source in Array(dependents.keys) {
            dependents[source]?.remove(dependent)
            if dependents[source]?.isEmpty == true {
                dependents[source] = nil
            }
        }
    }

    /// Forgets that `dependent` is drawn from each of `sources` (D-094: the builder keeps each
    /// node's sources, so dropping them costs their number, not the index's size).
    public mutating func remove(_ dependent: NodeID, from sources: some Sequence<NodeID>) {
        for source in sources {
            dependents[source]?.remove(dependent)
            if dependents[source]?.isEmpty == true {
                dependents[source] = nil
            }
        }
    }

    /// Adds every dependency `other` records.
    public mutating func formUnion(_ other: DependencyIndex) {
        for (source, nodes) in other.dependents {
            dependents[source, default: []].formUnion(nodes)
        }
    }

    /// The nodes drawn from `source`, directly.
    public func directDependents(of source: NodeID) -> Set<NodeID> {
        dependents[source] ?? []
    }

    /// Every node drawn from any of `sources`, directly or through other dependents (an
    /// instance of a symbol whose master holds an instance of the edited symbol; a connector
    /// attached to an instance).  Cycles terminate.
    public func dependents(of sources: some Sequence<NodeID>) -> Set<NodeID> {
        var result: Set<NodeID> = []
        var pending = Array(sources)
        while let next = pending.popLast() {
            for dependent in dependents[next] ?? [] where result.insert(dependent).inserted {
                pending.append(dependent)
            }
        }
        return result
    }

    public var isEmpty: Bool { dependents.isEmpty }
}

extension ChangeSummary {
    /// The summary with every dependent of a touched node touched too (as a whole, without
    /// bounds, so the invalidation mapper looks them up in the lists before and after).
    public func touchingDependents(in index: DependencyIndex) -> ChangeSummary {
        var result = self
        for dependent in index.dependents(of: touchedNodes) where !touchedNodes.contains(dependent) {
            result.touch(dependent)
        }
        return result
    }
}
