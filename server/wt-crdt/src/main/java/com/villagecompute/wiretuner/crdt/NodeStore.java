package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NavigableMap;
import java.util.NavigableSet;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * The merged state: which nodes exist and of what kind, every register keyed by node and
 * {@link RegisterPath}, and the change log of every write -- winning or losing -- per register.
 * Not thread-safe; the owning {@link Engine} serialises access.
 */
public final class NodeStore {

    /** Kinds of the well-known nodes that carry properties: document (0:0) and settings (0:1). */
    private static final Map<OpId, Integer> WELL_KNOWN_KINDS = Map.of(
            OpId.wellKnown(0), 1,
            OpId.wellKnown(1), 2);

    /** Well-known nodes use replica 0 and counters below this (crdt-model.adoc, "The node tree"). */
    static final long WELL_KNOWN_LIMIT = 16;

    private final Map<OpId, Integer> created = new HashMap<>();
    private final Map<OpId, NavigableMap<RegisterPath, Register>> registers = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, List<Write>>> log = new HashMap<>();

    /**
     * The kind of {@code node} (the field number of its {@code NodeProps.kind} case), or 0 when
     * the node does not exist or is a well-known collection without properties.
     */
    public int kind(OpId node) {
        Integer kind = created.get(node);
        if (kind == null) {
            kind = WELL_KNOWN_KINDS.get(node);
        }
        return kind == null ? 0 : kind;
    }

    /** Whether {@code node} was created or is a well-known node. */
    public boolean exists(OpId node) {
        return created.containsKey(node) || node.replica() == 0 && Long.compareUnsigned(node.counter(), WELL_KNOWN_LIMIT) < 0;
    }

    /** Records a node created with {@code kind}; returns false if it already existed. */
    boolean create(OpId node, int kind) {
        if (exists(node)) {
            return false;
        }
        created.put(node, kind);
        return true;
    }

    /**
     * Applies one register write by the last-writer-wins rule and retains it in the log. A write
     * already applied (same register, same op) is ignored entirely, so replays are idempotent.
     *
     * @return whether the write now holds the register
     */
    boolean write(OpId node, RegisterPath path, byte[] value, OpId op) {
        List<Write> history = log.computeIfAbsent(node, n -> new HashMap<>())
                .computeIfAbsent(path, p -> new ArrayList<>());
        for (Write seen : history) {
            if (seen.op().equals(op)) {
                return false;
            }
        }
        history.add(new Write(node, path, value, op));
        NavigableMap<RegisterPath, Register> nodeRegisters = registers.computeIfAbsent(node, n -> new TreeMap<>());
        Register current = nodeRegisters.get(path);
        if (current != null && current.op().compareTo(op) > 0) {
            return false;
        }
        nodeRegisters.put(path, new Register(value, op));
        return true;
    }

    /** The register at {@code path} of {@code node}, or {@code null} when it was never written. */
    public Register register(OpId node, RegisterPath path) {
        NavigableMap<RegisterPath, Register> nodeRegisters = registers.get(node);
        return nodeRegisters == null ? null : nodeRegisters.get(path);
    }

    /** Every register of {@code node}, in path order. */
    public NavigableMap<RegisterPath, Register> registers(OpId node) {
        return Collections.unmodifiableNavigableMap(registers.getOrDefault(node, new TreeMap<>()));
    }

    /** Every retained write to one register, in arrival order. */
    public List<Write> writes(OpId node, RegisterPath path) {
        Map<RegisterPath, List<Write>> nodeLog = log.getOrDefault(node, Map.of());
        return List.copyOf(nodeLog.getOrDefault(path, List.of()));
    }

    /** The retained writes to one register that do not hold it, in OpId order. */
    public List<Write> losingWrites(OpId node, RegisterPath path) {
        Register current = register(node, path);
        return writes(node, path).stream()
                .filter(write -> !write.op().equals(current.op()))
                .sorted((a, b) -> a.op().compareTo(b.op()))
                .toList();
    }

    /** The nodes the state hash covers: every created node and every node holding a register. */
    public NavigableSet<OpId> nodes() {
        NavigableSet<OpId> nodes = new TreeSet<>(created.keySet());
        nodes.addAll(registers.keySet());
        return nodes;
    }
}
