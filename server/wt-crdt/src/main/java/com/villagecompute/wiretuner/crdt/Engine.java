package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import java.util.List;

/**
 * The merge engine (docs/spec/crdt-model.adoc), mirroring {@code WTCRDT.EngineState} type for
 * type: a {@link LamportClock}, the {@link NodeStore} and the {@link Schema} it merges with. Every
 * op applies to every state; an op the engine cannot use is a deterministic no-op ("Totality").
 *
 * <p>Implemented: registers ({@code SetFields}, CRDT-001), the node tree ({@code CreateNode},
 * {@code MoveNode}, {@code SetDeleted}, CRDT-002), sets ({@code SetAdd}, {@code SetRemove},
 * CRDT-007) and sequences ({@code ElementInsert}, {@code ElementMove}, {@code ElementDelete},
 * CRDT-004). Text ops only advance the clock until CRDT-005/006. Not thread-safe: the
 * snapshotter gives each document its own engine.
 */
public final class Engine {

    /** Version of the merge semantics this engine implements (docs/spec/crdt-model.adoc). */
    public static final String VERSION = "0.2.0";

    /** The change an op belongs to: its seq and causal past (0 for an op applied on its own). */
    public record Context(long seq, long baseServerSeq) {

        /** The context of an op applied on its own. */
        public static final Context NONE = new Context(0, 0);
    }

    private final Schema schema;
    private final PathResolver resolver;
    private final LamportClock clock = new LamportClock();
    private final NodeStore store = new NodeStore();

    /** An engine over the generated merge table. */
    public Engine() {
        this(Schema.generated());
    }

    /** An engine over {@code schema}. */
    public Engine(Schema schema) {
        this.schema = schema;
        this.resolver = new PathResolver(schema);
    }

    /** The engine version, for health data and snapshot metadata. */
    public static String version() {
        return VERSION;
    }

    /** The merge table this engine uses. */
    public Schema schema() {
        return schema;
    }

    /** This replica's Lamport clock; every applied op advances it. */
    public LamportClock clock() {
        return clock;
    }

    /** The merged state. */
    public NodeStore store() {
        return store;
    }

    /** Applies every op of a change the server has not sequenced (or whose server_seq is unknown). */
    public void apply(Change change) {
        apply(change, null);
    }

    /**
     * Applies every op of {@code change}. Op {@code i} has counter {@code start_counter} plus the
     * counters the ops before it took (change.proto). {@code serverSeq} is the server's sequence
     * number for the change when known, else {@code null}: sets judge a concurrent remove by it.
     */
    public void apply(Change change, Long serverSeq) {
        if (serverSeq != null) {
            acknowledge(change.getReplica(), change.getSeq(), serverSeq);
        }
        Context context = new Context(change.getSeq(), change.getBaseServerSeq());
        long counter = change.getStartCounter();
        for (Op op : change.getOpsList()) {
            apply(op, new OpId(counter, change.getReplica()), context);
            counter += counters(op);
        }
    }

    /** Records the server_seq of change {@code seq} of {@code replica} (the ack of a local change). */
    public void acknowledge(long replica, long seq, long serverSeq) {
        store.sequence(replica, seq, serverSeq);
    }

    /**
     * How many counters {@code op} takes: one per element of an {@code ElementInsert} or Unicode
     * scalar of a {@code TextInsert}, at least one; one for every other op.
     */
    public static long counters(Op op) {
        return switch (op.getOpCase()) {
            case ELEMENT_INSERT -> Math.max(1, op.getElementInsert().getPositionsCount());
            case TEXT_INSERT -> {
                String chars = op.getTextInsert().getChars();
                yield Math.max(1, chars.codePointCount(0, chars.length()));
            }
            default -> 1;
        };
    }

    /** Applies one op on its own with id {@code id}. */
    public void apply(Op op, OpId id) {
        apply(op, id, Context.NONE);
    }

    /** Applies one op with id {@code id} (its first counter) in {@code context}. */
    public void apply(Op op, OpId id, Context context) {
        clock.observe(id.counter() + counters(op) - 1);
        switch (op.getOpCase()) {
            case CREATE -> create(op.getCreate(), id);
            case SET -> set(op.getSet(), id);
            case MOVE -> {
                MoveNode move = op.getMove();
                store.applyTree(id, OpId.of(move.getNode()), OpId.of(move.getParent()),
                        move.getPosition().toByteArray(), false);
            }
            case SET_DELETED -> store.setDeleted(OpId.of(op.getSetDeleted().getNode()), op.getSetDeleted().getDeleted(), id);
            case ELEMENT_INSERT -> insert(op.getElementInsert(), id);
            case ELEMENT_MOVE -> {
                ElementMove move = op.getElementMove();
                OpId node = OpId.of(move.getNode());
                PathResolver.Target target = walk(node, move.getElement(), null);
                if (target != null && !target.isField()) {
                    store.moveElement(node, target.path(), move.getPosition().toByteArray(), id);
                }
            }
            case ELEMENT_DELETE -> {
                ElementDelete delete = op.getElementDelete();
                OpId node = OpId.of(delete.getNode());
                for (FieldPath element : delete.getElementsList()) {
                    PathResolver.Target target = walk(node, element, null);
                    if (target != null && !target.isField()) {
                        store.deleteElement(node, target.path(), delete.getDeleted(), id);
                    }
                }
            }
            case SET_ADD -> {
                OpId node = OpId.of(op.getSetAdd().getNode());
                Members members = members(node, op.getSetAdd().getSet(), op.getSetAdd().getValues());
                if (members != null) {
                    for (byte[] member : members.values()) {
                        store.addMember(node, members.path(), member, new NodeStore.SetAddition(id, context.seq()));
                    }
                }
            }
            case SET_REMOVE -> {
                OpId node = OpId.of(op.getSetRemove().getNode());
                Members members = members(node, op.getSetRemove().getSet(), op.getSetRemove().getValues());
                if (members != null) {
                    for (byte[] member : members.values()) {
                        store.removeMember(node, members.path(), member,
                                new NodeStore.SetRemoval(id, context.seq(), context.baseServerSeq()));
                    }
                }
            }
            default -> {
                // Text ops arrive with CRDT-005/006; Noop only keeps its counter.
            }
        }
    }

    private void create(CreateNode create, OpId id) {
        WireMessage props = WireMessage.parse(create.getProps().toByteArray());
        int kind = props == null ? 0 : props.lastMessageOf(schema.kinds());
        if (kind == 0 || !store.create(id, kind)) {
            return;
        }
        for (PathResolver.Assignment write : resolver.initial(kind, props)) {
            store.write(id, write.path(), write.value(), id);
        }
        store.applyTree(id, id, OpId.of(create.getParent()), create.getPosition().toByteArray(), true);
    }

    private void set(SetFields set, OpId id) {
        OpId node = OpId.of(set.getNode());
        int kind = store.kind(node);
        WireMessage values = WireMessage.parse(set.getValues().toByteArray());
        if (kind == 0 || values == null) {
            return;
        }
        for (FieldPath path : set.getPathsList()) {
            List<PathResolver.Assignment> writes = resolver.resolve(kind, path, values,
                    at -> store.element(node, at) != null);
            if (writes != null) {
                for (PathResolver.Assignment write : writes) {
                    store.write(node, write.path(), write.value(), id);
                }
            }
        }
    }

    // Element ids are this op's counter, counter + 1, ...; each takes its position and, from the
    // i-th occurrence of the SEQUENCE field in `values`, its initial field values.
    private void insert(ElementInsert insert, OpId id) {
        OpId node = OpId.of(insert.getNode());
        WireMessage values = WireMessage.parse(insert.getValues().toByteArray());
        PathResolver.Target target = values == null ? null : walk(node, insert.getSequence(), values);
        if (target == null || !target.isField() || target.row().policy() != Policy.SEQUENCE
                || target.row().typeName() == null) {
            return;
        }
        FieldPolicy row = target.row();
        List<WireMessage> occurrences = target.value() == null ? List.of() : target.value().occurrences(row.fieldNumber());
        for (int index = 0; index < insert.getPositionsCount(); index++) {
            OpId element = new OpId(id.counter() + index, id.replica());
            RegisterPath path = target.path().element(element);
            if (!store.insertElement(node, path, insert.getPositions(index).toByteArray(), element)) {
                continue;
            }
            WireMessage value = index < occurrences.size() ? occurrences.get(index) : null;
            for (PathResolver.Assignment write : resolver.initialElement(row.typeName(), path, value)) {
                store.write(node, write.path(), write.value(), element);
            }
        }
    }

    /** A SET field's path and the members a value holds there. */
    private record Members(RegisterPath path, List<byte[]> values) {
    }

    private Members members(OpId node, FieldPath path, NodeProps props) {
        WireMessage values = WireMessage.parse(props.toByteArray());
        return values == null ? null : members(walk(node, path, values));
    }

    private static Members members(PathResolver.Target target) {
        if (target == null || !target.isField() || target.row().policy() != Policy.SET) {
            return null;
        }
        WireMessage container = target.value() == null ? WireMessage.parse(new byte[0]) : target.value();
        List<byte[]> members = container.members(target.row().fieldNumber(), target.row().type(), target.row().typeName());
        return members == null ? null : new Members(target.path(), members);
    }

    private PathResolver.Target walk(OpId node, FieldPath path, WireMessage values) {
        int kind = store.kind(node);
        return kind == 0 ? null : resolver.walk(kind, path, values, at -> store.element(node, at) != null);
    }

    /** The register at {@code path} of {@code node}, or {@code null} when never written. */
    public Register register(OpId node, RegisterPath path) {
        return store.register(node, path);
    }

    /** The retained writes to one register that lost (crdt-model.adoc, "Merge rules"). */
    public List<Write> losingWrites(OpId node, RegisterPath path) {
        return store.losingWrites(node, path);
    }

    /**
     * The members {@code values} (a sparse {@code NodeProps}) holds at the SET field {@code path}
     * names on a node of {@code kind}, in their canonical form, or {@code null} when the path does
     * not name a SET field.
     */
    public List<byte[]> members(NodeProps values, int kind, FieldPath path) {
        Members members = members(resolver.walk(kind, path, WireMessage.parse(values.toByteArray()), at -> true));
        return members == null ? null : members.values();
    }

    /** The state hash of the merged state (32 bytes, {@link StateHash}). */
    public byte[] stateHash() {
        return StateHash.of(store);
    }
}
