package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import com.google.protobuf.Message;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;

/**
 * Which node each op of a change names, read through the generic op shape and never interpreted:
 * a {@code CreateNode} names the node it creates (its own OpId), a {@code Noop} names none, and
 * every other op names its {@code node} (field 1 of each op message, ops.proto). Used by the merge
 * guard and exclusions (branches.adoc, Merge semantics) and by node history (history.adoc).
 */
public final class TouchedNodes {

    /** An op with its id and the node it names ({@code null} for a {@code Noop}). */
    public record Named(Op op, OpId id, OpId node) {
    }

    private TouchedNodes() {
    }

    /** Every op of {@code change} with its id (start_counter plus the counters before it) and node. */
    public static List<Named> ops(Change change) {
        List<Named> named = new ArrayList<>(change.getOpsCount());
        long counter = change.getStartCounter();
        for (Op op : change.getOpsList()) {
            OpId id = new OpId(counter, change.getReplica());
            named.add(new Named(op, id, node(op, id)));
            counter += Engine.counters(op);
        }
        return named;
    }

    /** The distinct nodes {@code change} names, in op order. */
    public static Set<OpId> of(Change change) {
        Set<OpId> nodes = new LinkedHashSet<>();
        for (Named op : ops(change)) {
            if (op.node() != null) {
                nodes.add(op.node());
            }
        }
        return nodes;
    }

    /** The node {@code op} (with id {@code id}) names. */
    static OpId node(Op op, OpId id) {
        return switch (op.getOpCase()) {
            case CREATE -> id;
            case NOOP -> null;
            default -> {
                Message body = (Message) op.getField(Op.getDescriptor().findFieldByNumber(op.getOpCase().getNumber()));
                com.villagecompute.wiretuner.doc.v1.OpId node = (com.villagecompute.wiretuner.doc.v1.OpId) body
                        .getField(body.getDescriptorForType().findFieldByNumber(1));
                yield OpId.of(node);
            }
        };
    }

    private static boolean named(Named op, Set<OpId> nodes) {
        return op.node() != null && nodes.contains(op.node());
    }

    /**
     * {@code change} with every op naming one of {@code excluded} replaced by as many {@code Noop}s
     * as counters it took, so the ids of the ops after it do not move; {@code change} itself when
     * nothing is excluded.
     */
    public static Change without(Change change, Set<OpId> excluded) {
        List<Named> ops = ops(change);
        if (ops.stream().noneMatch(op -> named(op, excluded))) {
            return change;
        }
        Change.Builder filtered = change.toBuilder().clearOps();
        Op noop = Op.newBuilder().setNoop(Noop.getDefaultInstance()).build();
        for (Named op : ops) {
            if (named(op, excluded)) {
                for (long i = 0; i < Engine.counters(op.op()); i++) {
                    filtered.addOps(noop);
                }
            } else {
                filtered.addOps(op.op());
            }
        }
        return filtered.build();
    }
}
