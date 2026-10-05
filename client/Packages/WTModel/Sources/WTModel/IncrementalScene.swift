import WTCRDT
import WTGeometry
import WTProto
import WTRender

// D-094: a change patches the scene instead of building it again.  A full build walks every
// object (each one cached, but still placed, recorded, indexed and summed); a patch visits only
// what the change can have altered:
//
// * the *dirty* nodes -- the ones the change touched and every node drawn from them
//   (`DependencyIndex`), whose cached items were dropped -- and
// * the *path* nodes: every group above a dirty node, before and after the change.
//
// Each top-level object among those is taken out of its layer's run and placed again; inside a
// group whose placement did not change (same transform, lock and layer) the members off the
// path keep their objects and items -- only renumbered when their slot moved -- and the path
// members are placed again the same way, down to the dirty nodes; a group whose placement did
// change is placed afresh with its whole subtree, as the full build would.  The display list is
// patched over the window of each run that changed (`DisplayList.replaceItems`), the item paths
// of the objects whose top-level index shifted are renumbered, the objects no longer drawn are
// dropped, and the objects' dependencies are updated object by object.  A run's place among its
// siblings is found by binary search on the siblings' keys (position, then id), so a change to
// k nodes costs O(k * depth + log n) plus the renumbering of shifted objects and the copies a
// value snapshot held elsewhere forces.
//
// A full build is kept for what reaches every object or cannot be patched safely: the first
// build, `rebuild`, `reload` and `setBackground`; the raster effect resolution; a layer added,
// removed, reordered, merged, or one whose flags or transform changed (a rename is patched);
// a glyph or master page touched (canvas membership); the document kind; the guide colour; a
// symbol's own canvas; and a remote tree op merged out of order (its undo-redo can re-parent
// nodes the change does not name).

/// Where a placed object sorts among its siblings: its layer's rank (a deleted layer's objects
/// follow the live layer's own, `LayerOrder.objects(on:in:)`), then its position, then its id.
struct ChildKey: Hashable, Sendable, Comparable {
    var rank: Int
    var position: [UInt8]
    var id: OpID

    static func < (lhs: ChildKey, rhs: ChildKey) -> Bool {
        lhs.rank != rhs.rank ? lhs.rank < rhs.rank : FractionalIndex.childOrder((lhs.position, lhs.id), (rhs.position, rhs.id))
    }
}

/// What the last build placed where (D-094): each visible layer's run of master content and
/// top-level objects, each placed object's key among its siblings, each drawn group's members in
/// item order.  Valid after a build of a pasteboard, master or glyph canvas.
struct SceneRecord: Sendable {
    struct Run: Sendable {
        var layer: OpID
        var rendering: LayerRendering
        var masters: [DisplayItem]
        var objects: [OpID]
    }

    var valid = false
    var runs: [Run] = []
    var keys: [OpID: ChildKey] = [:]
    var members: [OpID: [OpID]] = [:]
    /// Each layer node's rank in its run (`ranks`): a deleted layer reordered among the deleted
    /// ones reorders what its run shows.
    var ranks: [OpID: Int] = [:]
    /// Each live layer's transform as placed: a change to one (also one a master's builder only
    /// hears of as an invalidated layer) moves everything on it.
    var layerTransforms: [OpID: AffineTransform] = [:]
    var guideColor: Color?
    var kind: DocumentKind?
}

/// One patch in progress: the nodes it places again, and what it changed so far.
struct UpdatePass: Sendable {
    var dirty: Set<OpID>
    var onPath: Set<OpID>
    /// Path and dirty nodes by their parent now.
    var childCandidates: [OpID: [OpID]]
    /// The objects as they were before the patch, for every object it wrote or dropped (absent:
    /// the object did not exist).
    var previous: [NodeID: SceneObject] = [:]
    var noted: Set<NodeID> = []
    /// Each group's members before the patch, for every group whose members it set.
    var previousMembers: [OpID: [OpID]] = [:]
    var notedMembers: Set<OpID> = []
    /// The objects written, the members kept as they were (with their subtrees), the nodes taken
    /// out of a run or a group (their old subtrees are checked at the end), and the groups whose
    /// members were patched rather than placed afresh.
    var writes: Set<OpID> = []
    var reusedRoots: Set<OpID> = []
    var dropped: Set<OpID> = []
    var patchedGroups: Set<OpID> = []
    var topCandidates: Set<OpID> = []
    /// Whether an object kept as it was moved to another item path.
    var shifted = false

    init(dirty: Set<OpID>, onPath: Set<OpID>, childCandidates: [OpID: [OpID]]) {
        self.dirty = dirty
        self.onPath = onPath
        self.childCandidates = childCandidates
    }

    func isCandidate(_ node: OpID) -> Bool { dirty.contains(node) || onPath.contains(node) }
}

/// The patch's plan, made before anything is changed: a patch that cannot find an object where
/// the record says it is falls back to a full build.
struct PatchPlan {
    var dirty: Set<OpID>
    var onPath: Set<OpID>
    var childCandidates: [OpID: [OpID]]
    /// The top-level nodes placed again, in a fixed order.
    var tops: [OpID]
    /// Where each of them was: run and index in the run's objects.
    var oldTops: [OpID: (run: Int, index: Int)]
    var ranks: [OpID: Int]
}

extension LayerOrder {
    /// A layer as it draws: everything but its name.
    static func renderingKey(_ info: LayerInfo?) -> LayerInfo? {
        guard var info else { return nil }
        info.name = ""
        return info
    }

    /// Whether `other` draws the same layers the same way (names aside).
    func drawsLike(_ other: LayerOrder) -> Bool {
        guides == other.guides && defaultLayer == other.defaultLayer && layers.count == other.layers.count && all.count == other.all.count
            && zip(layers, other.layers).allSatisfy { Self.renderingKey($0) == Self.renderingKey($1) }
            && all.allSatisfy { Self.renderingKey($0.value) == Self.renderingKey(other.all[$0.key]) }
    }
}

extension DocumentDisplayListBuilder {
    // MARK: Keys and bookkeeping

    static func key(_ node: OpID, rank: Int, state: EngineState) -> ChildKey {
        ChildKey(rank: rank, position: state.store.placement(node)?.position ?? [], id: node)
    }

    /// Each layer node's rank in the run it shows on: 0 for a live layer, then the deleted
    /// layers routed to it in tree order.
    static func ranks(_ order: LayerOrder, state: EngineState) -> [OpID: Int] {
        var ranks: [OpID: Int] = [:]
        var counts: [OpID: Int] = [:]
        for layer in order.layers { ranks[layer.id] = 0 }
        for node in state.store.children(WellKnown.layers) where order.all[node] != nil && !order.isLive(node) {
            guard let shown = order.displayLayer(for: node) else { continue }
            counts[shown, default: 0] += 1
            ranks[node] = counts[shown]
        }
        return ranks
    }

    /// Notes `node`'s object as it was before the patch, once.
    mutating func notePrevious(_ node: OpID, in objects: [NodeID: SceneObject]) {
        guard pass != nil else { return }
        let id = NodeID(node)
        if pass!.noted.insert(id).inserted, let old = objects[id] {
            pass!.previous[id] = old
        }
    }

    /// Sets a drawn group's members, noting the ones it had before the patch.
    mutating func setMembers(_ node: OpID, _ list: [OpID]) {
        if pass != nil, pass!.notedMembers.insert(node).inserted, let old = record.members[node] {
            pass!.previousMembers[node] = old
        }
        record.members[node] = list
    }

    /// `node`'s members before the patch.
    func oldMembers(_ node: OpID) -> [OpID] {
        if let pass, pass.notedMembers.contains(node) { return pass.previousMembers[node] ?? [] }
        return record.members[node] ?? []
    }

    /// Whether a change of `seeds` and their `dirty` dependents can be patched in (see the file
    /// comment for what cannot).
    func canPatch(touched: [OpID: [FieldPath]], dirty: Set<OpID>, order: LayerOrder, state: EngineState) -> Bool {
        guard record.valid, record.guideColor == guideColor, symbolCanvas(state) == nil,
              let before = scene.layers, before.drawsLike(order) else { return false }
        for (node, fields) in touched where order.all[node] != nil {
            if fields.contains(where: { !FieldPath(LayerFields.name).contains($0) }) { return false }
        }
        for node in dirty {
            let kind = state.store.kind(node)
            if kind == GlyphFields.kind || kind == MasterPageFields.kind { return false }
        }
        if dirty.contains(WellKnown.settings), DocumentKind(state) != record.kind { return false }
        for layer in order.layers where PathEditing.transform(state.props(layer.id).layer.common.transform) != record.layerTransforms[layer.id] {
            return false
        }
        return Self.ranks(order, state: state) == record.ranks
    }

    /// Whether every tree op of `change` was applied after every other logged one: a remote op
    /// merged out of order undoes and redoes later moves, which can re-parent nodes the change
    /// does not name.
    static func treeOpsInOrder(_ change: Wiretuner_Doc_V1_Change, state: EngineState) -> Bool {
        var treeOps: Set<OpID> = []
        for (op, id) in zip(change.ops, change.opIDs) {
            switch op.op {
            case .create?, .move?: treeOps.insert(id)
            default: break
            }
        }
        guard let first = treeOps.min() else { return true }
        let log = state.store.moveLog
        var low = 0, high = log.count
        while low < high {
            let middle = (low + high) / 2
            if log[middle].op < first { low = middle + 1 } else { high = middle }
        }
        return log[low...].allSatisfy { treeOps.contains($0.op) }
    }

    /// The index of `node` in `list` (sorted by key), by binary search.
    func lowerBound(_ list: [OpID], _ key: ChildKey, keys: [OpID: ChildKey]) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if let other = keys[list[middle]], other < key { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Planning

    func patchPlan(dirty: Set<OpID>, order: LayerOrder, state: EngineState) -> PatchPlan? {
        let objects = scene.objects
        var onPath: Set<OpID> = []
        for node in dirty {
            var next = state.store.placement(node)?.parent
            while let up = next, order.all[up] == nil, onPath.insert(up).inserted {
                next = state.store.placement(up)?.parent
            }
            var old = objects[NodeID(node)]?.parent
            while let up = old, onPath.insert(up).inserted {
                old = objects[NodeID(up)]?.parent
            }
        }
        var childCandidates: [OpID: [OpID]] = [:]
        var tops: Set<OpID> = []
        for node in dirty.union(onPath) {
            if let parent = state.store.placement(node)?.parent {
                if order.all[parent] != nil { tops.insert(node) } else { childCandidates[parent, default: []].append(node) }
            }
            if let object = objects[NodeID(node)], object.parent == nil { tops.insert(node) }
        }
        var runIndex: [OpID: Int] = [:]
        for (index, run) in record.runs.enumerated() { runIndex[run.layer] = index }
        var oldTops: [OpID: (run: Int, index: Int)] = [:]
        for node in tops {
            guard let object = objects[NodeID(node)], object.parent == nil else { continue }
            guard let layer = object.layer, let run = runIndex[layer], let key = record.keys[node] else { return nil }
            let list = record.runs[run].objects
            let index = lowerBound(list, key, keys: record.keys)
            guard index < list.count, list[index] == node else { return nil }
            oldTops[node] = (run, index)
        }
        return PatchPlan(dirty: dirty, onPath: onPath, childCandidates: childCandidates, tops: tops.sorted(), oldTops: oldTops,
                         ranks: record.ranks)
    }

    // MARK: Patching

    /// Brings the scene up to `state` by patching it (`plan`); the summary is the full build's.
    mutating func patch(_ plan: PatchPlan, touched: [OpID: [FieldPath]], seeds: Set<OpID>, dependents: Set<NodeID>, order: LayerOrder,
                        state: EngineState, origin: ChangeOrigin) -> (DocumentScene, ChangeSummary) {
        patches += 1
        prepareMasters(state, touched: seeds)
        begin(state)
        defer {
            end()
            pass = nil
        }
        let beforeLayers = scene.layers
        // A symbol's or a brush's artwork changed: the library is read again.
        if plan.dirty.contains(where: { isLibraryNode($0, state: state) }) {
            var index = DependencyIndex()
            library = buildLibrary(state, dependencies: &index)
            addBrushDependencies(state, to: &index)
            libraryDependencies = index
        }
        var pass = UpdatePass(dirty: plan.dirty, onPath: plan.onPath, childCandidates: plan.childCandidates)
        pass.topCandidates = Set(plan.tops)
        self.pass = pass
        // Moved out so the patch owns them (no copy while it edits them).
        var objects = scene.objects
        scene.objects = [:]
        slotTable = scene.slots
        scene.slots = [:]
        let context = sceneContext(state)
        var windowIDsChanged = false
        TextWrapping.withPass {
            ColorResolver.$current.withValue(ColorResolver(state)) {
                SceneContext.$current.withValue(context) {
                    windowIDsChanged = patchRuns(plan, order: order, state: state, objects: &objects)
                }
            }
        }
        let removed = dropAbsent(objects: &objects)
        refreshDependencies(for: self.pass!.writes.union(removed), objects: objects)
        scene.objects = objects
        scene.slots = slotTable
        slotTable = [:]
        scene.layers = order
        let done = self.pass!
        var isStructural = windowIDsChanged || done.shifted
        if !isStructural {
            for id in done.noted where done.previous[id]?.itemPath != objects[id]?.itemPath {
                isStructural = true
                break
            }
        }
        let summary = summarize(
            touched: touched, seeds: seeds, dependents: dependents, state: state, origin: origin, isStructural: isStructural,
            oldObject: { done.noted.contains($0) ? done.previous[$0] : objects[$0] }, newObject: { objects[$0] },
            children: { [record] id in
                let node = OpID(id)
                let old = done.notedMembers.contains(node) ? done.previousMembers[node] ?? [] : record.members[node] ?? []
                return (old + (record.members[node] ?? [])).map(NodeID.init)
            },
            layerNamesChildren: { Self.layerChanged($0, fields: touched[$0] ?? [], before: beforeLayers, after: order) }
        )
        return (scene, summary)
    }

    /// Whether `node` is a symbol or brush, or lies under the symbols or the brushes.
    private func isLibraryNode(_ node: OpID, state: EngineState) -> Bool {
        var current: OpID? = node
        while let id = current {
            let kind = state.store.kind(id)
            if id == WellKnown.symbols || id == BrushFields.collection || kind == NodeKind.symbol.rawValue || kind == BrushFields.kind { return true }
            current = state.store.placement(id)?.parent
        }
        return false
    }

    /// Takes the plan's top-level nodes out of their runs, places them again, and patches the
    /// display list, the top-level order and the item paths over each run's changed window.
    /// Returns whether the list's node ids changed.
    private mutating func patchRuns(_ plan: PatchPlan, order: LayerOrder, state: EngineState, objects: inout [NodeID: SceneObject]) -> Bool {
        let oldRuns = record.runs
        var runs = oldRuns
        var removedIndices = Array(repeating: [Int](), count: runs.count)
        for (node, location) in plan.oldTops {
            removedIndices[location.run].append(location.index)
            pass!.dropped.insert(node)
        }
        for run in runs.indices {
            for index in removedIndices[run].sorted(by: >) { runs[run].objects.remove(at: index) }
        }
        var oldStarts: [Int] = []
        var start = background.count
        for run in oldRuns {
            oldStarts.append(start)
            start += run.masters.count + run.objects.count
        }
        var runIndex: [OpID: Int] = [:]
        for (index, run) in runs.enumerated() { runIndex[run.layer] = index }
        var inserted = Array(repeating: [OpID](), count: runs.count)
        for node in plan.tops {
            guard state.isLive(node), let parent = state.store.placement(node)?.parent, order.all[parent] != nil,
                  let shown = order.displayLayer(for: parent), let run = runIndex[shown], let info = order.all[shown],
                  belongs(node, state: state) else { continue }
            let provisional = plan.oldTops[node].map { oldStarts[$0.run] + oldRuns[$0.run].masters.count + $0.index } ?? 0
            let transform = layerTransform(shown, state: state)
            guard placeIncremental(node, state: state, parentTransform: transform, itemPath: [provisional], parent: nil,
                                   context: Placing(layer: shown, locked: info.locked), objects: &objects) != nil else { continue }
            let key = Self.key(node, rank: plan.ranks[parent] ?? 0, state: state)
            record.keys[node] = key
            runs[run].objects.insert(node, at: lowerBound(runs[run].objects, key, keys: record.keys))
            inserted[run].append(node)
        }
        // Each run's changed window: everything between the first and the last item removed,
        // inserted or placed again (all of it when its master content changed).  The objects
        // outside it keep their place in the run.
        struct Window {
            var low: Int
            var suffix: Int
        }
        var windows: [Window?] = []
        var insertedIndices: [[(node: OpID, index: Int)]] = []
        var mastersChanged: [Bool] = []
        var idsChanged = false
        for run in runs.indices {
            let newMasters = masters.items(on: runs[run].layer, output: false)
            let changed = newMasters != oldRuns[run].masters
            mastersChanged.append(changed)
            runs[run].masters = newMasters
            let removedHere = removedIndices[run].sorted()
            var insertedHere: [(node: OpID, index: Int)] = []
            for node in inserted[run] {
                guard let key = record.keys[node] else { continue }
                insertedHere.append((node: node, index: lowerBound(runs[run].objects, key, keys: record.keys)))
            }
            insertedHere.sort { $0.index < $1.index }
            insertedIndices.append(insertedHere)
            guard changed || !removedHere.isEmpty || !insertedHere.isEmpty else {
                windows.append(nil)
                continue
            }
            let oldCount = oldRuns[run].objects.count, newCount = runs[run].objects.count
            let low = changed ? 0 : min(removedHere.first ?? .max, insertedHere.first?.index ?? .max)
            let suffix = min(oldCount - 1 - (removedHere.last ?? -1), newCount - 1 - (insertedHere.last?.index ?? -1), oldCount - low, newCount - low)
            windows.append(Window(low: low, suffix: suffix))
        }
        // Whether the list's node ids changed: compared over the span from the first run's window
        // to the last one's, outside which both lists are the same.
        var newStarts: [Int] = []
        var nextStart = background.count
        for run in runs {
            newStarts.append(nextStart)
            nextStart += run.masters.count + run.objects.count
        }
        let changedRuns = runs.indices.filter { windows[$0] != nil }
        if let first = changedRuns.first, let last = changedRuns.last, let firstWindow = windows[first], let lastWindow = windows[last] {
            let low = oldStarts[first] + (mastersChanged[first] ? 0 : oldRuns[first].masters.count + firstWindow.low)
            let oldHigh = oldStarts[last] + oldRuns[last].masters.count + oldRuns[last].objects.count - lastWindow.suffix
            let newHigh = newStarts[last] + runs[last].masters.count + runs[last].objects.count - lastWindow.suffix
            if oldHigh != newHigh {
                idsChanged = true
            } else {
                // Same length: compared position by position, stopping at the first difference.
                let list = scene.displayList.nodeIDs
                var run = first
                for position in low..<newHigh {
                    while position >= newStarts[run] + runs[run].masters.count + runs[run].objects.count { run += 1 }
                    let offset = position - newStarts[run] - runs[run].masters.count
                    let now = offset < 0 ? nil : NodeID(runs[run].objects[offset])
                    if (list.isEmpty ? nil : list[position]) != now {
                        idsChanged = true
                        break
                    }
                }
            }
        }
        // Renumber the objects whose top-level index moved (a run's objects follow its master
        // content and every run before it).
        var newStart = background.count
        for run in runs.indices {
            let oldBase = oldStarts[run] + oldRuns[run].masters.count, newBase = newStart + runs[run].masters.count
            let list = runs[run].objects
            if let window = windows[run] {
                let newCount = list.count, oldCount = oldRuns[run].objects.count
                if newBase != oldBase {
                    for index in 0..<window.low { renumber(list[index], to: newBase + index, objects: &objects) }
                }
                for index in window.low..<(newCount - window.suffix) { renumber(list[index], to: newBase + index, objects: &objects) }
                if newBase + newCount != oldBase + oldCount {
                    for index in (newCount - window.suffix)..<newCount { renumber(list[index], to: newBase + index, objects: &objects) }
                }
            } else if newBase != oldBase {
                for (index, node) in list.enumerated() { renumber(node, to: newBase + index, objects: &objects) }
            }
            newStart = newBase + list.count
        }
        // Patch the list and the top-level order, last run first so earlier offsets hold: an
        // object placed again at its index replaces its item; otherwise the objects taken out
        // are removed and the ones placed are inserted where they sort (the items between keep
        // their place and only shift).
        var topStarts: [Int] = []
        var topStart = 0
        for run in oldRuns {
            topStarts.append(topStart)
            topStart += run.objects.count
        }
        func entry(_ node: OpID) -> (DisplayItem, Rect?) {
            let object = objects[NodeID(node)]
            return (object?.item ?? .group(GroupItem(children: [])), object?.bounds)
        }
        for run in runs.indices.reversed() where windows[run] != nil {
            let base = oldStarts[run] + oldRuns[run].masters.count
            let removedHere = removedIndices[run].sorted()
            let insertedHere = insertedIndices[run]
            if removedHere == insertedHere.map(\.index) {
                for (node, index) in insertedHere {
                    let (item, bounds) = entry(node)
                    scene.displayList.replaceItems((base + index)..<(base + index + 1), with: [item], bounds: [bounds], nodeIDs: [NodeID(node)])
                    scene.topLevel[topStarts[run] + index] = NodeID(node)
                }
            } else {
                for index in removedHere.reversed() {
                    scene.displayList.replaceItems((base + index)..<(base + index + 1), with: [], bounds: [], nodeIDs: [])
                    scene.topLevel.remove(at: topStarts[run] + index)
                }
                for (node, index) in insertedHere {
                    let (item, bounds) = entry(node)
                    scene.displayList.replaceItems((base + index)..<(base + index), with: [item], bounds: [bounds], nodeIDs: [NodeID(node)])
                    scene.topLevel.insert(NodeID(node), at: topStarts[run] + index)
                }
            }
            if mastersChanged[run] {
                let items = runs[run].masters
                scene.displayList.replaceItems(oldStarts[run]..<base, with: items, bounds: items.map(\.bounds),
                                               nodeIDs: Array(repeating: nil, count: items.count))
            }
        }
        if windows.contains(where: { $0 != nil }) {
            var spans: [LayerSpan] = []
            var spanStart = background.count
            for run in runs {
                let count = run.masters.count + run.objects.count
                spans.append(LayerSpan(layer: run.rendering, range: spanStart..<(spanStart + count)))
                spanStart += count
            }
            scene.displayList.setLayers(spans)
        }
        record.runs = runs
        return idsChanged
    }

    /// Gives top-level `node`'s objects the top-level index `index`.  Its subtree's objects all
    /// carry the index the node's own does, so a node already there is left alone.  One lookup
    /// for an object without members: a restack from the bottom renumbers every object above.
    /// (A shifted top-level object always comes with a change of the list's ids, which makes the
    /// change structural.)
    private mutating func renumber(_ node: OpID, to index: Int, objects: inout [NodeID: SceneObject]) {
        guard let slot = objects.index(forKey: NodeID(node)), objects.values[slot].itemPath[0] != index else { return }
        objects.values[slot].itemPath[0] = index
        let kind = objects.values[slot].kind
        guard kind == .group || WrapperKind(rawValue: kind.rawValue) != nil, let members = record.members[node] else { return }
        var pending = members
        while let next = pending.popLast() {
            guard let member = objects.index(forKey: NodeID(next)) else { continue }
            objects.values[member].itemPath[0] = index
            if !objects.values[member].aliasItemPaths.isEmpty {
                objects.values[member].aliasItemPaths = objects.values[member].aliasItemPaths.map { path in
                    var path = path
                    if !path.isEmpty { path[0] = index }
                    return path
                }
            }
            pending += record.members[next] ?? []
        }
    }

    /// Moves a kept member's subtree from item path `from` to `to`.
    private mutating func shift(_ node: OpID, from: [Int], to: [Int], objects: inout [NodeID: SceneObject]) {
        var pending = [node]
        while let next = pending.popLast() {
            let id = NodeID(next)
            guard objects[id] != nil else { continue }
            objects[id]!.itemPath = to + objects[id]!.itemPath.dropFirst(from.count)
            if !objects[id]!.aliasItemPaths.isEmpty {
                objects[id]!.aliasItemPaths = objects[id]!.aliasItemPaths.map { $0.starts(with: from) ? to + $0.dropFirst(from.count) : $0 }
            }
            pending += record.members[next] ?? []
        }
        pass!.shifted = true
    }

    /// `node` placed again under the patch's rules: a group whose placement did not change keeps
    /// its members off the path, and places its path members the same way; anything else is
    /// placed afresh with its subtree (`place`).
    mutating func placeIncremental(_ node: OpID, state: EngineState, parentTransform: AffineTransform, itemPath: [Int], parent: OpID?,
                                   context: Placing, objects: inout [NodeID: SceneObject]) -> DisplayItem? {
        let id = NodeID(node)
        let old = objects[id]
        guard !locallyHidden.contains(node), let built = built(node, state: state) else {
            if old != nil { pass!.dropped.insert(node) }
            return nil
        }
        let transform = built.transform.concatenating(parentTransform)
        let locked = context.locked || built.locked
        guard built.kind == .group, built.wrapper == nil, let old, old.kind == .group, old.transform == transform,
              old.isEffectivelyLocked == locked, old.layer == context.layer, let previousMembers = record.members[node] else {
            // Its old subtree is checked at the end: what the fresh placement does not draw goes.
            if old != nil { pass!.dropped.insert(node) }
            return place(node, state: state, parentTransform: parentTransform, itemPath: itemPath, parent: parent, context: context,
                         objects: &objects, record: true)
        }
        pass!.patchedGroups.insert(node)
        // The members off the path keep their order; the path members go where they sort now.
        var keys: [OpID: ChildKey] = [:]
        var order = previousMembers.filter { member in
            guard pass!.isCandidate(member) else { return true }
            pass!.dropped.insert(member)
            return false
        }
        for member in pass!.childCandidates[node] ?? [] where state.isLive(member) {
            let key = Self.key(member, rank: 0, state: state)
            keys[member] = key
            var low = 0, high = order.count
            while low < high {
                let middle = (low + high) / 2
                if let other = keys[order[middle]] ?? record.keys[order[middle]], other < key { low = middle + 1 } else { high = middle }
            }
            order.insert(member, at: low)
        }
        let clip = ClipRendering.clipPath(of: node, in: state)
        let inner = Placing(layer: context.layer, locked: locked)
        var children: [DisplayItem] = []
        var childBounds: [Rect?] = []
        var placedIDs: [OpID] = []
        var slots: [[Int]: NodeID] = [:]
        var clipItem: DisplayItem?
        for member in order {
            let path = clip.map { ClipRendering.itemPath(itemPath, child: member, clip: $0, contentIndex: children.count) } ?? itemPath + [children.count]
            let placed: DisplayItem?
            if pass!.isCandidate(member) {
                placed = placeIncremental(member, state: state, parentTransform: transform, itemPath: path, parent: node, context: inner, objects: &objects)
            } else if let kept = objects[NodeID(member)] {
                placed = kept.item
                pass!.reusedRoots.insert(member)
                if kept.itemPath != path { shift(member, from: kept.itemPath, to: path, objects: &objects) }
                if member != clip, !kept.aliasItemPaths.isEmpty { objects[NodeID(member)]!.aliasItemPaths = [] }
            } else {
                placed = nil
            }
            guard let placed else { continue }
            if member == clip {
                clipItem = placed
            } else {
                children.append(placed)
                childBounds.append(objects[NodeID(member)]?.bounds)
            }
            placedIDs.append(member)
            slots[Array(path.dropFirst(itemPath.count))] = NodeID(member)
        }
        guard let finished = finishGroup(node, built: built, transform: transform, itemPath: itemPath, clip: clip, clipItem: clipItem,
                                         children: children, childBounds: childBounds, placedIDs: placedIDs, slots: &slots, state: state,
                                         objects: &objects) else {
            pass!.dropped.insert(node)
            return nil
        }
        let (item, bounds) = finished
        notePrevious(node, in: objects)
        objects[id] = SceneObject(
            id: node, kind: built.kind, path: built.path, transform: transform, itemPath: itemPath, parent: parent,
            bounds: bounds, elementPoints: built.elementPoints, leafContours: built.leafContours, item: item,
            layer: context.layer, isLocked: built.locked, isEffectivelyLocked: locked
        )
        pass!.writes.insert(node)
        setMembers(node, placedIDs)
        slotTable[id] = slots
        if parent != nil { record.keys[node] = Self.key(node, rank: 0, state: state) }
        return item
    }

    /// Drops the objects of the nodes taken out of a run or a group that the patch did not draw
    /// again (with their old subtrees); returns the nodes dropped.
    private mutating func dropAbsent(objects: inout [NodeID: SceneObject]) -> Set<OpID> {
        let done = pass!
        var candidates: [OpID] = []
        var seen: Set<OpID> = []
        var pending = Array(done.dropped)
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            candidates.append(next)
            // A kept member's subtree is unchanged; a patched group's dropped members were noted
            // themselves.
            if done.reusedRoots.contains(next) || done.patchedGroups.contains(next) { continue }
            pending += oldMembers(next)
        }
        // Decided before anything is dropped: the walk reads the parents as they were.
        let absent = candidates.filter { !isPresent($0, objects: objects) }
        for node in absent {
            let id = NodeID(node)
            notePrevious(node, in: objects)
            objects[id] = nil
            slotTable[id] = nil
            if record.members[node] != nil { setMembers(node, []) }
            record.members[node] = nil
            record.keys[node] = nil
        }
        return Set(absent)
    }

    /// Whether `node` is drawn after the patch: written by it, or inside a member it kept, or
    /// inside a top-level object it did not touch.  A node whose way up meets a node the patch
    /// wrote, before the node itself, was not drawn under it again.
    private func isPresent(_ node: OpID, objects: [NodeID: SceneObject]) -> Bool {
        let done = pass!
        var current = node
        while true {
            if done.writes.contains(current) { return current == node }
            if done.reusedRoots.contains(current) { return true }
            guard let object = objects[NodeID(current)] else { return false }
            guard let parent = object.parent else { return !done.topCandidates.contains(current) }
            current = parent
        }
    }

    /// Brings the objects' dependencies up to date for `nodes` (written or dropped).
    private mutating func refreshDependencies(for nodes: Set<OpID>, objects: [NodeID: SceneObject]) {
        for node in nodes {
            let id = NodeID(node)
            if let old = objectSources.removeValue(forKey: node) {
                objectDependencies.remove(id, from: old.map(NodeID.init))
            }
            if objects[id] != nil, let sources = cache[node]?.sources, !sources.isEmpty {
                objectSources[node] = sources
                for source in sources { objectDependencies.add(id, dependsOn: NodeID(source)) }
            }
        }
    }
}
