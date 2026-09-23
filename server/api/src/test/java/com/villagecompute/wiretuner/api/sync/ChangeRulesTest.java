package com.villagecompute.wiretuner.api.sync;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Arrays;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.google.rpc.BadRequest;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.FieldPolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.MessagePolicy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.Policy;
import com.villagecompute.wiretuner.crdt.schema.MergeTable.RefFallback;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetAdd;
import com.villagecompute.wiretuner.doc.v1.SetDeleted;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.SetRemove;
import com.villagecompute.wiretuner.doc.v1.TextDelete;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import com.villagecompute.wiretuner.doc.v1.TextMark;

import io.grpc.StatusRuntimeException;
import io.grpc.protobuf.StatusProto;

/** SRV-004: the size cap and the merge-table path check. */
class ChangeRulesTest {

    static final String ROOT = Schema.ROOT;
    static final int ELEMENT = -1;

    /** A table with one field of every policy under a group kind (50). */
    static final Schema TABLE = Schema.of(Map.of(
            ROOT, message(ROOT, row(50, Policy.STRUCT, "t.Group", null)),
            "t.Group", message("t.Group",
                    row(1, Policy.STRUCT, "t.Common", null),
                    row(2, Policy.SEQUENCE, "t.Item", "t.Item"),
                    row(3, Policy.TEXT, null, null),
                    row(4, Policy.SET, null, null),
                    row(5, Policy.VARIANT, "t.Variant", null)),
            "t.Common", message("t.Common", row(1, Policy.ATOMIC, null, null)),
            "t.Item", message("t.Item", row(1, Policy.ATOMIC, null, null)),
            "t.Variant", message("t.Variant", row(1, Policy.ATOMIC, null, null))), Map.of());

    static FieldPolicy row(int number, Policy policy, String typeName, String element) {
        return new FieldPolicy(number, "f" + number, policy, RefFallback.UNSET, false, typeName == null ? "string" : "message",
                policy == Policy.SEQUENCE || policy == Policy.SET, typeName, element, number == 50 ? "kind" : null);
    }

    static MessagePolicy message(String name, FieldPolicy... rows) {
        return new MessagePolicy(name, Arrays.stream(rows).collect(java.util.stream.Collectors.toMap(FieldPolicy::fieldNumber, r -> r)));
    }

    /** A path of field numbers; {@link #ELEMENT} marks an element segment. */
    static FieldPath path(int... segments) {
        FieldPath.Builder path = FieldPath.newBuilder();
        for (int segment : segments) {
            path.addSegments(segment == ELEMENT
                    ? PathSegment.newBuilder().setElement(ElementId.newBuilder().setCounter(1).setReplica(1))
                    : PathSegment.newBuilder().setField(segment));
        }
        return path.build();
    }

    @Test
    void pathsResolveThroughEveryPolicy() {
        assertThat(ChangeRules.known(TABLE, path(50, 1, 1))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 1))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 2))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 2, ELEMENT, 1))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 3, ELEMENT))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 4))).isTrue();
        assertThat(ChangeRules.known(TABLE, path(50, 5, 1))).isTrue();
    }

    @Test
    void malformedPathsAreUnknown() {
        assertThat(ChangeRules.known(TABLE, path(99))).as("unknown kind").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 99))).as("unknown field").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 1, 1, 1))).as("past an ATOMIC field").isFalse();
        assertThat(ChangeRules.known(TABLE, path(ELEMENT))).as("element without a sequence").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 1, ELEMENT))).as("element in a STRUCT").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 2, 1))).as("field where the element belongs").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 3, ELEMENT, 1))).as("past a character").isFalse();
        assertThat(ChangeRules.known(TABLE, path(50, 4, 1))).as("past a SET").isFalse();
    }

    @Test
    void theGeneratedTableKnowsAGroupName() {
        Schema generated = Schema.generated();
        assertThat(ChangeRules.known(generated, path(50, 1, 1))).isTrue();
        assertThat(ChangeRules.known(generated, path(50, 1, 4, 1))).isFalse();
    }

    static Op op(Op.Builder op) {
        return op.build();
    }

    /** One op of every kind, each naming {@code path} where it names one. */
    static List<Op> everyOp(FieldPath path) {
        return List.of(
                op(Op.newBuilder().setCreate(CreateNode.getDefaultInstance())),
                op(Op.newBuilder().setSet(SetFields.newBuilder().addPaths(path))),
                op(Op.newBuilder().setMove(MoveNode.getDefaultInstance())),
                op(Op.newBuilder().setSetDeleted(SetDeleted.getDefaultInstance())),
                op(Op.newBuilder().setElementInsert(ElementInsert.newBuilder().setSequence(path))),
                op(Op.newBuilder().setElementMove(ElementMove.newBuilder().setElement(path))),
                op(Op.newBuilder().setElementDelete(ElementDelete.newBuilder().addElements(path))),
                op(Op.newBuilder().setTextInsert(TextInsert.newBuilder().setText(path))),
                op(Op.newBuilder().setTextDelete(TextDelete.newBuilder().setText(path))),
                op(Op.newBuilder().setTextMark(TextMark.newBuilder().setText(path))),
                op(Op.newBuilder().setSetAdd(SetAdd.newBuilder().setSet(path))),
                op(Op.newBuilder().setSetRemove(SetRemove.newBuilder().setSet(path))),
                op(Op.newBuilder().setNoop(Noop.getDefaultInstance())),
                Op.getDefaultInstance());
    }

    @Test
    void everyOpKindHasItsPathsChecked() {
        Change good = Change.newBuilder().setReplica(1).setSeq(1).addAllOps(everyOp(path(50, 1, 1))).build();
        assertThatCode(() -> ChangeRules.check(TABLE, good)).doesNotThrowAnyException();

        Change bad = Change.newBuilder().setReplica(1).setSeq(1).addAllOps(everyOp(path(50, 99))).build();
        StatusRuntimeException e = (StatusRuntimeException) catchFailure(() -> ChangeRules.check(TABLE, bad));
        assertThat(StatusExceptions.reasonOf(e)).contains(ErrorReasons.VALIDATION_FAILED);
        assertThat(violations(e)).containsExactly("ops[1]", "ops[4]", "ops[5]", "ops[6]", "ops[7]", "ops[8]", "ops[9]",
                "ops[10]", "ops[11]");
    }

    @Test
    void aChangeOverFourMebibytesIsRefused() {
        Op big = Op.newBuilder().setCreate(CreateNode.newBuilder().setPosition(ByteString.copyFrom(new byte[64 * 1024]))).build();
        Change.Builder change = Change.newBuilder().setReplica(1).setSeq(1);
        for (int i = 0; i < 65; i++) {
            change.addOps(big);
        }
        assertThat(change.build().getSerializedSize()).isGreaterThan(ChangeRules.MAX_CHANGE_BYTES);
        StatusRuntimeException e = (StatusRuntimeException) catchFailure(() -> ChangeRules.check(TABLE, change.build()));
        assertThat(violations(e)).containsExactly("change");

        change.removeOps(0);
        change.removeOps(0);
        assertThat(change.build().getSerializedSize()).isLessThanOrEqualTo(ChangeRules.MAX_CHANGE_BYTES);
        assertThatCode(() -> ChangeRules.check(TABLE, change.build())).doesNotThrowAnyException();
    }

    static Throwable catchFailure(Runnable call) {
        try {
            call.run();
        } catch (RuntimeException e) {
            return e;
        }
        throw new AssertionError("no failure");
    }

    static List<String> violations(StatusRuntimeException e) {
        return StatusProto.fromThrowable(e).getDetailsList().stream()
                .filter(any -> any.is(BadRequest.class))
                .flatMap(any -> {
                    try {
                        return any.unpack(BadRequest.class).getFieldViolationsList().stream();
                    } catch (com.google.protobuf.InvalidProtocolBufferException x) {
                        throw new IllegalStateException(x);
                    }
                })
                .map(BadRequest.FieldViolation::getField)
                .toList();
    }

    @Test
    void theCapsAreTheSpecsNumbers() {
        assertThat(ChangeRules.MAX_CHANGE_BYTES).isEqualTo(4 * 1024 * 1024);
        assertThat(ChangeRules.MAX_FRAME_BYTES).isEqualTo(1024 * 1024);
        assertThatThrownBy(() -> ChangeRules.check(TABLE, Change.newBuilder()
                .addOps(Op.newBuilder().setSet(SetFields.newBuilder().addPaths(path(1))))
                .build())).isInstanceOf(StatusRuntimeException.class);
    }
}
