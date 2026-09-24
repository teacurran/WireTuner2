package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc;

import io.grpc.Status;
import io.quarkus.test.junit.QuarkusTest;

/** SRV-004: the acceptance rules through PushChange, one test per rejection reason. */
@QuarkusTest
class ChangeIngestTest extends SyncTestSupport {

    static PushChangeRequest push(UUID document, Change change) {
        return PushChangeRequest.newBuilder().setDocumentId(document.toString()).setChange(change).build();
    }

    long push(SyncServiceGrpc.SyncServiceBlockingStub stub, UUID document, Change change) {
        return stub.pushChange(push(document, change)).getServerSeq();
    }

    @Test
    void acceptedChangesGetDenseServerSeqsAndAreStoredVerbatim() {
        UUID doc = document(ALICE);
        UUID device = UUID.randomUUID();
        var stub = blocking(ALICE, device);
        long a = replicaId();
        long b = replicaId();
        assertThat(push(stub, doc, change(a, 1))).isEqualTo(1);
        assertThat(push(stub, doc, change(b, 1))).isEqualTo(2);
        assertThat(push(stub, doc, change(a, 2))).isEqualTo(3);
        assertThat(count("SELECT head_seq FROM document WHERE id = ?", doc)).isEqualTo(3);
        assertThat((byte[]) value("SELECT bytes FROM change_log WHERE document_id = ? AND server_seq = 3", doc))
                .isEqualTo(change(a, 2).toByteArray());
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ? AND replica_id = ?", doc, a)).isEqualTo(device);
        assertThat(count("SELECT last_seq FROM replica WHERE document_id = ? AND replica_id = ?", doc, a)).isEqualTo(2);
    }

    @Test
    void localOnlyWritesAreStrippedBeforeTheyAreLogged() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        FieldPath zoom = FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(2))
                .addSegments(PathSegment.newBuilder().setField(40)).addSegments(PathSegment.newBuilder().setField(1)).build();
        var values = com.villagecompute.wiretuner.doc.v1.NodeProps.newBuilder().setSettings(
                com.villagecompute.wiretuner.doc.v1.SettingsProps.newBuilder()
                        .setView(com.villagecompute.wiretuner.doc.v1.ViewState.newBuilder().setMagnification(4)));
        Change zoomed = Change.newBuilder().setReplica(replica).setSeq(1).setStartCounter(1).setLabel("Zoom")
                .addOps(Op.newBuilder().setSet(SetFields.newBuilder().setNode(OpId.newBuilder().setCounter(1)).addPaths(zoom)
                        .setValues(values)))
                .build();
        assertThat(push(stub, doc, zoomed)).isEqualTo(1);
        Change logged = Change.newBuilder(zoomed).setOps(0, Op.newBuilder()
                .setNoop(com.villagecompute.wiretuner.doc.v1.Noop.getDefaultInstance())).build();
        assertThat((byte[]) value("SELECT bytes FROM change_log WHERE document_id = ? AND server_seq = 1", doc))
                .isEqualTo(logged.toByteArray());
        // A retry of the same change strips to the same bytes: acknowledged, not a conflict.
        assertThat(push(stub, doc, zoomed)).isEqualTo(1);
    }

    @Test
    void aReplicaWithoutDeviceBindsToTheZeroDevice() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        push(blocking(ALICE, null), doc, change(replica, 1));
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ? AND replica_id = ?", doc, replica))
                .isEqualTo(ReplicaBinding.NO_DEVICE);
    }

    @Test
    void anIdenticalRetryIsSilentlyAckedWithItsOriginalServerSeq() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        push(stub, doc, change(replica, 1));
        push(stub, doc, change(replicaId(), 1));
        assertThat(push(stub, doc, change(replica, 1))).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(2);
    }

    @Test
    void aRetryWithDifferentContentIsReplicaConflict() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        push(stub, doc, change(replica, 1, "first"));
        assertFails(() -> push(stub, doc, change(replica, 1, "other")), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.REPLICA_CONFLICT);
    }

    @Test
    void aRetryOfACompactedSeqAsksForAResend() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        push(stub, doc, change(replica, 1));
        push(stub, doc, change(replica, 2));
        exec("DELETE FROM change_log WHERE document_id = ? AND server_seq = 1", doc);
        assertFails(() -> push(stub, doc, change(replica, 1)), Status.Code.ABORTED, ErrorReasons.SEQ_GAP);
    }

    @Test
    void aSeqAheadOfItsPredecessorIsSeqGap() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        assertFails(() -> push(stub, doc, change(replica, 2)), Status.Code.ABORTED, ErrorReasons.SEQ_GAP);
        push(stub, doc, change(replica, 1));
        assertFails(() -> push(stub, doc, change(replica, 3)), Status.Code.ABORTED, ErrorReasons.SEQ_GAP);
        assertThat(push(stub, doc, change(replica, 2))).isEqualTo(2);
    }

    @Test
    void aReplicaBoundToAnotherAccountOrDeviceIsReplicaConflict() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        UUID device = UUID.randomUUID();
        long replica = replicaId();
        push(blocking(ALICE, device), doc, change(replica, 1));
        assertFails(() -> push(blocking(BOB, device), doc, change(replica, 2)), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.REPLICA_CONFLICT);
        assertFails(() -> push(blocking(ALICE, UUID.randomUUID()), doc, change(replica, 2)),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.REPLICA_CONFLICT);
    }

    @Test
    void aRetiredReplicaIsReplicaExpired() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        push(stub, doc, change(replica, 1));
        exec("UPDATE replica SET retired_at = now() WHERE document_id = ? AND replica_id = ?", doc, replica);
        assertFails(() -> push(stub, doc, change(replica, 2)), Status.Code.FAILED_PRECONDITION, ErrorReasons.REPLICA_EXPIRED);
    }

    @Test
    void readersCannotPushAndStrangersCannotSeeTheDocument() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        share(doc, carol, "commenter");
        assertFails(() -> push(blocking(BOB, null), doc, change(replicaId(), 1)), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        // A commenter pushes only under the comments collection (COLLAB-030): a no-op concerns nothing and
        // passes, a node of another kind does not.
        long commenter = replicaId();
        assertThat(push(blocking(CAROL, null), doc, change(commenter, 1))).isEqualTo(1);
        assertFails(() -> push(blocking(CAROL, null), doc, sized(commenter, 2, 1024)), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> push(blocking(com.villagecompute.wiretuner.api.TestUsers.DAVE, null), doc, change(replicaId(), 1)), Status.Code.NOT_FOUND,
                ErrorReasons.DOCUMENT_NOT_FOUND);
        Status.Code anonymous = failure(() -> SyncServiceGrpc.newBlockingStub(channel).pushChange(push(doc, change(1, 1))))
                .getStatus().getCode();
        assertThat(anonymous).isEqualTo(Status.Code.UNAUTHENTICATED);
    }

    static Change withOp(long replica, long seq, Op op) {
        return change(replica, seq).toBuilder().clearOps().addOps(op).build();
    }

    @Test
    void anUnknownFieldPathIsValidationFailed() {
        UUID doc = document(ALICE);
        var stub = blocking(ALICE, null);
        OpId node = OpId.newBuilder().setCounter(20).setReplica(1).build();
        Op unknown = Op.newBuilder().setSet(SetFields.newBuilder().setNode(node)
                .addPaths(FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(50))
                        .addSegments(PathSegment.newBuilder().setField(999)))).build();
        long replica = replicaId();
        assertFails(() -> push(stub, doc, withOp(replica, 1, unknown)), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        Op text = Op.newBuilder().setTextInsert(TextInsert.newBuilder().setNode(node).setChars("hi")
                .setText(FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(50))
                        .addSegments(PathSegment.newBuilder().setElement(ElementId.newBuilder().setCounter(3).setReplica(1)))))
                .build();
        assertFails(() -> push(stub, doc, withOp(replica, 1, text)), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        Op known = Op.newBuilder().setSet(SetFields.newBuilder().setNode(node)
                .addPaths(FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(50))
                        .addSegments(PathSegment.newBuilder().setField(1)).addSegments(PathSegment.newBuilder().setField(1))))
                .build();
        assertThat(push(stub, doc, withOp(replica, 1, known))).isEqualTo(1);
    }

    @Test
    void aProtovalidateViolationIsValidationFailed() {
        UUID doc = document(ALICE);
        assertFails(() -> push(blocking(ALICE, null), doc, change(replicaId(), 1).toBuilder().setSeq(0).build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertFails(() -> push(blocking(ALICE, null), doc, change(replicaId(), 1).toBuilder().clearOps().build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void aChangeOverFourMebibytesIsValidationFailed() {
        UUID doc = document(ALICE);
        Change big = sized(replicaId(), 1, 4 * 1024 * 1024 + 32 * 1024);
        assertThat(big.getSerializedSize()).isGreaterThan(ChangeRules.MAX_CHANGE_BYTES);
        assertFails(() -> push(blocking(ALICE, null), doc, big), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        Change limit = sized(replicaId(), 1, 4 * 1024 * 1024 - 64 * 1024);
        assertThat(push(blocking(ALICE, null), doc, limit)).isEqualTo(1);
        assertThat(ByteString.copyFrom((byte[]) value("SELECT bytes FROM change_log WHERE document_id = ?", doc)).size())
                .isEqualTo(limit.getSerializedSize());
    }

    @Test
    void aStatementErrorFailsTheWriteAndChangesNothing() {
        UUID doc = document(ALICE);
        byte[] bytes = change(9, 1).toByteArray();
        // A row at head + 1 that the head does not account for: the next insert collides with it.
        exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size) VALUES (?, 1, 9, 1, ?, ?)",
                doc, bytes, bytes.length);
        long replica = replicaId();
        Status.Code code = failure(() -> push(blocking(ALICE, null), doc, change(replica, 1))).getStatus().getCode();
        assertThat(code).isNotEqualTo(Status.Code.OK);
        assertThat(count("SELECT count(*) FROM replica WHERE document_id = ? AND replica_id = ?", doc, replica)).isZero();
        assertThat(count("SELECT head_seq FROM document WHERE id = ?", doc)).isZero();
    }

    @Test
    void theLogOfADocumentIsItsOwn() {
        UUID first = document(ALICE);
        UUID second = document(ALICE);
        var stub = blocking(ALICE, null);
        long replica = replicaId();
        push(stub, first, change(replica, 1));
        assertThat(push(stub, second, change(replica, 1))).isEqualTo(1);
        assertThat(column("SELECT server_seq FROM change_log WHERE document_id = ? ORDER BY server_seq", second))
                .isEqualTo(List.of(1L));
    }
}
