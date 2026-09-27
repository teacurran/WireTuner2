package com.villagecompute.wiretuner.crdt;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.ElementIdRange;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.TextMarkValue;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Predicate;

/**
 * The inverse of a local change (crdt-model.adoc, "Undo"; CRDT-008), recorded against the state
 * just before each op, mirroring {@code WTCRDT.Inverse}: the prior {@code (value, OpId)} of every
 * register written, the prior parent and position of each moved node, the inserted element and
 * character ids, the deleted characters with their content. {@link Engine#undoChange} turns it
 * into the change that undoes it.
 */
public record Inverse(List<Step> steps) {

    /**
     * This inverse followed by {@code later}: the inverse of this change and then {@code later}
     * applied as one unit, which {@link Engine#undoChange} undoes together.
     */
    public Inverse followed(Inverse later) {
        List<Step> joined = new ArrayList<>(steps);
        joined.addAll(later.steps());
        return new Inverse(List.copyOf(joined));
    }

    /** Whether the change changed nothing undoable. */
    public boolean isEmpty() {
        return steps.isEmpty();
    }

    /** One undoable effect of one op, in application order. */
    public sealed interface Step permits Created, RegisterStep, PlacementStep, Deleted, ElementInserted, ElementPosition,
            ElementDeleted, MemberAdded, MemberRemoved, TextInserted, TextDeleted, TextMarked {
    }

    /** A {@code CreateNode} made {@code node}; undo deletes it. */
    public record Created(OpId node) implements Step {
    }

    /** A register write; undo restores {@code prior} ({@code null}: never written, restored as unset). */
    public record RegisterStep(OpId node, RegisterPath path, Register prior, OpId wrote) implements Step {
    }

    /** A {@code MoveNode}; undo moves the node back. */
    public record PlacementStep(OpId node, Placement prior, OpId wrote) implements Step {
    }

    /** A {@code SetDeleted}; undo writes the prior flag (false when never written). */
    public record Deleted(OpId node, Stamped<Boolean> prior, OpId wrote) implements Step {
    }

    /** An {@code ElementInsert} element; undo deletes it. */
    public record ElementInserted(OpId node, RegisterPath element) implements Step {
    }

    /** An {@code ElementMove}; undo moves the element back. */
    public record ElementPosition(OpId node, RegisterPath element, Stamped<byte[]> prior, OpId wrote) implements Step {
    }

    /** An {@code ElementDelete}; undo writes the prior flag (false when never written). */
    public record ElementDeleted(OpId node, RegisterPath element, Stamped<Boolean> prior, OpId wrote) implements Step {
    }

    /** A {@code SetAdd} of a member ({@code wasPresent}: whether it was a member before); undo removes it. */
    public record MemberAdded(OpId node, RegisterPath set, byte[] member, OpId tag, boolean wasPresent, MemberField field)
            implements Step {

        @Override
        public boolean equals(Object other) {
            return other instanceof MemberAdded(var thatNode, var thatSet, var thatMember, var thatTag,
                    var thatWasPresent, var thatField)
                    && Objects.equals(node, thatNode)
                    && Objects.equals(set, thatSet)
                    && Arrays.equals(member, thatMember)
                    && Objects.equals(tag, thatTag)
                    && wasPresent == thatWasPresent
                    && Objects.equals(field, thatField);
        }

        @Override
        public int hashCode() {
            return Objects.hash(node, set, Arrays.hashCode(member), tag, wasPresent, field);
        }

        /** {@inheritDoc} Byte arrays show as hex. */
        @Override
        public String toString() {
            return "MemberAdded[node=" + node
                    + ", set=" + set
                    + ", member=" + Bytes.show(member)
                    + ", tag=" + tag
                    + ", wasPresent=" + wasPresent
                    + ", field=" + field + "]";
        }
    }

    /** A {@code SetRemove} that took a member out; undo adds it back. */
    public record MemberRemoved(OpId node, RegisterPath set, byte[] member, MemberField field) implements Step {

        @Override
        public boolean equals(Object other) {
            return other instanceof MemberRemoved(var thatNode, var thatSet, var thatMember, var thatField)
                    && Objects.equals(node, thatNode)
                    && Objects.equals(set, thatSet)
                    && Arrays.equals(member, thatMember)
                    && Objects.equals(field, thatField);
        }

        @Override
        public int hashCode() {
            return Objects.hash(node, set, Arrays.hashCode(member), field);
        }

        /** {@inheritDoc} Byte arrays show as hex. */
        @Override
        public String toString() {
            return "MemberRemoved[node=" + node
                    + ", set=" + set
                    + ", member=" + Bytes.show(member)
                    + ", field=" + field + "]";
        }
    }

    /** A {@code TextInsert}; undo deletes the characters. */
    public record TextInserted(OpId node, RegisterPath text, List<OpId> chars) implements Step {
    }

    /** A {@code TextDelete}; undo re-inserts the text as new characters at the original place. */
    public record TextDeleted(OpId node, RegisterPath text, List<DeletedChar> chars) implements Step {
    }

    /** A {@code TextMark}; undo re-applies each character's prior value of the attribute. */
    public record TextMarked(OpId node, RegisterPath text, OpId mark, MarkKey key, byte[] value, List<PriorFormat> prior)
            implements Step {

        @Override
        public boolean equals(Object other) {
            return other instanceof TextMarked(var thatNode, var thatText, var thatMark, var thatKey, var thatValue,
                    var thatPrior)
                    && Objects.equals(node, thatNode)
                    && Objects.equals(text, thatText)
                    && Objects.equals(mark, thatMark)
                    && Objects.equals(key, thatKey)
                    && Arrays.equals(value, thatValue)
                    && Objects.equals(prior, thatPrior);
        }

        @Override
        public int hashCode() {
            return Objects.hash(node, text, mark, key, Arrays.hashCode(value), prior);
        }

        /** {@inheritDoc} Byte arrays show as hex. */
        @Override
        public String toString() {
            return "TextMarked[node=" + node
                    + ", text=" + text
                    + ", mark=" + mark
                    + ", key=" + key
                    + ", value=" + Bytes.show(value)
                    + ", prior=" + prior + "]";
        }
    }

    /** How a SET field encodes its members, so an inverse can write one back. */
    public record MemberField(int number, String type, String typeName) {

        static MemberField of(FieldPolicy row) {
            return new MemberField(row.fieldNumber(), row.type(), row.typeName());
        }

        /** The protobuf record holding {@code member} (a canonical member, crdt-model.adoc "Sets"). */
        byte[] record(byte[] member) {
            WireWriter out = new WireWriter();
            if (type.equals("message")) {
                out.idField(number, new OpId(u64(member, 0), u64(member, 8)));
            } else if (type.equals("string") || type.equals("bytes")) {
                out.lenField(number, member);
            } else if (member.length == 8 && (type.equals("fixed64") || type.equals("sfixed64") || type.equals("double"))) {
                out.tag(number, WireMessage.FIXED64);
                out.raw(member);
            } else if (member.length == 4) {
                out.tag(number, WireMessage.FIXED32);
                out.raw(member);
            } else {
                out.varintField(number, u64(member, 0), true);
            }
            return out.bytes();
        }

        private static long u64(byte[] bytes, int offset) {
            long value = 0;
            for (int i = offset; i < offset + 8; i++) {
                value = value << 8 | (bytes[i] & 0xFF);
            }
            return value;
        }
    }

    /** One register beneath a deleted newline: the path after the character's element segment, and its value. */
    public record ParagraphRegister(List<RegisterPath.Segment> suffix, byte[] value) {

        @Override
        public boolean equals(Object other) {
            return other instanceof ParagraphRegister(var thatSuffix, var thatValue)
                    && Objects.equals(suffix, thatSuffix)
                    && Arrays.equals(value, thatValue);
        }

        @Override
        public int hashCode() {
            return Objects.hash(suffix, Arrays.hashCode(value));
        }

        /** {@inheritDoc} Byte arrays show as hex. */
        @Override
        public String toString() {
            return "ParagraphRegister[suffix=" + suffix
                    + ", value=" + Bytes.show(value) + "]";
        }
    }

    /** A character a local {@code TextDelete} deleted, with its scalar, attribute values and paragraph registers. */
    public record DeletedChar(OpId id, int scalar, List<byte[]> attributes, List<ParagraphRegister> paragraph) {
    }

    /** What formatted a character before a local mark: the winning value of its attribute ({@code null}: none). */
    public record PriorFormat(OpId character, byte[] value) {

        @Override
        public boolean equals(Object other) {
            return other instanceof PriorFormat(var thatCharacter, var thatValue)
                    && Objects.equals(character, thatCharacter)
                    && Arrays.equals(value, thatValue);
        }

        @Override
        public int hashCode() {
            return Objects.hash(character, Arrays.hashCode(value));
        }

        /** {@inheritDoc} Byte arrays show as hex. */
        @Override
        public String toString() {
            return "PriorFormat[character=" + character
                    + ", value=" + Bytes.show(value) + "]";
        }
    }

    // ---- Undo

    /**
     * The change undoing {@code inverse} (see {@code WTCRDT.EngineState.undoChange}): undone as a
     * unit, where several ops wrote one target the value before the first is restored if no other
     * replica has written it since the last (the state holds that write or a later one of this
     * replica's); characters the change inserted are not re-inserted; a target that no longer
     * exists (collected, CRDT-010) is skipped.
     */
    static Change undoChange(Engine engine, Inverse inverse, long replica, long seq, long startCounter, long baseServerSeq,
            String label) {
        Builder builder = new Builder(engine.store(), inverse, replica, startCounter);
        List<Step> steps = inverse.steps();
        for (int i = steps.size() - 1; i >= 0; i--) {
            builder.undo(steps.get(i), i);
        }
        if (builder.ops.isEmpty()) {
            return null;
        }
        return Change.newBuilder().setReplica(replica).setSeq(seq).setStartCounter(startCounter)
                .setBaseServerSeq(baseServerSeq).setLabel(label).addAllOps(builder.ops).build();
    }

    /** What one step targets, so the steps of one change touching the same thing undo as one. */
    private record StepKey(String kind, OpId node, RegisterPath path, java.nio.ByteBuffer member) {

        static StepKey of(Step step) {
            return switch (step) {
                case RegisterStep s -> new StepKey("register", s.node(), s.path(), null);
                case PlacementStep s -> new StepKey("placement", s.node(), null, null);
                case Deleted s -> new StepKey("deleted", s.node(), null, null);
                case ElementPosition s -> new StepKey("position", s.node(), s.element(), null);
                case ElementDeleted s -> new StepKey("elementDeleted", s.node(), s.element(), null);
                case MemberAdded s -> new StepKey("member", s.node(), s.set(), java.nio.ByteBuffer.wrap(s.member()));
                case MemberRemoved s -> new StepKey("member", s.node(), s.set(), java.nio.ByteBuffer.wrap(s.member()));
                default -> null;
            };
        }
    }

    /** Builds the ops of an undo change, numbering them as it goes. */
    private static final class Builder {
        private final NodeStore store;
        private final long replica;
        private long counter;
        private final List<Op> ops = new ArrayList<>();
        private final Map<StepKey, Step> first = new java.util.HashMap<>();
        private final Map<StepKey, Integer> last = new java.util.HashMap<>();
        private final java.util.Set<OpId> wrote = new java.util.HashSet<>();
        private final java.util.Set<OpId> inserted = new java.util.HashSet<>();
        private final Map<StepKey, java.util.Set<OpId>> tags = new java.util.HashMap<>();

        Builder(NodeStore store, Inverse inverse, long replica, long counter) {
            this.store = store;
            this.replica = replica;
            this.counter = counter;
            List<Step> steps = inverse.steps();
            for (int index = 0; index < steps.size(); index++) {
                Step step = steps.get(index);
                StepKey key = StepKey.of(step);
                if (key != null) {
                    first.putIfAbsent(key, step);
                    last.put(key, index);
                }
                switch (step) {
                    case Deleted deleted -> wrote.add(deleted.wrote());
                    case ElementDeleted deleted -> wrote.add(deleted.wrote());
                    case TextInserted textInserted -> inserted.addAll(textInserted.chars());
                    case MemberAdded added -> tags.computeIfAbsent(key, k -> new java.util.HashSet<>()).add(added.tag());
                    default -> {
                        // Other steps carry nothing the others need.
                    }
                }
            }
        }

        void add(Op op) {
            ops.add(op);
            counter += Engine.counters(op);
        }

        // Whether the write holding a target is `wrote` or a later one by this replica.
        private boolean ours(OpId holder, OpId wrote) {
            return holder.equals(wrote) || holder.replica() == replica;
        }

        private boolean oursOrThisChange(Cell<Boolean> flag) {
            return flag == null || wrote.contains(flag.current().op()) || flag.current().op().replica() == replica;
        }

        void undo(Step step, int index) {
            StepKey key = StepKey.of(step);
            if (key != null) {
                if (last.get(key) == index) {
                    undoLast(step, first.get(key), key);
                }
                return;
            }
            switch (step) {
                case Created created -> {
                    if (store.isCreated(created.node()) && oursOrThisChange(store.deleted(created.node()))) {
                        add(Ops.setDeleted(created.node(), true));
                    }
                }
                case ElementInserted elementInserted -> {
                    Element element = store.element(elementInserted.node(), elementInserted.element());
                    if (element != null && oursOrThisChange(element.deleted())) {
                        add(Ops.elementDelete(elementInserted.node(), elementInserted.element(), true));
                    }
                }
                case TextInserted textInserted -> {
                    TextSequence text = store.text(textInserted.node(), textInserted.text());
                    List<OpId> live = text == null ? List.of()
                            : textInserted.chars().stream().filter(c -> text.contains(c) && !text.isDeleted(c)).toList();
                    if (!live.isEmpty()) {
                        add(Ops.textDelete(textInserted.node(), textInserted.text(), live));
                    }
                }
                case TextDeleted deleted -> reinsert(deleted.node(), deleted.text(),
                        deleted.chars().stream().filter(c -> !inserted.contains(c.id())).toList());
                case TextMarked marked -> remark(marked);
                default -> {
                    // Keyed steps are undone above.
                }
            }
        }

        // The last step of one target: restore the value before the change's first step, if the
        // state still holds this step's write.
        private void undoLast(Step step, Step earliest, StepKey key) {
            switch (step) {
                case RegisterStep register -> {
                    Register current = store.register(register.node(), register.path());
                    Register prior = ((RegisterStep) earliest).prior();
                    if (current != null && ours(current.op(), register.wrote())) {
                        add(Ops.setFields(register.node(), register.path(),
                                values(register.node(), register.path(), prior == null ? null : prior.value())));
                    }
                }
                case PlacementStep placement -> {
                    Placement current = store.placement(placement.node());
                    Placement prior = ((PlacementStep) earliest).prior();
                    if (current != null && ours(current.op(), placement.wrote()) && prior != null) {
                        add(Ops.move(placement.node(), prior.parent(), prior.position()));
                    }
                }
                case Deleted deleted -> {
                    Stamped<Boolean> prior = ((Deleted) earliest).prior();
                    Cell<Boolean> flag = store.deleted(deleted.node());
                    if (flag != null && ours(flag.current().op(), deleted.wrote())) {
                        add(Ops.setDeleted(deleted.node(), prior != null && prior.value()));
                    }
                }
                case ElementPosition position -> {
                    Element element = store.element(position.node(), position.element());
                    if (element != null && ours(element.position().current().op(), position.wrote())) {
                        add(Ops.elementMove(position.node(), position.element(), ((ElementPosition) earliest).prior().value()));
                    }
                }
                case ElementDeleted deleted -> {
                    Element element = store.element(deleted.node(), deleted.element());
                    Stamped<Boolean> prior = ((ElementDeleted) earliest).prior();
                    if (element != null && ours(element.deleted().current().op(), deleted.wrote())) {
                        add(Ops.elementDelete(deleted.node(), deleted.element(), prior != null && prior.value()));
                    }
                }
                case MemberAdded added -> undoMember(added.node(), added.set(), added.member(), added.field(), earliest, key);
                case MemberRemoved removed -> undoMember(removed.node(), removed.set(), removed.member(), removed.field(),
                        earliest, key);
                default -> {
                    // A key's steps are all of one kind.
                }
            }
        }

        // A member the change added or removed: added back when it was a member before and is none
        // now; removed when it was none before and only the change's adds hold it now.
        private void undoMember(OpId node, RegisterPath set, byte[] member, MemberField field, Step earliest, StepKey key) {
            boolean wasPresent = !(earliest instanceof MemberAdded added) || added.wasPresent();
            java.util.Set<OpId> live = new java.util.HashSet<>(store.liveTags(node, set, member));
            byte[] values = values(node, set, field.record(member));
            if (wasPresent && live.isEmpty()) {
                add(Ops.setAdd(node, set, values));
            } else if (!wasPresent && !live.isEmpty() && live.stream().allMatch(
                    tag -> tags.getOrDefault(key, java.util.Set.of()).contains(tag) || tag.replica() == replica)) {
                add(Ops.setRemove(node, set, values));
            }
        }

        // Re-inserts deleted characters as new ones, run by run.
        private void reinsert(OpId node, RegisterPath path, List<DeletedChar> chars) {
            TextSequence text = store.text(node, path);
            if (text == null) {
                return;
            }
            Map<OpId, Integer> index = text.orderIndex();
            List<DeletedChar> present = new ArrayList<>(chars.stream().filter(c -> index.containsKey(c.id())).toList());
            present.sort((a, b) -> Integer.compare(index.get(a.id()), index.get(b.id())));
            List<List<DeletedChar>> runs = new ArrayList<>();
            for (DeletedChar c : present) {
                List<DeletedChar> run = runs.isEmpty() ? null : runs.get(runs.size() - 1);
                if (run != null && index.get(run.get(run.size() - 1).id()) + 1 == index.get(c.id())) {
                    run.add(c);
                } else {
                    runs.add(new ArrayList<>(List.of(c)));
                }
            }
            for (List<DeletedChar> run : runs) {
                long base = counter;
                OpId tail = run.get(run.size() - 1).id();
                add(Ops.textInsert(node, path, tail, text.successor(tail), run.stream().mapToInt(DeletedChar::scalar).toArray()));
                List<OpId> ids = new ArrayList<>();
                for (int i = 0; i < run.size(); i++) {
                    ids.add(new OpId(base + i, replica));
                }
                List<byte[]> formats = new ArrayList<>();
                for (DeletedChar c : run) {
                    for (byte[] value : c.attributes()) {
                        if (formats.stream().noneMatch(seen -> Arrays.equals(seen, value))) {
                            formats.add(value);
                        }
                    }
                }
                for (byte[] value : formats) {
                    int start = -1;
                    for (int i = 0; i <= run.size(); i++) {
                        boolean has = i < run.size() && run.get(i).attributes().stream().anyMatch(v -> Arrays.equals(v, value));
                        if (has && start < 0) {
                            start = i;
                        } else if (!has && start >= 0) {
                            add(Ops.textMark(node, path, new Anchor(ids.get(start), true), new Anchor(ids.get(i - 1), false), value));
                            start = -1;
                        }
                    }
                }
                for (int i = 0; i < run.size(); i++) {
                    for (ParagraphRegister register : run.get(i).paragraph()) {
                        List<RegisterPath.Segment> segments = new ArrayList<>(path.segments());
                        segments.add(RegisterPath.Segment.element(ids.get(i)));
                        segments.addAll(register.suffix());
                        RegisterPath target = RegisterPath.of(segments);
                        add(Ops.setFields(node, target, values(node, target, register.value())));
                    }
                }
            }
        }

        // Re-applies the prior value of a mark's attribute on the characters the mark still wins.
        private void remark(TextMarked marked) {
            TextSequence text = store.text(marked.node(), marked.text());
            if (text == null) {
                return;
            }
            Map<OpId, TextMark> winners = text.winners(marked.key(),
                    marked.prior().stream().map(PriorFormat::character).toList());
            List<PriorFormat> still = new ArrayList<>(marked.prior().stream()
                    .filter(p -> winners.containsKey(p.character()) && ours(winners.get(p.character()).id(), marked.mark())
                            && !text.isDeleted(p.character()))
                    .toList());
            still.sort((a, b) -> Integer.compare(text.offset(a.character()), text.offset(b.character())));
            int index = 0;
            while (index < still.size()) {
                int end = index;
                while (end + 1 < still.size()
                        && text.offset(still.get(end + 1).character()) == text.offset(still.get(end).character()) + 1
                        && Arrays.equals(still.get(end + 1).value(), still.get(index).value())) {
                    end++;
                }
                byte[] prior = still.get(index).value();
                byte[] restored = prior != null ? prior : MarkValue.cleared(marked.value(), marked.key());
                add(Ops.textMark(marked.node(), marked.text(), new Anchor(still.get(index).character(), true),
                        new Anchor(still.get(end).character(), false), restored));
                index = end + 1;
            }
        }

        private byte[] values(OpId node, RegisterPath path, byte[] records) {
            return Values.wrap(path, records, prefix -> store.text(node, prefix) != null);
        }
    }

    /** Sparse {@code NodeProps} values holding one register's records. */
    static final class Values {

        private Values() {
        }

        /**
         * Wraps {@code records} (the last field's records) in the messages of {@code path}'s other
         * field segments; an element segment adds nothing, except after a TEXT field, where the
         * character sits in {@code RichText.chars}. {@code null} records give empty values.
         */
        static byte[] wrap(RegisterPath path, byte[] records, Predicate<RegisterPath> isText) {
            if (records == null) {
                return new byte[0];
            }
            byte[] content = records;
            List<RegisterPath.Segment> segments = path.segments();
            for (int index = segments.size() - 2; index >= 0; index--) {
                RegisterPath.Segment segment = segments.get(index);
                WireWriter out = new WireWriter();
                if (!segment.isElement()) {
                    out.lenField(segment.field(), content);
                    content = out.bytes();
                } else if (isText.test(RegisterPath.of(segments.subList(0, index)))) {
                    out.lenField(PathResolver.CHARS_FIELD, content);
                    content = out.bytes();
                }
            }
            return content;
        }
    }

    /** Builders for the ops an undo change holds. */
    static final class Ops {

        private Ops() {
        }

        private static NodeProps props(byte[] bytes) {
            try {
                return NodeProps.parseFrom(bytes);
            } catch (InvalidProtocolBufferException e) {
                // Values the engine wrote itself always parse.
                throw new IllegalStateException(e);
            }
        }

        private static ElementId elementId(OpId id) {
            return ElementId.newBuilder().setCounter(id.counter()).setReplica(id.replica()).build();
        }

        static Op setDeleted(OpId node, boolean deleted) {
            return Op.newBuilder().setSetDeleted(com.villagecompute.wiretuner.doc.v1.SetDeleted.newBuilder()
                    .setNode(node.toProto()).setDeleted(deleted)).build();
        }

        static Op setFields(OpId node, RegisterPath path, byte[] values) {
            return Op.newBuilder().setSet(com.villagecompute.wiretuner.doc.v1.SetFields.newBuilder()
                    .setNode(node.toProto()).addPaths(path.toProto()).setValues(props(values))).build();
        }

        static Op move(OpId node, OpId parent, byte[] position) {
            return Op.newBuilder().setMove(com.villagecompute.wiretuner.doc.v1.MoveNode.newBuilder()
                    .setNode(node.toProto()).setParent(parent.toProto()).setPosition(ByteString.copyFrom(position))).build();
        }

        static Op elementMove(OpId node, RegisterPath element, byte[] position) {
            return Op.newBuilder().setElementMove(com.villagecompute.wiretuner.doc.v1.ElementMove.newBuilder()
                    .setNode(node.toProto()).setElement(element.toProto()).setPosition(ByteString.copyFrom(position))).build();
        }

        static Op elementDelete(OpId node, RegisterPath element, boolean deleted) {
            return Op.newBuilder().setElementDelete(com.villagecompute.wiretuner.doc.v1.ElementDelete.newBuilder()
                    .setNode(node.toProto()).addElements(element.toProto()).setDeleted(deleted)).build();
        }

        static Op setAdd(OpId node, RegisterPath set, byte[] values) {
            return Op.newBuilder().setSetAdd(com.villagecompute.wiretuner.doc.v1.SetAdd.newBuilder()
                    .setNode(node.toProto()).setSet(set.toProto()).setValues(props(values))).build();
        }

        static Op setRemove(OpId node, RegisterPath set, byte[] values) {
            return Op.newBuilder().setSetRemove(com.villagecompute.wiretuner.doc.v1.SetRemove.newBuilder()
                    .setNode(node.toProto()).setSet(set.toProto()).setValues(props(values))).build();
        }

        static Op textInsert(OpId node, RegisterPath text, OpId left, OpId right, int[] scalars) {
            StringBuilder chars = new StringBuilder();
            for (int scalar : scalars) {
                chars.appendCodePoint(Character.isValidCodePoint(scalar) ? scalar : 0xFFFD);
            }
            return Op.newBuilder().setTextInsert(com.villagecompute.wiretuner.doc.v1.TextInsert.newBuilder()
                    .setNode(node.toProto()).setText(text.toProto()).setLeftOrigin(elementId(left))
                    .setRightOrigin(elementId(right)).setChars(chars.toString())).build();
        }

        /** A {@code TextDelete} of {@code chars}, as runs of consecutive ids. */
        static Op textDelete(OpId node, RegisterPath text, List<OpId> chars) {
            List<OpId> sorted = new ArrayList<>(chars);
            sorted.sort(null);
            List<ElementIdRange.Builder> ranges = new ArrayList<>();
            for (OpId c : sorted) {
                ElementIdRange.Builder last = ranges.isEmpty() ? null : ranges.get(ranges.size() - 1);
                if (last != null && last.getFirst().getReplica() == c.replica()
                        && last.getFirst().getCounter() + last.getCount() == c.counter()) {
                    last.setCount(last.getCount() + 1);
                } else {
                    ranges.add(ElementIdRange.newBuilder().setFirst(elementId(c)).setCount(1));
                }
            }
            com.villagecompute.wiretuner.doc.v1.TextDelete.Builder delete = com.villagecompute.wiretuner.doc.v1.TextDelete
                    .newBuilder().setNode(node.toProto()).setText(text.toProto());
            ranges.forEach(delete::addRanges);
            return Op.newBuilder().setTextDelete(delete).build();
        }

        static Op textMark(OpId node, RegisterPath text, Anchor start, Anchor end, byte[] value) {
            TextMarkValue parsed;
            try {
                parsed = TextMarkValue.parseFrom(value);
            } catch (InvalidProtocolBufferException e) {
                // A TextMarkValue the engine read from an op always parses again.
                throw new IllegalStateException(e);
            }
            return Op.newBuilder().setTextMark(com.villagecompute.wiretuner.doc.v1.TextMark.newBuilder()
                    .setNode(node.toProto()).setText(text.toProto())
                    .setStart(com.villagecompute.wiretuner.doc.v1.Anchor.newBuilder()
                            .setChar(elementId(start.character())).setBefore(start.before()))
                    .setEnd(com.villagecompute.wiretuner.doc.v1.Anchor.newBuilder()
                            .setChar(elementId(end.character())).setBefore(end.before()))
                    .setValue(parsed)).build();
        }
    }
}
