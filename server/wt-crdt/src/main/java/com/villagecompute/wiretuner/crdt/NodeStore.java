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

    /** The server_seq of one sequenced change. */
    record Sequenced(long replica, long seq, long serverSeq) {
    }

    private record ChangeKey(long replica, long seq) {
    }

    private final Map<OpId, Integer> created = new HashMap<>();
    private final Map<OpId, NavigableMap<RegisterPath, Register>> registers = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, List<Write>>> log = new HashMap<>();
    private final Map<OpId, Cell<Boolean>> deletedFlags = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, Element>> elements = new HashMap<>();
    private final Map<OpId, Map<RegisterPath, Map<ByteBuffer, MemberHistory>>> sets = new HashMap<>();
    private final Map<ChangeKey, Long> sequenced = new HashMap<>();
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
        if (!created.containsKey(node)) {
            return;
        }
        Cell<Boolean> cell = deletedFlags.get(node);
        if (cell == null) {
            deletedFlags.put(node, new Cell<>(deleted, op));
        } else {
            cell.write(deleted, op);
        }
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

    /** Records the server_seq the server gave change {@code seq} of {@code replica}. */
    void sequence(long replica, long seq, long serverSeq) {
        sequenced.put(new ChangeKey(replica, seq), serverSeq);
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
        Long serverSeq = sequenced.get(new ChangeKey(add.op().replica(), add.seq()));
        return serverSeq != null && Long.compareUnsigned(serverSeq, removal.base()) <= 0;
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
        ReplicaState state = replicaStates.getOrDefault(replica, new ReplicaState(0, 0));
        replicaStates.put(replica, new ReplicaState(
                Long.compareUnsigned(seq, state.seq()) > 0 ? seq : state.seq(),
                Long.compareUnsigned(baseServerSeq, state.ackedServerSeq()) > 0 ? baseServerSeq : state.ackedServerSeq()));
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

    /** The server_seq of every sequenced change, ascending by replica then seq. */
    List<Sequenced> sequencedChanges() {
        return sequenced.entrySet().stream()
                .map(entry -> new Sequenced(entry.getKey().replica(), entry.getKey().seq(), entry.getValue()))
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

    /** Restores a node's {@code deleted} register (snapshot decoding). */
    void restoreDeleted(OpId node, boolean deleted, OpId op) {
        deletedFlags.put(node, new Cell<>(deleted, op));
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
