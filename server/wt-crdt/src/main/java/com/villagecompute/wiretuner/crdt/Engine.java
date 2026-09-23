package com.villagecompute.wiretuner.crdt;

import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementIdRange;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.TextDelete;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The merge engine (docs/spec/crdt-model.adoc), mirroring {@code WTCRDT.EngineState} type for
 * type: a {@link LamportClock}, the {@link NodeStore} and the {@link Schema} it merges with. Every
 * op applies to every state; an op the engine cannot use is a deterministic no-op ("Totality").
 *
 * <p>Implemented: registers ({@code SetFields}, CRDT-001), the node tree ({@code CreateNode},
 * {@code MoveNode}, {@code SetDeleted}, CRDT-002), sets ({@code SetAdd}, {@code SetRemove},
 * CRDT-007), sequences ({@code ElementInsert}, {@code ElementMove}, {@code ElementDelete},
 * CRDT-004), changes with their inverses (CRDT-008), text ({@code TextInsert},
 * {@code TextDelete}, CRDT-005) and formatting marks ({@code TextMark}, CRDT-006). Not
 * thread-safe: the snapshotter gives each document its own engine.
 */
public final class Engine {

    /** Version of the merge semantics this engine implements (docs/spec/crdt-model.adoc). */
    public static final String VERSION = "0.3.0";

    /** The change an op belongs to: its seq and causal past (0 for an op applied on its own). */
    public record Context(long seq, long baseServerSeq) {

        /** The context of an op applied on its own. */
        public static final Context NONE = new Context(0, 0);
    }

    private final Schema schema;
    private final PathResolver resolver;
    private LamportClock clock = new LamportClock();
    private final NodeStore store;
    /** The inverse steps of the local change being applied ({@link #applyLocal}), else {@code null}. */
    private List<Inverse.Step> recording;

    /** An engine over the generated merge table. */
    public Engine() {
        this(Schema.generated());
    }

    /** An engine over {@code schema}. */
    public Engine(Schema schema) {
        this(schema, new NodeStore());
    }

    Engine(Schema schema, NodeStore store) {
        this.schema = schema;
        this.resolver = new PathResolver(schema);
        this.store = store;
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

    void restoreClock(long max) {
        clock = new LamportClock(max);
    }

    /** The merged state. */
    public NodeStore store() {
        return store;
    }

    PathResolver resolver() {
        return resolver;
    }

    /** Applies every op of a change the server has not sequenced (or whose server_seq is unknown). */
    public void apply(Change change) {
        apply(change, null);
    }

    /**
     * Applies {@code change} as a unit (CRDT-008): every op in order, op {@code i} with counter
     * {@code start_counter} plus the counters the ops before it took (change.proto), then records
     * the change against its replica (highest seq, highest {@code base_server_seq}). A change
     * applied again changes nothing. {@code serverSeq} is the server's sequence number for the
     * change when known, else {@code null}: sets judge a concurrent remove by it.
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
        store.recordChange(change.getReplica(), change.getSeq(), change.getBaseServerSeq());
    }

    /**
     * Applies a local change (one this replica just made) and returns its inverse, from which
     * {@link #undoChange} builds the change that undoes it (crdt-model.adoc, "Undo").
     */
    public Inverse applyLocal(Change change) {
        recording = new ArrayList<>();
        try {
            apply(change);
            return new Inverse(List.copyOf(recording));
        } finally {
            recording = null;
        }
    }

    /**
     * The change undoing {@code inverse} against the current state, or {@code null} when nothing
     * of it is left to undo; each step is undone only where the state still holds what this
     * replica wrote. The ops are numbered from {@code startCounter}.
     */
    public Change undoChange(Inverse inverse, long replica, long seq, long startCounter, long baseServerSeq, String label) {
        return Inverse.undoChange(this, inverse, replica, seq, startCounter, baseServerSeq, label);
    }

    /** An undo change and the inverse that redoes it. */
    public record Undone(Change change, Inverse redo) {
    }

    /**
     * Undoes {@code inverse} as change {@code seq} of {@code replica}: builds the undo change from
     * the clock's next counter, applies it locally and returns it with the inverse that redoes it;
     * {@code null} when nothing is left to undo.
     */
    public Undone undo(Inverse inverse, long replica, long seq, long baseServerSeq, String label) {
        Change change = undoChange(inverse, replica, seq, clock.peek(), baseServerSeq, label);
        return change == null ? null : new Undone(change, applyLocal(change));
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

    private void record(Inverse.Step step) {
        if (recording != null) {
            recording.add(step);
        }
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
            case MOVE -> move(op.getMove(), id);
            case SET_DELETED -> {
                OpId node = OpId.of(op.getSetDeleted().getNode());
                Cell<Boolean> before = store.deleted(node);
                Stamped<Boolean> prior = before == null ? null : before.current();
                store.setDeleted(node, op.getSetDeleted().getDeleted(), id);
                Cell<Boolean> after = store.deleted(node);
                if (after != null && after.current().op().equals(id)) {
                    record(new Inverse.Deleted(node, prior, id));
                }
            }
            case ELEMENT_INSERT -> insert(op.getElementInsert(), id);
            case ELEMENT_MOVE -> {
                ElementMove move = op.getElementMove();
                OpId node = OpId.of(move.getNode());
                PathResolver.Target target = walk(node, move.getElement(), null);
                Element element = target == null || target.isField() ? null : store.element(node, target.path());
                if (element != null) {
                    Stamped<byte[]> prior = element.position().current();
                    store.moveElement(node, target.path(), move.getPosition().toByteArray(), id);
                    if (element.position().current().op().equals(id)) {
                        record(new Inverse.ElementPosition(node, target.path(), prior, id));
                    }
                }
            }
            case ELEMENT_DELETE -> {
                ElementDelete delete = op.getElementDelete();
                OpId node = OpId.of(delete.getNode());
                for (FieldPath path : delete.getElementsList()) {
                    PathResolver.Target target = walk(node, path, null);
                    Element element = target == null || target.isField() ? null : store.element(node, target.path());
                    if (element != null) {
                        Stamped<Boolean> prior = element.deleted() == null ? null : element.deleted().current();
                        store.deleteElement(node, target.path(), delete.getDeleted(), id);
                        if (element.deleted().current().op().equals(id)) {
                            record(new Inverse.ElementDeleted(node, target.path(), prior, id));
                        }
                    }
                }
            }
            case SET_ADD -> {
                OpId node = OpId.of(op.getSetAdd().getNode());
                Members members = members(node, op.getSetAdd().getSet(), op.getSetAdd().getValues());
                if (members != null) {
                    for (byte[] member : members.values()) {
                        boolean present = !store.liveTags(node, members.path(), member).isEmpty();
                        if (store.addMember(node, members.path(), member, new NodeStore.SetAddition(id, context.seq()))) {
                            record(new Inverse.MemberAdded(node, members.path(), member, id, present, members.field()));
                        }
                    }
                }
            }
            case SET_REMOVE -> {
                OpId node = OpId.of(op.getSetRemove().getNode());
                Members members = members(node, op.getSetRemove().getSet(), op.getSetRemove().getValues());
                if (members != null) {
                    for (byte[] member : members.values()) {
                        boolean present = !store.liveTags(node, members.path(), member).isEmpty();
                        store.removeMember(node, members.path(), member,
                                new NodeStore.SetRemoval(id, context.seq(), context.baseServerSeq()));
                        if (present && store.liveTags(node, members.path(), member).isEmpty()) {
                            record(new Inverse.MemberRemoved(node, members.path(), member, members.field()));
                        }
                    }
                }
            }
            case TEXT_INSERT -> insertText(op.getTextInsert(), id);
            case TEXT_DELETE -> deleteText(op.getTextDelete(), id);
            case TEXT_MARK -> mark(op.getTextMark(), id);
            default -> {
                // Noop only keeps its counter.
            }
        }
    }

    private void move(MoveNode move, OpId id) {
        OpId node = OpId.of(move.getNode());
        // A node's id is the id of the CreateNode that made it, so no move is its own node.
        if (node.equals(id)) {
            return;
        }
        Placement prior = store.placement(node);
        store.applyTree(id, node, OpId.of(move.getParent()), move.getPosition().toByteArray(), false);
        Placement after = store.placement(node);
        if (after != null && after.op().equals(id)) {
            record(new Inverse.PlacementStep(node, prior, id));
        }
    }

    private void create(CreateNode create, OpId id) {
        WireMessage props = WireMessage.parse(create.getProps().toByteArray());
        int kind = props == null ? 0 : props.lastMessageOf(schema.kinds());
        if (kind == 0 || !store.create(id, kind)) {
            return;
        }
        record(new Inverse.Created(id));
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
            List<PathResolver.Assignment> writes = resolver.resolve(kind, path, values, at -> exists(node, at));
            if (writes != null) {
                for (PathResolver.Assignment write : writes) {
                    Register prior = store.register(node, write.path());
                    if (store.write(node, write.path(), write.value(), id)) {
                        record(new Inverse.RegisterStep(node, write.path(), prior, id));
                    }
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
            record(new Inverse.ElementInserted(node, path));
            WireMessage value = index < occurrences.size() ? occurrences.get(index) : null;
            for (PathResolver.Assignment write : resolver.initialElement(row.typeName(), path, value)) {
                store.write(node, write.path(), write.value(), element);
            }
        }
    }

    /** A SET field's path, how it encodes members, and the members a value holds there. */
    private record Members(RegisterPath path, Inverse.MemberField field, List<byte[]> values) {
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
        return members == null ? null : new Members(target.path(), Inverse.MemberField.of(target.row()), members);
    }

    // Whether the element or newline character at `path` of `node` exists.
    private boolean exists(OpId node, RegisterPath path) {
        return store.element(node, path) != null || store.isNewline(node, path);
    }

    private PathResolver.Target walk(OpId node, FieldPath path, WireMessage values) {
        int kind = store.kind(node);
        return kind == 0 ? null : resolver.walk(kind, path, values, at -> exists(node, at));
    }

    // The TEXT field `path` names on `node`, or null.
    private PathResolver.Target textField(OpId node, FieldPath path) {
        PathResolver.Target target = walk(node, path, null);
        return target != null && target.isField() && target.row().policy() == Policy.TEXT ? target : null;
    }

    // Characters take this op's counter, counter + 1, ..., one per Unicode scalar (CRDT-005).
    private void insertText(TextInsert insert, OpId id) {
        OpId node = OpId.of(insert.getNode());
        PathResolver.Target target = textField(node, insert.getText());
        if (target == null) {
            return;
        }
        int[] scalars = insert.getChars().codePoints().toArray();
        OpId left = new OpId(insert.getLeftOrigin().getCounter(), insert.getLeftOrigin().getReplica());
        OpId right = new OpId(insert.getRightOrigin().getCounter(), insert.getRightOrigin().getReplica());
        List<OpId> inserted = store.editText(node, target.path(), text -> text.insert(scalars, id, left, right));
        if (!inserted.isEmpty()) {
            record(new Inverse.TextInserted(node, target.path(), inserted));
        }
    }

    // Each range names consecutive character ids; a tombstone keeps the greatest delete.
    private void deleteText(TextDelete delete, OpId id) {
        OpId node = OpId.of(delete.getNode());
        PathResolver.Target target = textField(node, delete.getText());
        TextSequence text = target == null ? null : store.text(node, target.path());
        if (text == null) {
            return;
        }
        List<OpId> ids = new ArrayList<>();
        for (ElementIdRange range : delete.getRangesList()) {
            ids.addAll(text.ids(new OpId(range.getFirst().getCounter(), range.getFirst().getReplica()), range.getCount()));
        }
        Map<OpId, Inverse.DeletedChar> content = recording == null ? Map.of() : deletedContent(node, target.path(), text, ids);
        List<Inverse.DeletedChar> deleted = new ArrayList<>();
        for (OpId c : ids) {
            if (store.editText(node, target.path(), t -> t.delete(c, id)) && content.containsKey(c)) {
                deleted.add(content.get(c));
            }
        }
        if (!deleted.isEmpty()) {
            record(new Inverse.TextDeleted(node, target.path(), deleted));
        }
    }

    // What undoing the deletion of `ids` needs: each live one's scalar, attributes and, for a
    // newline, its paragraph registers.
    private Map<OpId, Inverse.DeletedChar> deletedContent(OpId node, RegisterPath path, TextSequence text, List<OpId> ids) {
        List<OpId> live = ids.stream().filter(c -> !text.isDeleted(c)).toList();
        Map<OpId, List<TextAttribute>> attributes = text.attributes(live);
        Map<OpId, Inverse.DeletedChar> out = new HashMap<>();
        for (OpId c : live) {
            RegisterPath prefix = path.element(c);
            List<Inverse.ParagraphRegister> paragraph = new ArrayList<>();
            if (text.codepoint(c) == 0x0A) {
                store.registers(node).forEach((registerPath, register) -> {
                    List<RegisterPath.Segment> segments = registerPath.segments();
                    int length = prefix.segments().size();
                    if (segments.size() > length && segments.subList(0, length).equals(prefix.segments())) {
                        paragraph.add(new Inverse.ParagraphRegister(segments.subList(length, segments.size()),
                                register.value()));
                    }
                });
            }
            out.put(c, new Inverse.DeletedChar(c, text.codepoint(c),
                    attributes.get(c).stream().map(TextAttribute::value).toList(), paragraph));
        }
        return out;
    }

    // A mark's id is this op's id; its key is the attribute it formats (CRDT-006).
    private void mark(com.villagecompute.wiretuner.doc.v1.TextMark op, OpId id) {
        OpId node = OpId.of(op.getNode());
        PathResolver.Target target = textField(node, op.getText());
        if (target == null) {
            return;
        }
        byte[] value = op.getValue().toByteArray();
        TextMark mark = new TextMark(id, anchor(op.getStart()), anchor(op.getEnd()), value,
                MarkValue.key(value, schema.featureField(target.row())));
        List<Inverse.PriorFormat> prior = new ArrayList<>();
        TextSequence text = store.text(node, target.path());
        if (recording != null && mark.key() != null && text != null && text.known(mark.start()) && text.known(mark.end())) {
            int[] range = TextSequence.covered(mark, text.orderIndex(), text.count());
            if (range != null) {
                List<OpId> chars = text.order().subList(range[0], range[1] + 1).stream()
                        .filter(c -> !text.isDeleted(c)).toList();
                Map<OpId, TextMark> winners = text.winners(mark.key(), chars);
                for (OpId c : chars) {
                    TextMark winner = winners.get(c);
                    prior.add(new Inverse.PriorFormat(c, winner == null ? null : winner.value()));
                }
            }
        }
        if (store.editText(node, target.path(), t -> t.mark(mark)) && mark.key() != null) {
            record(new Inverse.TextMarked(node, target.path(), id, mark.key(), value, prior));
        }
    }

    private static Anchor anchor(com.villagecompute.wiretuner.doc.v1.Anchor anchor) {
        return new Anchor(new OpId(anchor.getChar().getCounter(), anchor.getChar().getReplica()), anchor.getBefore());
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

    /**
     * The value {@code values} (a sparse {@code NodeProps}) holds for the register at {@code path}
     * on a node of {@code kind} -- the bytes a {@code SetFields} carrying {@code values} writes
     * there -- or {@code null} when absent or when {@code path} does not name a register field.
     */
    public byte[] registerValue(NodeProps values, int kind, RegisterPath path) {
        PathResolver.Target target = resolver.walk(kind, path.toProto(), WireMessage.parse(values.toByteArray()), at -> true);
        return target == null || !target.isField() || target.value() == null ? null
                : target.value().records(target.row().fieldNumber());
    }

    /** The TEXT field {@code path} names on {@code node}, or {@code null} when it holds nothing. */
    public TextSequence text(OpId node, RegisterPath path) {
        return store.text(node, path);
    }

    /** The state hash of the merged state (32 bytes, {@link StateHash}). */
    public byte[] stateHash() {
        return StateHash.of(store);
    }
}
