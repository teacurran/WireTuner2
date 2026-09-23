package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import com.google.protobuf.Descriptors.FieldDescriptor;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.crdt.Write;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetFields;

/**
 * The registers a change wrote whose write did not apply (COLLAB-023; history.adoc, Blame): the
 * write lost to a <em>concurrent</em> write of the same register with a greater OpId, so on every
 * replica the other value holds it. A write replaced by a later edit that knew about it applied
 * and is not lost.
 *
 * <p>Concurrency comes from the change's causal context, which is all a change carries: a change
 * knew another when the other's server_seq is at or below its {@code base_server_seq}, or it is the
 * same replica's earlier change. The registers come from the merge table: each {@code SetFields}
 * path is resolved on a scratch {@link Engine} node of the path's kind (a struct path stands for
 * every register beneath it); an attribute is lost when every register each of its paths wrote
 * lost. {@code SetDeleted} ("Deleted") and {@code MoveNode} ("Order") are one register per node.
 * Sequence, text and set ops merge by their own rules and never lose; a path through a sequence
 * element or a paragraph resolves to no register on the scratch node and is never marked.
 */
final class LostWrites {

    /** The replica of the scratch ops that resolve paths; no real replica is all ones. */
    private static final long SCRATCH = -1L;

    /** One logged change: its seq and the change. */
    record Logged(long serverSeq, Change change) {
    }

    /** One attribute write: the change, its op's id, the attribute, and the registers it wrote. */
    private record Entry(Logged owner, OpId op, String attribute, Set<Object> registers) {
    }

    /** One register write, by change and op id. */
    private record Writer(Logged owner, OpId op) {
    }

    /** A non-field register: a node's {@code deleted} or its placement. */
    private record Special(OpId node, String attribute) {
    }

    /** A field register of a node. */
    private record Field(OpId node, RegisterPath path) {
    }

    private LostWrites() {
    }

    /**
     * The lost attributes of each of {@code page}'s changes, by server_seq (changes with none are
     * left out), judged against {@code context}: the other changes that wrote the same nodes
     * (the page's own changes may be among them).
     */
    static Map<Long, List<String>> of(Collection<Logged> page, Collection<Logged> context) {
        Map<Long, Logged> all = new LinkedHashMap<>();
        page.forEach(logged -> all.put(logged.serverSeq(), logged));
        context.forEach(logged -> all.putIfAbsent(logged.serverSeq(), logged));
        Resolver resolver = new Resolver();
        List<Entry> entries = new ArrayList<>();
        for (Logged logged : all.values()) {
            for (TouchedNodes.Named named : TouchedNodes.ops(logged.change())) {
                entries.addAll(entries(logged, named, resolver));
            }
        }
        Map<Object, List<Writer>> writers = new HashMap<>();
        for (Entry entry : entries) {
            for (Object register : entry.registers()) {
                writers.computeIfAbsent(register, r -> new ArrayList<>()).add(new Writer(entry.owner(), entry.op()));
            }
        }
        Set<Long> wanted = new HashSet<>();
        page.forEach(logged -> wanted.add(logged.serverSeq()));
        // Per change and attribute: whether every write under it lost (null until one is seen).
        Map<Long, Map<String, Boolean>> lost = new HashMap<>();
        for (Entry entry : entries) {
            long seq = entry.owner().serverSeq();
            if (!wanted.contains(seq) || entry.registers().isEmpty()) {
                continue;
            }
            boolean lostAll = entry.registers().stream().allMatch(register -> writers.get(register).stream()
                    .anyMatch(other -> beats(other, entry)));
            lost.computeIfAbsent(seq, s -> new HashMap<>()).merge(entry.attribute(), lostAll, Boolean::logicalAnd);
        }
        Map<Long, List<String>> out = new HashMap<>();
        for (Logged logged : page) {
            Map<String, Boolean> attributes = lost.getOrDefault(logged.serverSeq(), Map.of());
            List<String> names = ChangeIndex.attributes(logged.change()).stream()
                    .filter(name -> attributes.getOrDefault(name, false)).toList();
            if (!names.isEmpty()) {
                out.put(logged.serverSeq(), names);
            }
        }
        return out;
    }

    /** Whether {@code other}'s write beats {@code entry}'s: another change, a greater OpId, and not made knowing it. */
    private static boolean beats(Writer other, Entry entry) {
        return other.owner() != entry.owner() && other.op().compareTo(entry.op()) > 0
                && !knew(other.owner().change(), entry.owner());
    }

    /** Whether {@code later} was made knowing {@code earlier}. */
    static boolean knew(Change later, Logged earlier) {
        Change change = earlier.change();
        return Long.compareUnsigned(earlier.serverSeq(), later.getBaseServerSeq()) <= 0
                || later.getReplica() == change.getReplica() && Long.compareUnsigned(change.getSeq(), later.getSeq()) < 0;
    }

    /** The attribute writes of one op. */
    private static List<Entry> entries(Logged owner, TouchedNodes.Named named, Resolver resolver) {
        Op op = named.op();
        return switch (op.getOpCase()) {
            case SET -> {
                List<Entry> out = new ArrayList<>();
                for (FieldPath path : op.getSet().getPathsList()) {
                    String attribute = ChangeIndex.attribute(path);
                    if (!attribute.isEmpty()) {
                        out.add(new Entry(owner, named.id(), attribute, resolver.registers(named.node(), op.getSet(), path)));
                    }
                }
                yield out;
            }
            case SET_DELETED -> List.of(special(owner, named, "Deleted"));
            case MOVE -> List.of(special(owner, named, "Order"));
            default -> List.of();
        };
    }

    private static Entry special(Logged owner, TouchedNodes.Named named, String attribute) {
        return new Entry(owner, named.id(), attribute, Set.of(new Special(named.node(), attribute)));
    }

    /**
     * Resolves {@code SetFields} paths to registers through the merge table: each node is created on
     * a scratch engine with the kind the path names, and each path is applied alone under a scratch
     * id; the registers written under that id are the path's.
     */
    private static final class Resolver {

        private final Engine engine = new Engine();
        private final Set<OpId> created = new HashSet<>();
        private long counter;

        Set<Object> registers(OpId node, SetFields set, FieldPath path) {
            // A path with an attribute names a kind (ChangeIndex.attribute).
            FieldDescriptor field = NodeProps.getDescriptor().findFieldByNumber(path.getSegments(0).getField());
            if (created.add(node)) {
                NodeProps.Builder props = NodeProps.newBuilder();
                props.setField(field, props.newBuilderForField(field).build());
                engine.apply(Op.newBuilder().setCreate(CreateNode.newBuilder().setProps(props)).build(), node);
            }
            OpId id = new OpId(++counter, SCRATCH);
            engine.apply(Op.newBuilder().setSet(set.toBuilder().clearPaths().addPaths(path)).build(), id);
            Set<Object> registers = new HashSet<>();
            for (RegisterPath register : engine.store().registers(node).keySet()) {
                for (Write write : engine.store().writes(node, register)) {
                    if (write.op().equals(id)) {
                        registers.add(new Field(node, register));
                    }
                }
            }
            return registers;
        }
    }
}
