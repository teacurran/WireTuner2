package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The node tree (docs/spec/crdt-model.adoc, "Tree moves"; CRDT-002): Kleppmann et al.'s
 * highly-available move operation, mirroring {@code WTCRDT.Tree}. Every tree op is kept in the
 * move log in OpId order; an op that arrives late undoes the logged ops after it, applies, and
 * redoes them. A {@code CreateNode} makes its node exist and places it when the parent exists; a
 * {@code MoveNode} applies when the node and the parent exist, the node is not well-known, and
 * the parent is neither the node nor one of its descendants.
 */
final class Tree {

    private final List<MoveLogEntry> log = new ArrayList<>();
    private final Set<OpId> live = new HashSet<>();
    private final Map<OpId, Placement> placements = new HashMap<>();
    private final Map<OpId, Set<OpId>> children = new HashMap<>();

    static boolean isWellKnown(OpId node) {
        return node.replica() == 0 && Long.compareUnsigned(node.counter(), NodeStore.WELL_KNOWN_LIMIT) < 0;
    }

    /** Whether {@code node} exists in the tree: well-known, or created by an op applied so far. */
    boolean exists(OpId node) {
        return isWellKnown(node) || live.contains(node);
    }

    /** The node's placement, or {@code null} for the document root and nodes without a parent. */
    Placement placement(OpId node) {
        if (isWellKnown(node)) {
            return node.equals(OpId.ZERO) ? null : new Placement(OpId.ZERO, new byte[0], OpId.ZERO);
        }
        return placements.get(node);
    }

    /** The children of {@code parent}, deleted ones included, by position then id. */
    List<OpId> children(OpId parent) {
        List<OpId> ids = new ArrayList<>(children.getOrDefault(parent, Set.of()));
        if (parent.equals(OpId.ZERO)) {
            for (long counter = 1; counter < NodeStore.WELL_KNOWN_LIMIT; counter++) {
                ids.add(OpId.wellKnown(counter));
            }
        }
        ids.sort((a, b) -> FractionalIndex.childOrder(
                placement(a).positionBytes(), a, placement(b).positionBytes(), b));
        return ids;
    }

    /** The move log, ascending by op. */
    List<MoveLogEntry> log() {
        return List.copyOf(log);
    }

    /** Applies one tree op in OpId order (undo, do, redo); a replay of a logged op is ignored. */
    void apply(OpId op, OpId node, OpId parent, byte[] position, boolean creates) {
        int low = 0;
        int high = log.size();
        while (low < high) {
            int mid = (low + high) >>> 1;
            if (log.get(mid).op().compareTo(op) < 0) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if (low < log.size() && log.get(low).op().equals(op)) {
            return;
        }
        for (int index = log.size() - 1; index >= low; index--) {
            undo(log.get(index));
        }
        log.add(low, new MoveLogEntry(op, node, parent, position, creates, null, false));
        for (int redo = low; redo < log.size(); redo++) {
            log.set(redo, perform(log.get(redo)));
        }
    }

    private MoveLogEntry perform(MoveLogEntry entry) {
        if (entry.creates()) {
            live.add(entry.node());
        }
        boolean applies = !isWellKnown(entry.node()) && live.contains(entry.node()) && exists(entry.parent())
                && !isAncestor(entry.node(), entry.parent());
        Placement old = applies ? placements.get(entry.node()) : null;
        if (applies) {
            place(entry.node(), new Placement(entry.parent(), entry.position(), entry.op()));
        }
        return entry.withOutcome(old, applies);
    }

    private void undo(MoveLogEntry entry) {
        if (entry.applied()) {
            place(entry.node(), entry.old());
        }
        if (entry.creates()) {
            live.remove(entry.node());
        }
    }

    // Whether `ancestor` is `node` or above it.
    private boolean isAncestor(OpId ancestor, OpId node) {
        OpId current = node;
        while (!current.equals(ancestor)) {
            Placement up = placement(current);
            if (up == null) {
                return false;
            }
            current = up.parent();
        }
        return true;
    }

    private void place(OpId node, Placement placement) {
        Placement old = placements.get(node);
        if (old != null) {
            children.get(old.parent()).remove(node);
        }
        if (placement == null) {
            placements.remove(node);
        } else {
            placements.put(node, placement);
            children.computeIfAbsent(placement.parent(), p -> new HashSet<>()).add(node);
        }
    }
}
