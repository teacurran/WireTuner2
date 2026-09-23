package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * {@code DocumentSnapshot} encoding and decoding (docs/spec/crdt-model.adoc, "Snapshots";
 * CRDT-009), byte for byte the same as {@code WTCRDT.Snapshot}. The engines write the message
 * themselves, field by field in number order with proto3 defaults left out: a register's value is
 * its records exactly as they arrived, which protobuf-java and swift-protobuf would reorder
 * differently when re-serialising unknown fields. See {@code WTCRDT.Snapshot} for the layout,
 * including the engine bookkeeping ({@code NodeState.sets}, {@code NodeState.texts},
 * {@code NodeState.deleted_wall_time_ms}, {@code MoveLogEntry.old_op},
 * {@code ReplicaState.stable_counter}, {@code DocumentSnapshot.stable_seq} and
 * {@code DocumentSnapshot.sequenced}). The change log is not part of a snapshot.
 */
public final class Snapshot {

    static final int NODE_SETS = 6;
    static final int NODE_TEXTS = 7;
    static final int NODE_DELETED_TIME = 8;
    static final int MOVE_OLD_OP = 8;
    static final int SEQUENCED = 9;

    /** Why a snapshot could not be decoded. */
    public static final class SnapshotException extends Exception {

        private static final long serialVersionUID = 1L;

        SnapshotException(String message) {
            super(message);
        }
    }

    private Snapshot() {
    }

    // ---- Encoding

    /** The canonical {@code DocumentSnapshot} of {@code engine}'s state at {@code serverSeq}. */
    public static byte[] encode(Engine engine, long serverSeq) {
        NodeStore store = engine.store();
        WireWriter out = new WireWriter();
        out.varintField(1, serverSeq);
        for (OpId node : store.nodes()) {
            out.lenField(2, nodeState(store, node));
        }
        for (MoveLogEntry entry : store.moveLog()) {
            out.lenField(3, moveLogEntry(entry));
        }
        store.replicas().forEach((replica, state) -> {
            WireWriter inner = new WireWriter();
            inner.fixed64Field(1, replica);
            inner.varintField(2, state.seq());
            inner.varintField(3, state.ackedServerSeq());
            inner.varintField(4, state.stableCounter());
            out.lenField(4, inner.bytes());
        });
        out.varintField(5, store.stableSeq());
        out.varintField(6, engine.clock().max());
        out.lenField(8, StateHash.of(store));
        for (NodeStore.Sequenced change : store.sequencedChanges()) {
            WireWriter inner = new WireWriter();
            inner.fixed64Field(1, change.replica());
            inner.varintField(2, change.seq());
            inner.varintField(3, change.serverSeq());
            inner.varintField(4, change.endCounter());
            out.lenField(SEQUENCED, inner.bytes());
        }
        return out.bytes();
    }

    private static byte[] nodeState(NodeStore store, OpId node) {
        Placement placement = store.placement(node);
        Cell<Boolean> deleted = store.deleted(node);
        WireWriter plain = new WireWriter();
        plain.idField(1, node);
        if (placement != null) {
            plain.idField(2, placement.parent());
            plain.bytesField(3, placement.positionBytes());
        }
        plain.varintField(4, deleted != null && deleted.current().value() ? 1 : 0);
        plain.bytesField(5, props(store, node));
        WireWriter out = new WireWriter();
        out.lenField(1, plain.bytes());
        if (placement != null) {
            out.idField(2, placement.op());
        }
        if (deleted != null) {
            out.idField(3, deleted.current().op());
        }
        store.registers(node).forEach((path, register) -> {
            WireWriter stamp = new WireWriter();
            stamp.lenField(1, WireWriter.path(path));
            stamp.idField(2, register.op());
            out.lenField(4, stamp.bytes());
        });
        for (byte[] element : elementStates(store, node)) {
            out.lenField(5, element);
        }
        for (NodeStore.SetEntry set : store.setHistories(node)) {
            WireWriter entry = new WireWriter();
            entry.lenField(1, WireWriter.path(set.path()));
            for (NodeStore.MemberEntry member : set.members()) {
                WireWriter inner = new WireWriter();
                inner.lenField(1, member.member());
                for (NodeStore.SetAddition add : member.adds()) {
                    inner.lenField(2, tag(add.op(), add.seq(), 0));
                }
                for (NodeStore.SetRemoval removal : member.removes()) {
                    inner.lenField(3, tag(removal.op(), removal.seq(), removal.base()));
                }
                entry.lenField(2, inner.bytes());
            }
            out.lenField(NODE_SETS, entry.bytes());
        }
        for (RegisterPath path : store.textPaths(node)) {
            out.lenField(NODE_TEXTS, WireWriter.path(path));
        }
        out.varintField(NODE_DELETED_TIME, store.deletedTime(node));
        return out.bytes();
    }

    private static byte[] tag(OpId op, long seq, long base) {
        WireWriter out = new WireWriter();
        out.idField(1, op);
        out.varintField(2, seq);
        out.varintField(3, base);
        return out.bytes();
    }

    // Every sequence element and character of `node`, by path.
    private static List<byte[]> elementStates(NodeStore store, OpId node) {
        TreeMap<RegisterPath, byte[]> states = new TreeMap<>();
        store.elements(node).forEach((path, element) -> {
            OpId id = path.last().element();
            WireWriter out = new WireWriter();
            out.lenField(1, WireWriter.path(path));
            Stamped<byte[]> position = element.position().current();
            out.bytesField(2, position.value());
            if (!position.op().equals(id)) {
                out.idField(3, position.op());
            }
            if (element.deleted() != null) {
                out.varintField(4, element.deleted().current().value() ? 1 : 0);
                out.idField(5, element.deleted().current().op());
            }
            states.put(path, out.bytes());
        });
        for (RegisterPath path : store.textPaths(node)) {
            TextSequence text = store.text(node, path);
            for (OpId c : text.order()) {
                WireWriter out = new WireWriter();
                out.lenField(1, WireWriter.path(path.element(c)));
                OpId deleted = text.deletedOp(c);
                if (deleted != null) {
                    out.varintField(4, 1);
                    out.idField(5, deleted);
                }
                states.put(path.element(c), out.bytes());
            }
        }
        return new ArrayList<>(states.values());
    }

    private static byte[] moveLogEntry(MoveLogEntry entry) {
        WireWriter out = new WireWriter();
        out.idField(1, entry.op());
        out.idField(2, entry.node());
        if (entry.old() != null) {
            out.idField(3, entry.old().parent());
            out.bytesField(4, entry.old().positionBytes());
        }
        out.idField(5, entry.parent());
        out.bytesField(6, entry.position());
        out.varintField(7, entry.applied() ? 1 : 0);
        if (entry.old() != null) {
            out.idField(MOVE_OLD_OP, entry.old().op());
        }
        return out.bytes();
    }

    // ---- Node.props

    /** The registers, elements and texts of one node as a tree of field and element segments. */
    private static final class PropsTree {
        byte[] leaf;
        final Map<Integer, PropsTree> fields = new TreeMap<>(Integer::compareUnsigned);
        final Map<OpId, PropsTree> elements = new HashMap<>();
        List<OpId> order;
        TextSequence text;

        PropsTree child(RegisterPath.Segment segment) {
            return segment.isElement() ? elements.computeIfAbsent(segment.element(), e -> new PropsTree())
                    : fields.computeIfAbsent(segment.field(), f -> new PropsTree());
        }

        PropsTree at(RegisterPath path) {
            PropsTree current = this;
            for (RegisterPath.Segment segment : path.segments()) {
                current = current.child(segment);
            }
            return current;
        }

        byte[] encode() {
            WireWriter out = new WireWriter();
            fields.forEach((number, child) -> {
                if (child.leaf != null) {
                    out.raw(child.leaf);
                } else if (child.order != null) {
                    for (OpId id : child.order) {
                        WireWriter element = new WireWriter();
                        element.idField(1, id);
                        PropsTree fieldsOf = child.elements.get(id);
                        element.raw(fieldsOf == null ? new byte[0] : fieldsOf.encode());
                        out.lenField(number, element.bytes());
                    }
                } else if (child.text != null) {
                    out.lenField(number, richText(child.text, child));
                } else {
                    out.lenField(number, child.encode());
                }
            });
            return out.bytes();
        }

        private static byte[] richText(TextSequence text, PropsTree container) {
            WireWriter out = new WireWriter();
            for (OpId c : text.order()) {
                TextSequence.Origins origins = text.origins(c);
                WireWriter entry = new WireWriter();
                entry.idField(1, c);
                entry.varintField(2, Integer.toUnsignedLong(text.codepoint(c)));
                entry.varintField(3, text.isDeleted(c) ? 1 : 0);
                entry.optionalIdField(4, origins.left());
                entry.optionalIdField(5, origins.right());
                PropsTree fieldsOf = container.elements.get(c);
                entry.raw(fieldsOf == null ? new byte[0] : fieldsOf.encode());
                out.lenField(PathResolver.CHARS_FIELD, entry.bytes());
            }
            for (TextMark mark : text.sortedMarks()) {
                WireWriter entry = new WireWriter();
                entry.idField(1, mark.id());
                entry.lenField(2, anchor(mark.start()));
                entry.lenField(3, anchor(mark.end()));
                entry.lenField(4, mark.valueBytes());
                out.lenField(2, entry.bytes());
            }
            return out.bytes();
        }

        private static byte[] anchor(Anchor anchor) {
            WireWriter out = new WireWriter();
            out.optionalIdField(1, anchor.character());
            out.varintField(2, anchor.before() ? 1 : 0);
            return out.bytes();
        }
    }

    // Every node a snapshot holds has a kind: a created node, or the document or settings node.
    private static byte[] props(NodeStore store, OpId node) {
        int kind = store.kind(node);
        PropsTree root = new PropsTree();
        root.child(RegisterPath.Segment.field(kind));
        for (RegisterPath path : store.textPaths(node)) {
            root.at(path).text = store.text(node, path);
        }
        Set<RegisterPath> sequences = new HashSet<>();
        for (RegisterPath path : store.elements(node).keySet()) {
            root.at(path);
            sequences.add(path.parent());
        }
        for (RegisterPath sequence : sequences) {
            root.at(sequence).order = store.elementOrder(node, sequence);
        }
        store.registers(node).forEach((path, register) -> {
            if (register.isSet()) {
                root.at(path).leaf = register.value();
            }
        });
        return root.encode();
    }

    // ---- Decoding

    /**
     * The state {@code bytes} (a {@code DocumentSnapshot}) holds, merging with {@code schema}.
     *
     * @throws SnapshotException when the bytes are not a snapshot or the decoded state does not
     *     have the snapshot's {@code state_hash}
     */
    public static Engine decode(byte[] bytes, Schema schema) throws SnapshotException {
        WireMessage snapshot = message(bytes);
        NodeStore store = new NodeStore();
        Engine engine = new Engine(schema, store);
        Map<OpId, Placement> placements = new HashMap<>();
        for (byte[] node : snapshot.payloads(2)) {
            readNode(node, store, engine.resolver(), schema, placements);
        }
        List<MoveLogEntry> log = new ArrayList<>();
        for (byte[] entryBytes : snapshot.payloads(3)) {
            WireMessage entry = message(entryBytes);
            OpId op = id(entry, 1);
            OpId node = id(entry, 2);
            Placement old = entry.has(3) ? new Placement(id(entry, 3), payload(entry, 4), id(entry, MOVE_OLD_OP)) : null;
            log.add(new MoveLogEntry(op, node, id(entry, 5), payload(entry, 6), op.equals(node), old, entry.lastVarint(7) != 0));
        }
        for (byte[] replica : snapshot.payloads(4)) {
            WireMessage entry = message(replica);
            store.restoreReplica(entry.lastFixed64(1),
                    new ReplicaState(entry.lastVarint(2), entry.lastVarint(3), entry.lastVarint(4)));
        }
        for (byte[] sequenced : snapshot.payloads(SEQUENCED)) {
            WireMessage entry = message(sequenced);
            store.restoreChange(entry.lastFixed64(1), entry.lastVarint(2), entry.lastVarint(3), entry.lastVarint(4));
        }
        store.restoreStableSeq(snapshot.lastVarint(5));
        engine.restoreClock(snapshot.lastVarint(6));
        store.restoreTree(new Tree(log, placements, store.createdNodes()));
        byte[] hash = snapshot.lastPayload(8);
        if (hash != null && !Arrays.equals(hash, engine.stateHash())) {
            throw new SnapshotException("state_hash " + Bytes.hex(hash) + " does not match the decoded state's "
                    + Bytes.hex(engine.stateHash()));
        }
        return engine;
    }

    /** The {@code state_hash} an encoded snapshot carries, or {@code null} when it has none or does not parse. */
    public static byte[] stateHash(byte[] bytes) {
        WireMessage snapshot = WireMessage.parse(bytes);
        return snapshot == null ? null : snapshot.lastPayload(8);
    }

    private static void readNode(byte[] bytes, NodeStore store, PathResolver resolver, Schema schema,
            Map<OpId, Placement> placements) throws SnapshotException {
        WireMessage state = message(bytes);
        WireMessage plain = message(payload(state, 1));
        OpId id = id(plain, 1);
        WireMessage props = message(payload(plain, 5));
        Integer kind = props.lastField();
        boolean wellKnown = Tree.isWellKnown(id);
        if (!wellKnown && kind != null) {
            store.restoreNode(id, kind);
        }
        if (plain.has(2) && !wellKnown) {
            placements.put(id, new Placement(id(plain, 2), payload(plain, 3), id(state, 2)));
        }
        if (state.has(3)) {
            store.restoreDeleted(id, plain.lastVarint(4) != 0, id(state, 3), state.lastVarint(NODE_DELETED_TIME));
        }
        Set<RegisterPath> textPaths = new HashSet<>();
        for (byte[] path : state.payloads(NODE_TEXTS)) {
            textPaths.add(path(path));
        }
        PropsReader reader = new PropsReader(props, textPaths);
        for (byte[] stampBytes : state.payloads(4)) {
            WireMessage stamp = message(stampBytes);
            RegisterPath path = path(payload(stamp, 1));
            byte[] value = null;
            WireMessage container = path.last().isElement() || path.parent() == null ? null : reader.message(path.parent());
            if (container != null) {
                value = container.records(path.last().field());
            }
            store.restoreRegister(id, path, new Register(value, id(stamp, 2)));
        }
        Map<RegisterPath, OpId> charDeletes = new HashMap<>();
        for (byte[] entryBytes : state.payloads(5)) {
            WireMessage entry = message(entryBytes);
            RegisterPath path = path(payload(entry, 1));
            if (!path.last().isElement() || path.parent() == null) {
                continue;
            }
            OpId deletedOp = entry.has(5) ? id(entry, 5) : null;
            if (textPaths.contains(path.parent())) {
                if (deletedOp != null) {
                    charDeletes.put(path, deletedOp);
                }
                continue;
            }
            Element element = new Element(payload(entry, 2), entry.has(3) ? id(entry, 3) : path.last().element());
            if (deletedOp != null) {
                element.delete(entry.lastVarint(4) != 0, deletedOp);
            }
            store.restoreElement(id, path, element);
        }
        for (RegisterPath path : textPaths) {
            Integer featureField = null;
            RegisterPath.Segment first = path.segments().get(0);
            PathResolver.Target target = first.isElement() ? null
                    : resolver.walk(first.field(), path.toProto(), null, at -> true);
            if (target != null && target.isField()) {
                featureField = schema.featureField(target.row());
            }
            store.restoreText(id, path, text(reader.message(path), path, charDeletes, featureField));
        }
        for (byte[] setBytes : state.payloads(NODE_SETS)) {
            WireMessage set = message(setBytes);
            RegisterPath path = path(payload(set, 1));
            for (byte[] memberBytes : set.payloads(2)) {
                WireMessage member = message(memberBytes);
                List<NodeStore.SetAddition> adds = new ArrayList<>();
                for (byte[] add : member.payloads(2)) {
                    WireMessage tag = message(add);
                    adds.add(new NodeStore.SetAddition(id(tag, 1), tag.lastVarint(2)));
                }
                List<NodeStore.SetRemoval> removes = new ArrayList<>();
                for (byte[] removal : member.payloads(3)) {
                    WireMessage tag = message(removal);
                    removes.add(new NodeStore.SetRemoval(id(tag, 1), tag.lastVarint(2), tag.lastVarint(3)));
                }
                store.restoreMember(id, path, new NodeStore.MemberEntry(payload(member, 1), adds, removes));
            }
        }
    }

    private static TextSequence text(WireMessage richText, RegisterPath path, Map<RegisterPath, OpId> deletes,
            Integer featureField) throws SnapshotException {
        List<TextSequence.RestoredChar> chars = new ArrayList<>();
        List<TextMark> marks = new ArrayList<>();
        if (richText != null) {
            for (byte[] charBytes : richText.payloads(PathResolver.CHARS_FIELD)) {
                WireMessage c = message(charBytes);
                OpId id = id(c, 1);
                chars.add(new TextSequence.RestoredChar(id, (int) c.lastVarint(2), id(c, 4), id(c, 5),
                        deletes.get(path.element(id))));
            }
            for (byte[] markBytes : richText.payloads(2)) {
                WireMessage mark = message(markBytes);
                byte[] value = payload(mark, 4);
                marks.add(new TextMark(id(mark, 1), anchor(mark, 2), anchor(mark, 3), value,
                        MarkValue.key(value, featureField)));
            }
        }
        return TextSequence.restore(chars, marks);
    }

    private static Anchor anchor(WireMessage mark, int number) throws SnapshotException {
        WireMessage anchor = message(payload(mark, number));
        return new Anchor(id(anchor, 1), anchor.lastVarint(2) != 0);
    }

    static WireMessage message(byte[] bytes) throws SnapshotException {
        WireMessage message = WireMessage.parse(bytes);
        if (message == null) {
            throw new SnapshotException("a snapshot message does not parse");
        }
        return message;
    }

    private static byte[] payload(WireMessage message, int number) {
        byte[] payload = message.lastPayload(number);
        return payload == null ? new byte[0] : payload;
    }

    /** The {@code OpId}/{@code ElementId} in field {@code number} of {@code message} (zero when absent). */
    static OpId id(WireMessage message, int number) throws SnapshotException {
        byte[] bytes = message.lastPayload(number);
        if (bytes == null) {
            return OpId.ZERO;
        }
        WireMessage id = message(bytes);
        return new OpId(id.lastVarint(1), id.lastFixed64(2));
    }

    static RegisterPath path(byte[] bytes) throws SnapshotException {
        WireMessage message = message(bytes);
        List<RegisterPath.Segment> segments = new ArrayList<>();
        for (byte[] segment : message.payloads(1)) {
            WireMessage wire = message(segment);
            segments.add(wire.has(2) ? RegisterPath.Segment.element(id(wire, 2))
                    : RegisterPath.Segment.field((int) wire.lastVarint(1)));
        }
        if (segments.isEmpty()) {
            throw new SnapshotException("an empty path");
        }
        return RegisterPath.of(segments);
    }

    /** Finds the message at a path inside {@code Node.props}, indexing each field's elements on first use. */
    private static final class PropsReader {
        private final WireMessage props;
        private final Set<RegisterPath> texts;
        private final Map<RegisterPath, WireMessage> messages = new HashMap<>();
        private final Map<RegisterPath, Map<OpId, WireMessage>> elements = new HashMap<>();

        PropsReader(WireMessage props, Set<RegisterPath> texts) {
            this.props = props;
            this.texts = texts;
        }

        /** The message at {@code path} (ending at a message field or an element), or {@code null}. */
        WireMessage message(RegisterPath path) {
            if (messages.containsKey(path)) {
                return messages.get(path);
            }
            WireMessage found;
            RegisterPath.Segment last = path.last();
            if (last.isElement()) {
                found = elementIndex(path.parent()).get(last.element());
            } else {
                WireMessage parent = path.parent() == null ? props : message(path.parent());
                found = parent == null ? null : parent.message(last.field());
            }
            messages.put(path, found);
            return found;
        }

        private Map<OpId, WireMessage> elementIndex(RegisterPath container) {
            Map<OpId, WireMessage> cached = elements.get(container);
            if (cached != null) {
                return cached;
            }
            Map<OpId, WireMessage> index = new HashMap<>();
            if (!container.last().isElement()) {
                WireMessage holder;
                int number;
                if (texts.contains(container)) {
                    holder = message(container);
                    number = PathResolver.CHARS_FIELD;
                } else {
                    holder = container.parent() == null ? props : message(container.parent());
                    number = container.last().field();
                }
                for (WireMessage occurrence : holder == null ? List.<WireMessage>of() : holder.occurrences(number)) {
                    if (occurrence != null) {
                        byte[] idBytes = occurrence.lastPayload(1);
                        WireMessage id = idBytes == null ? null : WireMessage.parse(idBytes);
                        index.put(id == null ? OpId.ZERO : new OpId(id.lastVarint(1), id.lastFixed64(2)), occurrence);
                    }
                }
            }
            elements.put(container, index);
            return index;
        }
    }
}
