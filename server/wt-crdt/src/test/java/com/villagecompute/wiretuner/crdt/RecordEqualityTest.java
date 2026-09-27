package com.villagecompute.wiretuner.crdt;

import static org.assertj.core.api.Assertions.assertThat;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.doc.v1.SnapshotHeader;
import java.util.List;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;

/**
 * Records with a byte-array component compare, hash and print by the array's content, not its
 * identity (Sonar java:S6218): two records built from equal bytes are equal, and changing any one
 * component makes them differ.
 */
class RecordEqualityTest {

    static final OpId A = new OpId(1, 1);
    static final OpId B = new OpId(2, 1);
    static final RegisterPath PATH = RegisterPath.of(150, 1);
    static final RegisterPath OTHER_PATH = RegisterPath.of(150, 2);
    static final MarkKey KEY = new MarkKey(3);
    static final Inverse.MemberField FIELD = new Inverse.MemberField(4, "string", "");
    static final Inverse.MemberField OTHER_FIELD = new Inverse.MemberField(5, "string", "");

    static byte[] bytes(int... values) {
        byte[] out = new byte[values.length];
        for (int i = 0; i < values.length; i++) {
            out[i] = (byte) values[i];
        }
        return out;
    }

    /**
     * {@code make} builds equal records from fresh arrays; each of {@code variants} differs from them in
     * one component. The record prints {@code shown}.
     */
    @SafeVarargs
    static <T> void byContent(Supplier<T> make, String shown, T... variants) {
        T one = make.get();
        T two = make.get();
        Object text = "x";
        assertThat(one).isEqualTo(one).isEqualTo(two).hasSameHashCodeAs(two).isNotEqualTo(text).isNotEqualTo(null);
        assertThat(one.toString()).contains(shown).isEqualTo(two.toString());
        for (T variant : variants) {
            assertThat(one).isNotEqualTo(variant);
        }
    }

    @Test
    void inverseStepsCompareTheirBytes() {
        byContent(() -> new Inverse.MemberAdded(A, PATH, bytes(0xab), B, true, FIELD), "member=ab",
                new Inverse.MemberAdded(B, PATH, bytes(0xab), B, true, FIELD),
                new Inverse.MemberAdded(A, OTHER_PATH, bytes(0xab), B, true, FIELD),
                new Inverse.MemberAdded(A, PATH, bytes(0xac), B, true, FIELD),
                new Inverse.MemberAdded(A, PATH, bytes(0xab), A, true, FIELD),
                new Inverse.MemberAdded(A, PATH, bytes(0xab), B, false, FIELD),
                new Inverse.MemberAdded(A, PATH, bytes(0xab), B, true, OTHER_FIELD));
        byContent(() -> new Inverse.MemberRemoved(A, PATH, bytes(1, 2), FIELD), "member=0102",
                new Inverse.MemberRemoved(B, PATH, bytes(1, 2), FIELD),
                new Inverse.MemberRemoved(A, OTHER_PATH, bytes(1, 2), FIELD),
                new Inverse.MemberRemoved(A, PATH, bytes(1), FIELD),
                new Inverse.MemberRemoved(A, PATH, bytes(1, 2), OTHER_FIELD));
        List<Inverse.PriorFormat> prior = List.of(new Inverse.PriorFormat(A, null));
        byContent(() -> new Inverse.TextMarked(A, PATH, B, KEY, bytes(7), prior), "value=07",
                new Inverse.TextMarked(B, PATH, B, KEY, bytes(7), prior),
                new Inverse.TextMarked(A, OTHER_PATH, B, KEY, bytes(7), prior),
                new Inverse.TextMarked(A, PATH, A, KEY, bytes(7), prior),
                new Inverse.TextMarked(A, PATH, B, new MarkKey(9), bytes(7), prior),
                new Inverse.TextMarked(A, PATH, B, KEY, bytes(8), prior),
                new Inverse.TextMarked(A, PATH, B, KEY, bytes(7), List.of()));
        List<RegisterPath.Segment> suffix = List.of(RegisterPath.Segment.field(2));
        byContent(() -> new Inverse.ParagraphRegister(suffix, bytes(0x10)), "value=10",
                new Inverse.ParagraphRegister(List.of(), bytes(0x10)),
                new Inverse.ParagraphRegister(suffix, bytes(0x11)));
        byContent(() -> new Inverse.PriorFormat(A, bytes(0xff)), "value=ff",
                new Inverse.PriorFormat(B, bytes(0xff)),
                new Inverse.PriorFormat(A, null));
        assertThat(new Inverse.PriorFormat(A, null)).hasToString("PriorFormat[character=" + A + ", value=null]");
        // An inverse compares its steps, so two inverses of the same change are equal.
        assertThat(new Inverse(List.of(new Inverse.MemberRemoved(A, PATH, bytes(1), FIELD))))
                .isEqualTo(new Inverse(List.of(new Inverse.MemberRemoved(A, PATH, bytes(1), FIELD))));
    }

    @Test
    void moveLogEntriesCompareTheirPosition() {
        Placement old = new Placement(A, bytes(0x80), B);
        byContent(() -> new MoveLogEntry(A, B, A, bytes(0x40), true, old, true), "position=40",
                new MoveLogEntry(B, B, A, bytes(0x40), true, old, true),
                new MoveLogEntry(A, A, A, bytes(0x40), true, old, true),
                new MoveLogEntry(A, B, B, bytes(0x40), true, old, true),
                new MoveLogEntry(A, B, A, bytes(0x41), true, old, true),
                new MoveLogEntry(A, B, A, bytes(0x40), false, old, true),
                new MoveLogEntry(A, B, A, bytes(0x40), true, null, true),
                new MoveLogEntry(A, B, A, bytes(0x40), true, old, false));
    }

    @Test
    void snapshotPartsCompareTheirBytes() {
        List<NodeStore.SetAddition> adds = List.of(new NodeStore.SetAddition(A, 1));
        List<NodeStore.SetRemoval> removes = List.of(new NodeStore.SetRemoval(B, 2, 1));
        byContent(() -> new NodeStore.MemberEntry(bytes(5), adds, removes), "member=05",
                new NodeStore.MemberEntry(bytes(6), adds, removes),
                new NodeStore.MemberEntry(bytes(5), List.of(), removes),
                new NodeStore.MemberEntry(bytes(5), adds, List.of()));
        byContent(() -> new PathResolver.Assignment(PATH, bytes(9), false), "value=09",
                new PathResolver.Assignment(OTHER_PATH, bytes(9), false),
                new PathResolver.Assignment(PATH, null, false),
                new PathResolver.Assignment(PATH, bytes(9), true));
        SnapshotHeader header = SnapshotHeader.newBuilder().setStateHash(ByteString.copyFrom(bytes(1))).build();
        byContent(() -> new SnapshotTransfer.Assembled(header, bytes(1, 2, 3)), "snapshot=3 bytes",
                new SnapshotTransfer.Assembled(SnapshotHeader.getDefaultInstance(), bytes(1, 2, 3)),
                new SnapshotTransfer.Assembled(header, bytes(1, 2)));
    }

    @Test
    void textRecordsPrintTheirValue() {
        Anchor start = new Anchor(A, true);
        Anchor end = new Anchor(B, false);
        assertThat(new TextAttribute(KEY, bytes(0x0a, 0x0b), A)).hasToString("TextAttribute[key=" + KEY + ", value=0a0b, mark="
                + A + "]");
        assertThat(new TextMark(A, start, end, bytes(0x0c), null)).hasToString("TextMark[id=" + A + ", start=" + start + ", end="
                + end + ", value=0c, key=null]");
    }
}
