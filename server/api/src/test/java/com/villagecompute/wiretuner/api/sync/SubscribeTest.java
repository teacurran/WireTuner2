package com.villagecompute.wiretuner.api.sync;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;

import com.google.common.util.concurrent.ListenableFuture;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.crdt.schema.MergeTable;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderRequest;
import com.villagecompute.wiretuner.docs.v1.RenameRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;
import com.villagecompute.wiretuner.sync.v1.AckRequest;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.ErrorReason;
import com.villagecompute.wiretuner.sync.v1.PresenceState;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeResponse;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;
import com.villagecompute.wiretuner.sync.v1.SubscribeRequest;
import com.villagecompute.wiretuner.sync.v1.SyncServiceGrpc;
import com.villagecompute.wiretuner.sync.v1.UpdatePresenceRequest;
import com.villagecompute.wiretuner.sync.v1.Welcome;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.test.junit.QuarkusTest;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;

import jakarta.inject.Inject;

/** SRV-005: the subscription, unary pushes through the replica queue, presence, events and Ack. */
@QuarkusTest
class SubscribeTest extends SyncTestSupport {

    @Inject
    SyncBus bus;

    @Inject
    Redis redis;

    @Inject
    ChangeReader reader;

    static PushChangeRequest push(UUID document, Change change) {
        return PushChangeRequest.newBuilder().setDocumentId(document.toString()).setChange(change).build();
    }

    long push(String user, UUID document, Change change) {
        return blocking(user, null).pushChange(push(document, change)).getServerSeq();
    }

    static List<Long> seqs(List<SequencedChange> changes) {
        return changes.stream().map(SequencedChange::getServerSeq).toList();
    }

    static List<Long> range(long from, long to) {
        List<Long> out = new ArrayList<>();
        for (long s = from; s <= to; s++) {
            out.add(s);
        }
        return out;
    }

    // --------------------------------------------------------------------------- collaboration

    @Test
    void threeClientsSeeEachOthersChanges() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "editor");
        List<String> users = List.of(ALICE, BOB, CAROL);
        List<Subscription> subscriptions = new ArrayList<>();
        for (String user : users) {
            Subscription s = subscribe(user, null, doc, replicaId(), 0);
            Welcome welcome = s.next().getWelcome();
            assertThat(welcome.getMergeTable().toByteArray()).isEqualTo(MergeTable.json());
            assertThat(welcome.getHeadSeq()).isZero();
            assertThat(welcome.getSnapshotHint()).isFalse();
            assertThat(s.next().hasPresence()).isTrue();
            subscriptions.add(s);
        }
        assertThat(subscriptions.get(0).frames).isEmpty();
        long started = System.nanoTime();
        for (int round = 1; round <= 2; round++) {
            for (String user : users) {
                push(user, doc, change(Math.abs(user.hashCode()) + 1L, round));
            }
        }
        for (Subscription s : subscriptions) {
            List<SequencedChange> changes = s.changes(6);
            assertThat(seqs(changes)).isEqualTo(range(1, 6));
            assertThat(changes).allSatisfy(c -> assertThat(c.getAuthor().getUserId()).isNotEmpty());
            assertThat(changes.get(0).getAuthor().getUserId()).isEqualTo(alice.toString());
            assertThat(changes.get(1).getAuthor().getUserId()).isEqualTo(bob.toString());
        }
        long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
        System.out.printf("SRV-005: 6 pushes by 3 clients seen by all 3 in %d ms%n", elapsedMs);
        subscriptions.forEach(Subscription::cancel);
    }

    @Test
    void thirtyTwoPipelinedPushesAreAcceptedInOrder() throws Exception {
        UUID doc = document(ALICE);
        long replica = replicaId();
        UUID device = UUID.randomUUID();
        // A connected channel first: grpc-java may start calls it buffered while connecting in any order.
        blocking(ALICE, device).pushChange(push(doc, change(replicaId(), 1)));
        var stub = future(ALICE, device);
        List<ListenableFuture<PushChangeResponse>> calls = new ArrayList<>();
        for (int seq = 1; seq <= 32; seq++) {
            calls.add(stub.pushChange(push(doc, change(replica, seq))));
        }
        List<Long> acks = new ArrayList<>();
        for (var call : calls) {
            acks.add(call.get(10, TimeUnit.SECONDS).getServerSeq());
        }
        assertThat(acks).isEqualTo(range(2, 33));
        assertThat(column("SELECT seq FROM change_log WHERE document_id = ? AND server_seq > 1 ORDER BY server_seq", doc))
                .isEqualTo(range(1, 32));
    }

    @Test
    void aReorderedPushIsSeqGapAndTheResendIsAccepted() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        StatusRuntimeException gap = failure(() -> push(ALICE, doc, change(replica, 2)));
        assertThat(StatusExceptions.reasonOf(gap)).contains(ErrorReasons.SEQ_GAP);
        assertThat(StatusExceptions.errorInfo(gap).orElseThrow().getMetadataMap()).containsEntry("expected", "1");
        assertThat(push(ALICE, doc, change(replica, 1))).isEqualTo(1);
        assertThat(push(ALICE, doc, change(replica, 2))).isEqualTo(2);
    }

    static Change unknownPath(long replica, long seq) {
        Op op = Op.newBuilder().setSet(SetFields.newBuilder().setNode(OpId.newBuilder().setCounter(20).setReplica(1))
                .addPaths(FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(4242)))).build();
        return change(replica, seq).toBuilder().clearOps().addOps(op).build();
    }

    @Test
    void aBatchWithABadThirdChangeAcksTwo() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        PushChangeBatchRequest batch = PushChangeBatchRequest.newBuilder().setDocumentId(doc.toString())
                .addChanges(change(replica, 1)).addChanges(change(replica, 2)).addChanges(unknownPath(replica, 3))
                .addChanges(change(replica, 4)).addChanges(change(replica, 5)).build();
        PushChangeBatchResponse response = blocking(ALICE, null).pushChangeBatch(batch);
        assertThat(response.getServerSeqsList()).containsExactly(1L, 2L);
        assertThat(response.getRejected().getSeq()).isEqualTo(3);
        assertThat(response.getRejected().getReplica()).isEqualTo(replica);
        assertThat(response.getRejected().getReason()).isEqualTo(ErrorReason.ERROR_REASON_VALIDATION_FAILED);
        assertThat(response.getRejected().getCode()).isEqualTo(Status.Code.INVALID_ARGUMENT.value());

        PushChangeBatchRequest resent = PushChangeBatchRequest.newBuilder().setDocumentId(doc.toString())
                .addChanges(change(replica, 2)).addChanges(change(replica, 3)).build();
        PushChangeBatchResponse whole = blocking(ALICE, null).pushChangeBatch(resent);
        assertThat(whole.getServerSeqsList()).containsExactly(2L, 3L);
        assertThat(whole.hasRejected()).isFalse();
    }

    @Test
    void aBatchFromAReaderIsRejectedAtItsFirstChangeAndAnAnonymousBatchFails() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        long replica = replicaId();
        PushChangeBatchRequest batch = PushChangeBatchRequest.newBuilder().setDocumentId(doc.toString())
                .addChanges(change(replica, 1)).build();
        PushChangeBatchResponse response = blocking(BOB, null).pushChangeBatch(batch);
        assertThat(response.getServerSeqsCount()).isZero();
        assertThat(response.getRejected().getReason()).isEqualTo(ErrorReason.ERROR_REASON_ROLE_INSUFFICIENT);
        assertThat(failure(() -> SyncServiceGrpc.newBlockingStub(channel).pushChangeBatch(batch)).getStatus().getCode())
                .isEqualTo(Status.Code.UNAUTHENTICATED);
    }

    @Test
    void aDroppedStreamResubscribesWithoutGapOrDuplicate() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        long aliceReplica = replicaId();
        long bobReplica = replicaId();
        Subscription first = subscribe(BOB, null, doc, bobReplica, 0);
        assertThat(first.next().getWelcome().getLastAcceptedSeq()).isZero();
        for (int seq = 1; seq <= 3; seq++) {
            push(ALICE, doc, change(aliceReplica, seq));
        }
        push(BOB, doc, change(bobReplica, 1));
        push(BOB, doc, change(bobReplica, 2));
        List<SequencedChange> seen = first.changes(5);
        assertThat(seqs(seen)).isEqualTo(range(1, 5));
        first.cancel();

        for (int seq = 4; seq <= 6; seq++) {
            push(ALICE, doc, change(aliceReplica, seq));
        }
        Subscription second = subscribe(BOB, null, doc, bobReplica, 5);
        Welcome welcome = second.next().getWelcome();
        assertThat(welcome.getLastAcceptedSeq()).isEqualTo(2);
        assertThat(welcome.getHeadSeq()).isEqualTo(8);
        assertThat(seqs(second.changes(3))).isEqualTo(range(6, 8));
        assertThat(second.next().hasPresence()).isTrue();
        push(ALICE, doc, change(aliceReplica, 7));
        assertThat(seqs(second.changes(1))).containsExactly(9L);
        second.assertNoChange(Duration.ofMillis(500));
        second.cancel();
    }

    @Test
    void aClientAheadOfTheHeadGetsNoReplayButEveryLaterChange() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        push(ALICE, doc, change(replica, 1));
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 9);
        assertThat(s.next().getWelcome().getHeadSeq()).isEqualTo(1);
        assertThat(s.next().hasPresence()).isTrue();
        push(ALICE, doc, change(replica, 2));
        assertThat(seqs(s.changes(1))).containsExactly(2L);
        s.cancel();
    }

    @Test
    void theReplayNamesNoAuthorForAnUnboundReplica() {
        UUID doc = document(ALICE);
        byte[] bytes = change(77, 1).toByteArray();
        exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size) VALUES (?, 1, 77, 1, ?, ?)",
                doc, bytes, bytes.length);
        exec("UPDATE document SET head_seq = 1 WHERE id = ?", doc);
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        SequencedChange replayed = s.changes(1).get(0);
        assertThat(replayed.hasAuthor()).isFalse();
        assertThat(replayed.getChange().toByteArray()).isEqualTo(bytes);
        s.cancel();
    }

    @Test
    void theSnapshotHintReplacesALongReplay() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        for (int seq = 1; seq <= 5; seq++) {
            push(ALICE, doc, change(replica, seq));
        }
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 3, 'k', ?, 1, 1)", doc, "c".repeat(64));
        Subscription behind = subscribe(ALICE, null, doc, replica, 1);
        Welcome welcome = behind.next().getWelcome();
        assertThat(welcome.getSnapshotHint()).isTrue();
        assertThat(welcome.getLastAcceptedSeq()).isEqualTo(5);
        assertThat(behind.next().hasPresence()).isTrue();
        behind.cancel();

        Subscription close = subscribe(ALICE, null, doc, replica, 4);
        assertThat(close.next().getWelcome().getSnapshotHint()).isFalse();
        assertThat(seqs(close.changes(1))).containsExactly(5L);
        close.cancel();
    }

    @Test
    void subscribingNeedsARoleAndTheCallersReplica() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        push(ALICE, doc, change(replica, 1));
        assertThat(reason(subscribe(DAVE, null, doc, replicaId(), 0))).isEqualTo(ErrorReasons.DOCUMENT_NOT_FOUND);
        share(doc, bob, "viewer");
        assertThat(reason(subscribe(BOB, null, doc, replica, 0))).isEqualTo(ErrorReasons.REPLICA_CONFLICT);
        Subscription viewer = subscribe(BOB, null, doc, replicaId(), 0);
        assertThat(viewer.next().getWelcome().getRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        viewer.cancel();
    }

    static String reason(Subscription s) {
        try {
            s.done.get(10, TimeUnit.SECONDS);
        } catch (Exception e) {
            return StatusExceptions.reasonOf(e.getCause()).orElseThrow();
        }
        throw new AssertionError("the subscription did not fail");
    }

    // ---------------------------------------------------------------------------------- events

    @Test
    void renameMoveTrashAndRestoreReachLiveSessions() {
        UUID doc = document(ALICE);
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        s.next(FrameCase.PRESENCE);
        var documents = TestUsers.as(docs, ALICE);
        documents.rename(RenameRequest.newBuilder().setDocumentId(doc.toString()).setName("Poster").build());
        DocumentEvent renamed = s.next(FrameCase.EVENT).getEvent();
        assertThat(renamed.getRenamed().getName()).isEqualTo("Poster");
        assertThat(renamed.getRenamed().getActor().getUserId()).isEqualTo(alice.toString());

        String folder = documents.createFolder(CreateFolderRequest.newBuilder().setSpaceId(alice.toString()).setName("F")
                .build()).getFolder().getId();
        documents.moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.toString()).setFolderId(folder).build());
        DocumentEvent moved = s.next(FrameCase.EVENT).getEvent();
        assertThat(moved.getMoved().getFolderId()).isEqualTo(folder);
        assertThat(moved.getMoved().getSpaceId()).isEqualTo(alice.toString());

        documents.trash(TrashRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertThat(s.next(FrameCase.EVENT).getEvent().getTrashed().getTrashed()).isTrue();
        documents.restore(RestoreRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertThat(s.next(FrameCase.EVENT).getEvent().getTrashed().getTrashed()).isFalse();
        s.cancel();
    }

    @Test
    void framesBeforeTheReplayEndsWaitForIt() throws InterruptedException {
        UUID doc = document(ALICE);
        LiveFeed feed = new LiveFeed(doc, reader, Duration.ofSeconds(1));
        feed.resync();
        feed.frame(ServerFrame.newBuilder().setEvent(DocumentEvent.newBuilder()
                .setRenamed(com.villagecompute.wiretuner.sync.v1.Renamed.newBuilder().setName("buffered"))).build());
        feed.frame(changeFrame(1, 5, 1));
        Thread.sleep(300);
        List<ServerFrame> out = new java.util.concurrent.CopyOnWriteArrayList<>();
        io.smallrye.mutiny.Multi.createFrom().<ServerFrame>emitter(emitter -> feed.start(1, emitter))
                .subscribe().with(out::add);
        assertThat(out).extracting(ServerFrame::getFrameCase).containsExactly(FrameCase.EVENT, FrameCase.CHANGE);
        assertThat(out.get(0).getEvent().getRenamed().getName()).isEqualTo("buffered");
    }

    // -------------------------------------------------------------------------------- presence

    static PresenceUpdate tool(String tool) {
        return PresenceUpdate.newBuilder().setTool(tool).setState(PresenceState.PRESENCE_STATE_ACTIVE).build();
    }

    @Test
    void presenceIsFannedOutSnapshottedAndRemoved() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "viewer");
        long aliceReplica = replicaId();
        Subscription alices = subscribe(ALICE, null, SubscribeRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(aliceReplica).setPresence(tool("pen")).build());
        assertThat(alices.next(FrameCase.PRESENCE).getPresence().getParticipantsList())
                .extracting(p -> p.getUser().getUserId()).containsExactly(alice.toString());

        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        PresenceUpdate seenByBob = bobs.next(FrameCase.PRESENCE).getPresence().getParticipants(0);
        assertThat(seenByBob.getTool()).isEqualTo("pen");
        assertThat(seenByBob.getUser().getRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
        assertThat(seenByBob.getColorIndex()).isBetween(0, 11);

        long carolReplica = replicaId();
        blocking(CAROL, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(carolReplica).setPresence(tool("hand").toBuilder()
                        .setBranchId(UUID.randomUUID().toString())).build());
        PresenceUpdate carols = presenceOf(alices, carol);
        assertThat(carols.getTool()).isEqualTo("hand");
        assertThat(carols.getBranchId()).isEmpty();
        assertThat(carols.getUser().getUserId()).isEqualTo(carol.toString());
        assertThat(carols.getUser().getRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        long ttl = redis.send(Request.cmd(Command.TTL).arg(PresenceStore.entry(doc, carolReplica)))
                .await().atMost(WAIT).toLong();
        assertThat(ttl).isBetween(1L, 15L);

        blocking(CAROL, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(carolReplica).setPresence(PresenceUpdate.newBuilder()
                        .setState(PresenceState.PRESENCE_STATE_GONE)).build());
        assertThat(presenceOf(alices, carol).getState()).isEqualTo(PresenceState.PRESENCE_STATE_GONE);

        alices.cancel();
        PresenceUpdate gone = presenceOf(bobs, alice);
        assertThat(gone.getState()).isEqualTo(PresenceState.PRESENCE_STATE_GONE);
        assertThat(gone.getUser().getUserId()).isEqualTo(alice.toString());
        bobs.cancel();
    }

    static PresenceUpdate presenceOf(Subscription s, UUID user) {
        while (true) {
            PresenceUpdate update = s.next(FrameCase.PRESENCE_UPDATE).getPresenceUpdate();
            if (update.getUser().getUserId().equals(user.toString())) {
                return update;
            }
        }
    }

    @Test
    void anExpiredEntryLeavesTheSnapshot() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        blocking(ALICE, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(replica).setPresence(tool("pen")).build());
        long other = replicaId();
        blocking(ALICE, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(other).setPresence(tool("zoom")).build());
        redis.send(Request.cmd(Command.DEL).arg(PresenceStore.entry(doc, replica))).await().atMost(WAIT);
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        assertThat(s.next(FrameCase.PRESENCE).getPresence().getParticipantsList())
                .extracting(PresenceUpdate::getTool).containsExactly("zoom");
        assertThat(redis.send(Request.cmd(Command.SCARD).arg(PresenceStore.members(doc))).await().atMost(WAIT).toInteger())
                .isEqualTo(1);
        s.cancel();
    }

    @Test
    void presenceNeedsARoleAndTheCallersReplica() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        push(ALICE, doc, change(replica, 1));
        UpdatePresenceRequest request = UpdatePresenceRequest.newBuilder().setDocumentId(doc.toString())
                .setReplica(replica).setPresence(tool("pen")).build();
        assertFails(() -> blocking(DAVE, null).updatePresence(request), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        share(doc, bob, "viewer");
        assertFails(() -> blocking(BOB, null).updatePresence(request), Status.Code.FAILED_PRECONDITION,
                ErrorReasons.REPLICA_CONFLICT);
    }

    @Test
    void theServerSendsPongAfterSilence() {
        UUID doc = document(ALICE);
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        ServerFrame pong = s.next(FrameCase.PONG);
        assertThat(pong.getPong().getServerTimeMs()).isCloseTo(System.currentTimeMillis(), org.assertj.core.data.Offset.offset(10_000L));
        s.cancel();
    }

    // -------------------------------------------------------------------------------------- Ack

    @Test
    void ackRecordsTheAppliedSeqAndReturnsTheStableSeq() {
        UUID doc = document(ALICE);
        share(doc, bob, "viewer");
        long replica = replicaId();
        for (int seq = 1; seq <= 4; seq++) {
            push(ALICE, doc, change(replica, seq));
        }
        long bobs = replicaId();
        assertThat(ack(BOB, doc, bobs, 2)).as("alice's replica has acked nothing").isZero();
        assertThat(ack(ALICE, doc, replica, 4)).isEqualTo(2);
        assertThat(ack(BOB, doc, bobs, 1)).as("never backwards").isEqualTo(2);
        assertThat(ack(BOB, doc, bobs, 99)).as("clamped to the head").isEqualTo(4);
        assertThat(count("SELECT last_ack_seq FROM replica WHERE document_id = ? AND replica_id = ?", doc, bobs)).isEqualTo(4);
        assertFails(() -> ack(BOB, doc, replica, 4), Status.Code.FAILED_PRECONDITION, ErrorReasons.REPLICA_CONFLICT);
    }

    long ack(String user, UUID doc, long replica, long applied) {
        return blocking(user, null).ack(AckRequest.newBuilder().setDocumentId(doc.toString()).setReplica(replica)
                .setAppliedServerSeq(applied).build()).getStableSeq();
    }

    // ------------------------------------------------------------------------------- live feed

    void logRow(UUID doc, long serverSeq, long replica, long seq) {
        byte[] bytes = change(replica, seq).toByteArray();
        exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size) VALUES (?, ?, ?, ?, ?, ?)",
                doc, serverSeq, replica, seq, bytes, bytes.length);
        exec("UPDATE document SET head_seq = ? WHERE id = ?", serverSeq, doc);
    }

    static ServerFrame changeFrame(long serverSeq, long replica, long seq) {
        return ServerFrame.newBuilder().setChange(SequencedChange.newBuilder().setServerSeq(serverSeq)
                .setChange(change(replica, seq))).build();
    }

    @Test
    void aGapInTheLiveFeedIsFilledFromTheLog() {
        UUID doc = document(ALICE);
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        s.next(FrameCase.PRESENCE);
        logRow(doc, 1, 5, 1);
        logRow(doc, 2, 5, 2);
        bus.publish(doc, changeFrame(2, 5, 2)).await().atMost(WAIT);
        bus.publish(doc, changeFrame(2, 5, 2)).await().atMost(WAIT);
        assertThat(seqs(s.changes(2))).containsExactly(1L, 2L);

        logRow(doc, 3, 5, 3);
        logRow(doc, 4, 5, 4);
        bus.publish(doc, changeFrame(4, 5, 4)).await().atMost(WAIT);
        bus.publish(doc, changeFrame(3, 5, 3)).await().atMost(WAIT);
        bus.publish(doc, changeFrame(2, 5, 2)).await().atMost(WAIT);
        assertThat(seqs(s.changes(2))).containsExactly(3L, 4L);
        s.assertNoChange(Duration.ofMillis(600));

        bus.publish(doc, changeFrame(9, 5, 9)).await().atMost(WAIT);
        assertThat(reason(s)).isEqualTo(ErrorReasons.HISTORY_UNAVAILABLE);
    }

    @Test
    void aDroppedValkeyConnectionIsRecoveredFromTheLog() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        Subscription s = subscribe(ALICE, null, doc, replicaId(), 0);
        s.next(FrameCase.PRESENCE);
        logRow(doc, 1, 5, 1);
        redis.send(Request.cmd(Command.CLIENT).arg("KILL").arg("TYPE").arg("pubsub")).await().atMost(WAIT);
        assertThat(seqs(s.changes(1))).containsExactly(1L);
        assertThat(push(ALICE, doc, change(replica, 1))).isEqualTo(2);
        assertThat(seqs(s.changes(1))).containsExactly(2L);

        // A frame from another node arrives through the resubscribed channel.
        logRow(doc, 3, 5, 2);
        byte[] frame = changeFrame(3, 5, 2).toByteArray();
        byte[] payload = new byte[16 + frame.length];
        payload[0] = 1;
        System.arraycopy(frame, 0, payload, 16, frame.length);
        ServerFrame received = null;
        for (int attempt = 0; attempt < 50 && received == null; attempt++) {
            redis.send(Request.cmd(Command.PUBLISH).arg(SyncBus.PREFIX + doc)
                    .arg(io.vertx.mutiny.core.buffer.Buffer.buffer(payload))).await().atMost(WAIT);
            try {
                received = s.frames.poll(200, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
            if (received != null && !received.hasChange()) {
                received = null;
            }
        }
        assertThat(received).isNotNull();
        assertThat(received.getChange().getServerSeq()).isEqualTo(3);
        s.cancel();
    }

    @Test
    void channelsFollowTheirListeners() {
        UUID doc = document(ALICE);
        SyncBus.Listener listener = new SyncBus.Listener() {
            @Override
            public void frame(ServerFrame frame) {
            }

            @Override
            public void resync() {
            }
        };
        int before = bus.channelCount();
        bus.listen(doc, listener).await().atMost(WAIT);
        assertThat(bus.channelCount()).isEqualTo(before + 1);
        bus.route("pong", SyncBus.PREFIX + doc, null);
        bus.unlisten(doc, new SyncBus.Listener() {
            @Override
            public void frame(ServerFrame frame) {
            }

            @Override
            public void resync() {
            }
        });
        assertThat(bus.channelCount()).isEqualTo(before + 1);
        bus.unlisten(doc, listener);
        bus.unlisten(doc, listener);
        assertThat(bus.channelCount()).isEqualTo(before);
        bus.route(SyncBus.MESSAGE, SyncBus.PREFIX + doc, new byte[16]);
    }
}
