package com.villagecompute.wiretuner.crdt;

import java.nio.ByteBuffer;
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
 * The merged state: which nodes exist and of what kind, the node tree, every register keyed by
 * node and {@link RegisterPath} with the change log of every write -- winning or losing -- per
 * register, {@code deleted} flags, sequence elements, set members, TEXT fields and what is known
 * of each replica. Mirrors
 * {@code WTCRDT.NodeStore}. Not thread-safe; the owning {@link Engine} serialises access.
 */
public final class NodeStore {

    /** Kinds of the well-known nodes that carry properties: document (0:0) and settings (0:1). */
    private static final Map<OpId, Integer> WELL_KNOWN_KINDS = Map.of(
            OpId.wellKnown(0), 1,
            OpId.wellKnown(1), 2);

    /** Well-known nodes use replica 0 and counters below this (crdt-model.adoc, "The node tree"). */
    static final long WELL_KNOWN_LIMIT = 16;

    /** An add of one member: the {@code SetAdd} op and the seq of its change. */
    record SetAddition(OpId op, long seq) {
    }

    /** A remove of one member: the {@code SetRemove} op, the seq of its change and its causal past. */
    record SetRemoval(OpId op, long seq, long base) {
    }

    /** Every add and remove of one member of one set. */
    static final class MemberHistory {
        final List<SetAddition> adds = new ArrayList<>();
        final List<SetRemoval> removes = new ArrayList<>();
    }

    /** One set member with its history, as a snapshot holds it. */
    record MemberEntry(byte[] member, List<SetAddition> adds, List<SetRemoval> removes) {
    }

    /** One set with the history of every member, as a snapshot holds it. */
    record SetEntry(RegisterPath path, List<MemberEntry> members) {
    }

    /** One change record: its server_seq and end counter, each 0 while unknown. */
    record Sequenced(long replica, long seq, long serverSeq, long endCounter) {
    }

    /** The server_seq and end counter of one change, each 0 while unknown. */
    private static final class ChangeRecord {
        long serverSeq;
        long endCounter;
    }

    private record ChangeKey(long replica, long seq) {
    }

    private final Map<OpId, Integer> created = new HashMap<>();
    private final Map<OpId, NavigableMap<RegisterPath, Register>> registers = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, List<Write>>> log = new HashMap<>();
    private final Map<OpId, Cell<Boolean>> deletedFlags = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, Element>> elements = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, Map<ByteBuffer, MemberHistory>>> sets = new HashMap<>();
    /** The server_seq and end counter of each change, by replica and seq; dropped once stable. */
    private final Map<ChangeKey, ChangeRecord> changeRecords = new HashMap<>();
    /** The wall time of the change that wrote each node's current {@code deleted} value. */
    private final Map<OpId, Long> deletedTimes = new HashMap<>();
    /** The stable point the state was last collected at (0: never). */
    private long stableSeq;
    private final Map<OpId, Map<RegisterPath, TextSequence>> texts = new HashMap<>();
    private final Map<Long, ReplicaState> replicaStates = new HashMap<>();
    private Tree tree = new Tree();

    // ---- Nodes and the tree

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

    /** Whether {@code node} was created by a {@code CreateNode}. */
    public boolean isCreated(OpId node) {
        return created.containsKey(node);
    }

    /** Whether {@code node} was created or is a well-known node. */
    public boolean exists(OpId node) {
        return created.containsKey(node) || Tree.isWellKnown(node);
    }

    /** Records a node created with {@code kind}; returns false if it already existed. */
    boolean create(OpId node, int kind) {
        if (exists(node)) {
            return false;
        }
        created.put(node, kind);
        return true;
    }

    /** Applies a tree op (a {@code CreateNode} or {@code MoveNode}) in OpId order. */
    void applyTree(OpId op, OpId node, OpId parent, byte[] position, boolean creates) {
        tree.apply(op, node, parent, position, creates);
    }

    /** Where {@code node} sits, or {@code null} for the document root and nodes without a parent. */
    public Placement placement(OpId node) {
        return tree.placement(node);
    }

    /** The children of {@code node}, deleted ones included, by position then id. */
    public List<OpId> children(OpId node) {
        return tree.children(node);
    }

    /** The unstable move log, ascending by op. */
    public List<MoveLogEntry> moveLog() {
        return tree.log();
    }

    /** Writes the {@code deleted} register of a created node; well-known and unknown nodes are left alone. */
    void setDeleted(OpId node, boolean deleted, OpId op) {
        setDeleted(node, deleted, op, 0);
    }

    /**
     * Writes the {@code deleted} register of a created node; {@code wallTime} is the writing
     * change's {@code wall_time_ms}, kept while the write holds.
     */
    void setDeleted(OpId node, boolean deleted, OpId op, long wallTime) {
        if (!created.containsKey(node)) {
            return;
        }
        Cell<Boolean> cell = deletedFlags.get(node);
        if (cell == null) {
            cell = new Cell<>(deleted, op);
            deletedFlags.put(node, cell);
        } else {
            cell.write(deleted, op);
        }
        if (cell.current().op().equals(op)) {
            deletedTimes.put(node, wallTime);
        }
    }

    /** The wall time of the change that wrote the current {@code deleted} value of {@code node} (0: unknown). */
    public long deletedTime(OpId node) {
        return deletedTimes.getOrDefault(node, 0L);
    }

    /** The {@code deleted} register of {@code node}, or {@code null} when it was never written. */
    public Cell<Boolean> deleted(OpId node) {
        return deletedFlags.get(node);
    }

    // ---- Registers

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

    // ---- Sequences

    /** Inserts an element at {@code path} (the sequence path plus the element id) unless it exists. */
    boolean insertElement(OpId node, RegisterPath path, byte[] position, OpId op) {
        Map<RegisterPath, Element> nodeElements = elements.computeIfAbsent(node, n -> new HashMap<>());
        if (nodeElements.containsKey(path)) {
            return false;
        }
        nodeElements.put(path, new Element(position, op));
        return true;
    }

    /** Writes an existing element's position register. */
    void moveElement(OpId node, RegisterPath path, byte[] position, OpId op) {
        Element element = element(node, path);
        if (element != null) {
            element.position().write(position, op);
        }
    }

    /** Writes an existing element's {@code deleted} register. */
    void deleteElement(OpId node, RegisterPath path, boolean deleted, OpId op) {
        Element element = element(node, path);
        if (element != null) {
            element.delete(deleted, op);
        }
    }

    /** The element at {@code path} of {@code node}, or {@code null} when it was never inserted. */
    public Element element(OpId node, RegisterPath path) {
        return elements.getOrDefault(node, Map.of()).get(path);
    }

    /** The element ids of the sequence at {@code sequence}, tombstones included, by position then id. */
    public List<OpId> elementOrder(OpId node, RegisterPath sequence) {
        List<Map.Entry<RegisterPath, Element>> found = new ArrayList<>();
        for (Map.Entry<RegisterPath, Element> entry : elements.getOrDefault(node, Map.of()).entrySet()) {
            if (sequence.equals(entry.getKey().parent()) && entry.getKey().last().isElement()) {
                found.add(entry);
            }
        }
        found.sort((a, b) -> FractionalIndex.childOrder(
                a.getValue().position().current().value(), a.getKey().last().element(),
                b.getValue().position().current().value(), b.getKey().last().element()));
        return found.stream().map(entry -> entry.getKey().last().element()).toList();
    }

    /** Every element of {@code node}, in path order. */
    public NavigableMap<RegisterPath, Element> elements(OpId node) {
        return Collections.unmodifiableNavigableMap(new TreeMap<>(elements.getOrDefault(node, Map.of())));
    }

    // ---- Sets

    /**
     * Records the server_seq the server gave change {@code seq} of {@code replica}. A server_seq at
     * or below the stable point is already folded into the replica's stable counter.
     */
    void sequence(long replica, long seq, long serverSeq) {
        if (Long.compareUnsigned(serverSeq, stableSeq) > 0) {
            changeRecords.computeIfAbsent(new ChangeKey(replica, seq), k -> new ChangeRecord()).serverSeq = serverSeq;
        }
    }

    private MemberHistory history(OpId node, RegisterPath path, byte[] member) {
        return sets.computeIfAbsent(node, n -> new HashMap<>())
                .computeIfAbsent(path, p -> new HashMap<>())
                .computeIfAbsent(ByteBuffer.wrap(member.clone()), m -> new MemberHistory());
    }

    /** Records an add of {@code member} to the set at {@code path}; replays are ignored. Returns whether it is new. */
    boolean addMember(OpId node, RegisterPath path, byte[] member, SetAddition add) {
        MemberHistory history = history(node, path, member);
        if (history.adds.stream().anyMatch(seen -> seen.op().equals(add.op()))) {
            return false;
        }
        history.adds.add(add);
        return true;
    }

    /** Records a remove of {@code member} from the set at {@code path}; replays are ignored. */
    void removeMember(OpId node, RegisterPath path, byte[] member, SetRemoval removal) {
        MemberHistory history = history(node, path, member);
        if (history.removes.stream().noneMatch(seen -> seen.op().equals(removal.op()))) {
            history.removes.add(removal);
        }
    }

    /**
     * Whether {@code removal} observed {@code add}: an earlier op of the same replica, or in a
     * change the server sequenced at or before the remove's {@code base_server_seq}.
     */
    private boolean observed(SetAddition add, SetRemoval removal) {
        if (add.op().replica() == removal.op().replica()) {
            return add.op().compareTo(removal.op()) < 0;
        }
        Long serverSeq = serverSeq(add);
        return serverSeq != null && Long.compareUnsigned(serverSeq, removal.base()) <= 0;
    }

    /**
     * The server_seq of an add's change; for a stable add whose record was collected, the stable
     * point (it was sequenced at or before it).
     */
    private Long serverSeq(SetAddition add) {
        ChangeRecord record = changeRecords.get(new ChangeKey(add.op().replica(), add.seq()));
        if (record != null && record.serverSeq != 0) {
            return record.serverSeq;
        }
        return add.seq() != 0 && isStable(add.op()) ? stableSeq : null;
    }

    /** The adds of {@code member} that no remove observed, ascending. */
    public List<OpId> liveTags(OpId node, RegisterPath path, byte[] member) {
        MemberHistory history = sets.getOrDefault(node, Map.of()).getOrDefault(path, Map.of())
                .get(ByteBuffer.wrap(member));
        if (history == null) {
            return List.of();
        }
        return history.adds.stream()
                .filter(add -> history.removes.stream().noneMatch(removal -> observed(add, removal)))
                .map(SetAddition::op)
                .sorted()
                .toList();
    }

    /** The members of the set at {@code path}, ascending bytewise. */
    public List<byte[]> members(OpId node, RegisterPath path) {
        List<byte[]> members = new ArrayList<>();
        for (ByteBuffer member : sets.getOrDefault(node, Map.of()).getOrDefault(path, Map.of()).keySet()) {
            byte[] bytes = member.array();
            if (!liveTags(node, path, bytes).isEmpty()) {
                members.add(bytes.clone());
            }
        }
        members.sort(java.util.Arrays::compareUnsigned);
        return members;
    }

    /** The paths of the sets of {@code node} that have at least one member, in path order. */
    public List<RegisterPath> setPaths(OpId node) {
        return sets.getOrDefault(node, Map.of()).keySet().stream()
                .filter(path -> !members(node, path).isEmpty())
                .sorted()
                .toList();
    }

    // ---- Text

    /** The TEXT field at {@code path} of {@code node}, or {@code null} when it holds nothing. */
    public TextSequence text(OpId node, RegisterPath path) {
        return texts.getOrDefault(node, Map.of()).get(path);
    }

    /** The paths of the TEXT fields of {@code node} that hold something, in path order. */
    public List<RegisterPath> textPaths(OpId node) {
        return texts.getOrDefault(node, Map.of()).keySet().stream().sorted().toList();
    }

    /** Whether {@code path} (a TEXT field's path plus a character id) names a newline character. */
    boolean isNewline(OpId node, RegisterPath path) {
        RegisterPath field = path.parent();
        if (!path.last().isElement() || field == null) {
            return false;
        }
        TextSequence text = text(node, field);
        return text != null && Integer.valueOf(0x0A).equals(text.codepoint(path.last().element()));
    }

    /** Changes one TEXT field in place, dropping it again if it is left holding nothing. */
    <R> R editText(OpId node, RegisterPath path, java.util.function.Function<TextSequence, R> edit) {
        Map<RegisterPath, TextSequence> nodeTexts = texts.computeIfAbsent(node, n -> new HashMap<>());
        TextSequence text = nodeTexts.computeIfAbsent(path, p -> new TextSequence());
        R result = edit.apply(text);
        if (text.isEmpty()) {
            nodeTexts.remove(path);
            if (nodeTexts.isEmpty()) {
                texts.remove(node);
            }
        }
        return result;
    }

    // ---- Replicas

    /** Records that change {@code seq} of {@code replica}, made with causal past {@code baseServerSeq}, was applied. */
    void recordChange(long replica, long seq, long baseServerSeq) {
        recordChange(replica, seq, baseServerSeq, 0);
    }

    /**
     * Records that change {@code seq} of {@code replica}, made with causal past
     * {@code baseServerSeq} and taking counters up to {@code endCounter} (exclusive), was applied.
     */
    void recordChange(long replica, long seq, long baseServerSeq, long endCounter) {
        ReplicaState state = replicaStates.getOrDefault(replica, new ReplicaState(0, 0));
        replicaStates.put(replica, new ReplicaState(
                Long.compareUnsigned(seq, state.seq()) > 0 ? seq : state.seq(),
                Long.compareUnsigned(baseServerSeq, state.ackedServerSeq()) > 0 ? baseServerSeq : state.ackedServerSeq(),
                state.stableCounter()));
        if (Long.compareUnsigned(endCounter, state.stableCounter()) > 0) {
            changeRecords.computeIfAbsent(new ChangeKey(replica, seq), k -> new ChangeRecord()).endCounter = endCounter;
        }
    }

    /** What is known of {@code replica}, or {@code null} when no change of it was applied. */
    public ReplicaState replicaState(long replica) {
        return replicaStates.get(replica);
    }

    /** Every replica with an applied change, ascending by id (unsigned). */
    public NavigableMap<Long, ReplicaState> replicas() {
        NavigableMap<Long, ReplicaState> out = new TreeMap<>(Long::compareUnsigned);
        out.putAll(replicaStates);
        return out;
    }

    /** Every change record (server_seq and end counter), ascending by replica then seq. */
    List<Sequenced> sequencedChanges() {
        return changeRecords.entrySet().stream()
                .map(entry -> new Sequenced(entry.getKey().replica(), entry.getKey().seq(),
                        entry.getValue().serverSeq, entry.getValue().endCounter))
                .sorted((a, b) -> a.replica() != b.replica() ? Long.compareUnsigned(a.replica(), b.replica())
                        : Long.compareUnsigned(a.seq(), b.seq()))
                .toList();
    }

    // ---- Snapshots

    /**
     * Every set of {@code node} with any history, in path order; members ascending bytewise, their
     * adds and removes ascending by op.
     */
    List<SetEntry> setHistories(OpId node) {
        List<SetEntry> out = new ArrayList<>();
        new TreeMap<>(sets.getOrDefault(node, Map.of())).forEach((path, members) -> {
            List<MemberEntry> entries = new ArrayList<>();
            members.forEach((member, history) -> entries.add(new MemberEntry(member.array().clone(),
                    history.adds.stream().sorted((a, b) -> a.op().compareTo(b.op())).toList(),
                    history.removes.stream().sorted((a, b) -> a.op().compareTo(b.op())).toList())));
            entries.sort((a, b) -> java.util.Arrays.compareUnsigned(a.member(), b.member()));
            out.add(new SetEntry(path, entries));
        });
        return out;
    }

    /** Restores a created node (snapshot decoding). */
    void restoreNode(OpId node, int kind) {
        created.put(node, kind);
    }

    /** Restores a register without a change log (snapshot decoding). */
    void restoreRegister(OpId node, RegisterPath path, Register register) {
        registers.computeIfAbsent(node, n -> new TreeMap<>()).put(path, register);
    }

    /** Restores a node's {@code deleted} register and when it was written (snapshot decoding). */
    void restoreDeleted(OpId node, boolean deleted, OpId op, long wallTime) {
        deletedFlags.put(node, new Cell<>(deleted, op));
        if (wallTime != 0) {
            deletedTimes.put(node, wallTime);
        }
    }

    /** Restores one change record (snapshot decoding). */
    void restoreChange(long replica, long seq, long serverSeq, long endCounter) {
        ChangeRecord record = changeRecords.computeIfAbsent(new ChangeKey(replica, seq), k -> new ChangeRecord());
        record.serverSeq = serverSeq;
        record.endCounter = endCounter;
    }

    /** Restores the stable point the state was collected at (snapshot decoding). */
    void restoreStableSeq(long seq) {
        stableSeq = seq;
    }

    /** Restores a sequence element (snapshot decoding). */
    void restoreElement(OpId node, RegisterPath path, Element element) {
        elements.computeIfAbsent(node, n -> new HashMap<>()).put(path, element);
    }

    /** Restores one set member's history (snapshot decoding). */
    void restoreMember(OpId node, RegisterPath path, MemberEntry entry) {
        MemberHistory history = history(node, path, entry.member());
        history.adds.addAll(entry.adds());
        history.removes.addAll(entry.removes());
    }

    /** Restores a TEXT field (snapshot decoding); an empty one is not kept. */
    void restoreText(OpId node, RegisterPath path, TextSequence text) {
        if (!text.isEmpty()) {
            texts.computeIfAbsent(node, n -> new HashMap<>()).put(path, text);
        }
    }

    /** Restores what is known of a replica (snapshot decoding). */
    void restoreReplica(long replica, ReplicaState state) {
        replicaStates.put(replica, state);
    }

    /** Restores the tree (snapshot decoding). */
    void restoreTree(Tree restored) {
        tree = restored;
    }

    /** The created nodes. */
    java.util.Set<OpId> createdNodes() {
        return created.keySet();
    }

    // ---- Garbage collection

    /** The stable point the state was last collected at (0: never). */
    public long stableSeq() {
        return stableSeq;
    }

    /**
     * Whether {@code op} is causally stable in this state: below its replica's stable counter,
     * which garbage collection advances (CRDT-010).
     */
    public boolean isStable(OpId op) {
        ReplicaState state = replicaStates.get(op.replica());
        return state != null && Long.compareUnsigned(op.counter(), state.stableCounter()) < 0;
    }

    /**
     * Each replica's stable counter at stable point {@code at}: one past the last counter of its
     * changes sequenced at or before it, and at least the counter a collection already reached.
     */
    public Map<Long, Long> stableCounters(long at) {
        Map<Long, Long> out = new HashMap<>();
        replicaStates.forEach((replica, state) -> {
            if (state.stableCounter() != 0) {
                out.put(replica, state.stableCounter());
            }
        });
        changeRecords.forEach((key, record) -> {
            if (record.serverSeq != 0 && Long.compareUnsigned(record.serverSeq, at) <= 0) {
                out.merge(key.replica(), record.endCounter, NodeStore::maxUnsigned);
            }
        });
        return out;
    }

    private static long maxUnsigned(long a, long b) {
        return Long.compareUnsigned(a, b) >= 0 ? a : b;
    }

    /**
     * The stable point the replica acks give: the smallest server_seq acknowledged by a replica
     * that is not {@code retired} (0 when there is none).
     */
    public long stablePoint(java.util.Set<Long> retired) {
        Long min = null;
        for (Map.Entry<Long, ReplicaState> entry : replicaStates.entrySet()) {
            long acked = entry.getValue().ackedServerSeq();
            if (!retired.contains(entry.getKey()) && (min == null || Long.compareUnsigned(acked, min) < 0)) {
                min = acked;
            }
        }
        return min == null ? 0 : min;
    }

    /**
     * Drops what stable point {@code target} makes causally stable; mirrors
     * {@code WTCRDT.NodeStore.collect} (crdt-model.adoc, "Garbage collection").
     */
    Collected collect(long target, long now, long retention) {
        if (Long.compareUnsigned(target, stableSeq) < 0) {
            return Collected.NONE;
        }
        Map<Long, Long> counters = stableCounters(target);
        java.util.function.Predicate<OpId> stable = op -> {
            Long counter = counters.get(op.replica());
            return counter != null && Long.compareUnsigned(op.counter(), counter) < 0;
        };
        int setTags = collectSets(stable);
        int elementCount = collectElements(stable);
        int characters = collectTexts(stable);
        int moveLogEntries = tree.prune(stable);
        int changes = 0;
        for (java.util.Iterator<ChangeRecord> records = changeRecords.values().iterator(); records.hasNext();) {
            ChangeRecord record = records.next();
            if (record.serverSeq != 0 && Long.compareUnsigned(record.serverSeq, target) <= 0) {
                records.remove();
                changes++;
            }
        }
        counters.forEach((replica, counter) -> replicaStates.computeIfPresent(replica,
                (r, state) -> state.withStableCounter(counter)));
        stableSeq = target;
        long cutoff;
        try {
            cutoff = Math.subtractExact(now, retention);
        } catch (ArithmeticException overflow) {
            cutoff = Long.MIN_VALUE;
        }
        int nodes = compactNodes(stable, cutoff);
        return new Collected(characters, elementCount, moveLogEntries, setTags, nodes, changes);
    }

    // A stable add some remove observed is dead for good, and a stable remove observes no add
    // that is not stable; both go.  A stable live add stays, judged as sequenced at the stable point.
    private int collectSets(java.util.function.Predicate<OpId> stable) {
        int dropped = 0;
        for (java.util.Iterator<Map<RegisterPath, Map<ByteBuffer, MemberHistory>>> nodeSets = sets.values().iterator();
                nodeSets.hasNext();) {
            Map<RegisterPath, Map<ByteBuffer, MemberHistory>> fields = nodeSets.next();
            for (java.util.Iterator<Map<ByteBuffer, MemberHistory>> fieldSets = fields.values().iterator(); fieldSets.hasNext();) {
                Map<ByteBuffer, MemberHistory> members = fieldSets.next();
                for (java.util.Iterator<MemberHistory> histories = members.values().iterator(); histories.hasNext();) {
                    MemberHistory history = histories.next();
                    List<SetAddition> adds = history.adds.stream()
                            .filter(add -> !(stable.test(add.op())
                                    && history.removes.stream().anyMatch(removal -> observed(add, removal))))
                            .toList();
                    List<SetRemoval> removes = history.removes.stream().filter(removal -> !stable.test(removal.op())).toList();
                    dropped += history.adds.size() - adds.size() + history.removes.size() - removes.size();
                    history.adds.clear();
                    history.adds.addAll(adds);
                    history.removes.clear();
                    history.removes.addAll(removes);
                    if (adds.isEmpty() && removes.isEmpty()) {
                        histories.remove();
                    }
                }
                if (members.isEmpty()) {
                    fieldSets.remove();
                }
            }
            if (fields.isEmpty()) {
                nodeSets.remove();
            }
        }
        return dropped;
    }

    // Sequence tombstones whose `deleted` write is stable go with everything beneath them.
    private int collectElements(java.util.function.Predicate<OpId> stable) {
        int dropped = 0;
        for (OpId node : List.copyOf(elements.keySet())) {
            java.util.Set<RegisterPath> gone = new java.util.HashSet<>();
            elements.get(node).forEach((path, element) -> {
                if (element.isDeleted() && stable.test(element.deleted().current().op())) {
                    gone.add(path);
                }
            });
            if (!gone.isEmpty()) {
                dropped += removeUnder(node, gone);
            }
        }
        return dropped;
    }

    // Character tombstones the text can drop go with their paragraph registers.
    private int collectTexts(java.util.function.Predicate<OpId> stable) {
        int dropped = 0;
        for (OpId node : List.copyOf(texts.keySet())) {
            Map<RegisterPath, TextSequence> fields = texts.get(node);
            for (RegisterPath path : List.copyOf(fields.keySet())) {
                TextSequence text = fields.get(path);
                java.util.Set<OpId> gone = text.collectable(stable);
                if (gone.isEmpty()) {
                    continue;
                }
                dropped += gone.size();
                TextSequence remaining = text.removing(gone);
                if (remaining.isEmpty()) {
                    fields.remove(path);
                } else {
                    fields.put(path, remaining);
                }
                java.util.Set<RegisterPath> prefixes = new java.util.HashSet<>();
                for (OpId c : gone) {
                    prefixes.add(path.element(c));
                }
                removeUnder(node, prefixes);
            }
            Map<RegisterPath, TextSequence> left = texts.get(node);
            if (left != null && left.isEmpty()) {
                texts.remove(node);
            }
        }
        return dropped;
    }

    // Removes every register, change log, element, set and text of `node` at or below one of
    // `prefixes` (element or character paths); returns how many elements went.
    private int removeUnder(OpId node, java.util.Set<RegisterPath> prefixes) {
        java.util.function.Predicate<RegisterPath> under = path -> {
            List<RegisterPath.Segment> segments = path.segments();
            for (int index = 1; index < segments.size(); index++) {
                if (segments.get(index).isElement()
                        && prefixes.contains(RegisterPath.of(segments.subList(0, index + 1)))) {
                    return true;
                }
            }
            return false;
        };
        removeKeys(registers, node, under);
        removeKeys(log, node, under);
        removeKeys(sets, node, under);
        removeKeys(texts, node, under);
        Map<RegisterPath, Element> nodeElements = elements.get(node);
        int before = nodeElements == null ? 0 : nodeElements.size();
        removeKeys(elements, node, under);
        nodeElements = elements.get(node);
        return before - (nodeElements == null ? 0 : nodeElements.size());
    }

    private static <V> void removeKeys(Map<OpId, ? extends Map<RegisterPath, V>> map, OpId node,
            java.util.function.Predicate<RegisterPath> under) {
        Map<RegisterPath, V> inner = map.get(node);
        if (inner != null) {
            inner.keySet().removeIf(under);
            if (inner.isEmpty()) {
                map.remove(node);
            }
        }
    }

    // Nodes deleted by a stable write at or before `cutoff`, each with its subtree.
    private int compactNodes(java.util.function.Predicate<OpId> stable, long cutoff) {
        List<OpId> candidates = new ArrayList<>();
        deletedFlags.forEach((node, flag) -> {
            if (flag.current().value() && stable.test(flag.current().op())
                    && deletedTimes.getOrDefault(node, 0L) <= cutoff) {
                candidates.add(node);
            }
        });
        candidates.sort(null);
        int compacted = 0;
        for (OpId node : candidates) {
            if (!created.containsKey(node)) {
                continue;
            }
            List<OpId> subtree = tree.subtree(node);
            if (tree.names(subtree)) {
                continue;
            }
            for (OpId member : subtree) {
                created.remove(member);
                registers.remove(member);
                log.remove(member);
                deletedFlags.remove(member);
                deletedTimes.remove(member);
                elements.remove(member);
                sets.remove(member);
                texts.remove(member);
            }
            tree.remove(subtree);
            compacted += subtree.size();
        }
        return compacted;
    }

    // ---- Hashing

    /**
     * The nodes the state hash covers: every created node and every node holding a register, a
     * {@code deleted} flag, an element, a set member's history or a TEXT field.
     */
    public NavigableSet<OpId> nodes() {
        NavigableSet<OpId> nodes = new TreeSet<>(created.keySet());
        nodes.addAll(registers.keySet());
        nodes.addAll(deletedFlags.keySet());
        nodes.addAll(elements.keySet());
        nodes.addAll(sets.keySet());
        nodes.addAll(texts.keySet());
        return nodes;
    }
}
