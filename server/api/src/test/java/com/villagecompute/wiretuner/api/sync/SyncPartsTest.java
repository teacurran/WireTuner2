package com.villagecompute.wiretuner.api.sync;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.sync.v1.ChangeRejected;
import com.villagecompute.wiretuner.sync.v1.ErrorReason;
import com.villagecompute.wiretuner.sync.v1.FetchChangesResponse;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

import io.grpc.Status;
import io.smallrye.mutiny.Uni;

/** SRV-004/005: the pure parts of the sync service. */
class SyncPartsTest {

    static final UUID ACCOUNT = UUID.randomUUID();
    static final UUID DEVICE = UUID.randomUUID();

    static Principal principal(UUID device) {
        return new Principal(ACCOUNT, "subject", device, "password", null, "request");
    }

    @Test
    void storedBytesThatDoNotDecodeAreAnInternalError() {
        assertThatThrownBy(() -> Protos.change(new byte[] {(byte) 0xff})).isInstanceOf(IllegalStateException.class);
        assertThat(Protos.change(Change.newBuilder().setSeq(3).build().toByteArray()).getSeq()).isEqualTo(3);
    }

    @Test
    void aReasonedStatusBecomesChangeRejected() {
        Change change = Change.newBuilder().setReplica(-1L).setSeq(4).build();
        ChangeRejected rejected = Protos.rejected(change, StatusExceptions.seqGap(2, 4)).orElseThrow();
        assertThat(rejected.getReplica()).isEqualTo(-1L);
        assertThat(rejected.getSeq()).isEqualTo(4);
        assertThat(rejected.getReason()).isEqualTo(ErrorReason.ERROR_REASON_SEQ_GAP);
        assertThat(rejected.getCode()).isEqualTo(Status.Code.ABORTED.value());
        assertThat(rejected.getMessage()).contains("expected seq 2");

        ChangeRejected truncated = Protos.rejected(change, StatusExceptions.teamRoleInvalid("x".repeat(2000))).orElseThrow();
        assertThat(truncated.getMessage()).hasSize(Protos.MESSAGE_CAP);
        assertThat(truncated.getReason()).isEqualTo(ErrorReason.ERROR_REASON_TEAM_ROLE_INVALID);
    }

    @Test
    void failuresWithoutAReasonFailTheCall() {
        Change change = Change.getDefaultInstance();
        assertThat(Protos.rejected(change, StatusExceptions.unauthenticated("no token"))).isEmpty();
        assertThat(Protos.rejected(change, new IllegalStateException("boom"))).isEmpty();
    }

    @Test
    void everyReasonHasAnEnumValue() throws IllegalAccessException {
        for (var field : ErrorReasons.class.getFields()) {
            String reason = (String) field.get(null);
            if (!reason.equals(ErrorReasons.DOMAIN)) {
                assertThat(ErrorReason.valueOf("ERROR_REASON_" + reason)).as(reason).isNotNull();
            }
        }
    }

    @Test
    void replicaBindingAdmitsOnlyItsOwner() {
        Principal caller = principal(DEVICE);
        assertThatCode(() -> ReplicaBinding.check(null, caller, 1)).doesNotThrowAnyException();
        assertThatCode(() -> ReplicaBinding.check(new ReplicaBinding(ACCOUNT, DEVICE, 3, false), caller, 1))
                .doesNotThrowAnyException();
        assertThat(reason(() -> ReplicaBinding.check(new ReplicaBinding(UUID.randomUUID(), DEVICE, 3, false), caller, 1)))
                .isEqualTo(ErrorReasons.REPLICA_CONFLICT);
        assertThat(reason(() -> ReplicaBinding.check(new ReplicaBinding(ACCOUNT, UUID.randomUUID(), 3, false), caller, 1)))
                .isEqualTo(ErrorReasons.REPLICA_CONFLICT);
        assertThat(reason(() -> ReplicaBinding.check(new ReplicaBinding(ACCOUNT, DEVICE, 3, true), caller, 1)))
                .isEqualTo(ErrorReasons.REPLICA_EXPIRED);
        assertThat(ReplicaBinding.device(principal(null))).isEqualTo(ReplicaBinding.NO_DEVICE);
        assertThat(ReplicaBinding.device(caller)).isEqualTo(DEVICE);
    }

    static String reason(Runnable call) {
        try {
            call.run();
        } catch (RuntimeException e) {
            return StatusExceptions.reasonOf(e).orElseThrow();
        }
        throw new AssertionError("no failure");
    }

    static SequencedChange sized(long seq, int bytes) {
        return SequencedChange.newBuilder().setServerSeq(seq)
                .setChange(Change.newBuilder().setLabel("x").setReplica(1).setSeq(seq)
                        .setUnknownFields(com.google.protobuf.UnknownFieldSet.newBuilder()
                                .addField(99, com.google.protobuf.UnknownFieldSet.Field.newBuilder()
                                        .addLengthDelimited(ByteString.copyFrom(new byte[bytes])).build())
                                .build()))
                .build();
    }

    @Test
    void framesHoldAtMost256Changes() {
        FramePacker packer = new FramePacker(300);
        List<FetchChangesResponse> frames = new ArrayList<>();
        for (int i = 1; i <= 300; i++) {
            frames.addAll(packer.add(sized(i, 10)));
        }
        frames.addAll(packer.flush());
        assertThat(frames).extracting(FetchChangesResponse::getChangesCount).containsExactly(256, 44);
        assertThat(frames).extracting(FetchChangesResponse::getHeadSeq).containsOnly(300L);
        assertThat(packer.flush()).isEmpty();
    }

    @Test
    void framesHoldAtMostOneMebibyteAndABigChangeTravelsAlone() {
        FramePacker packer = new FramePacker(4);
        List<FetchChangesResponse> frames = new ArrayList<>();
        frames.addAll(packer.add(sized(1, 600 * 1024)));
        frames.addAll(packer.add(sized(2, 600 * 1024)));
        frames.addAll(packer.add(sized(3, 2 * 1024 * 1024)));
        frames.addAll(packer.add(sized(4, 10)));
        frames.addAll(packer.flush());
        assertThat(frames).extracting(FetchChangesResponse::getChangesCount).containsExactly(1, 1, 1, 1);

        FramePacker alone = new FramePacker(1);
        assertThat(alone.add(sized(1, 2 * 1024 * 1024))).isEmpty();
        assertThat(alone.flush()).hasSize(1);
    }

    @Test
    void aReplicasWorkRunsInSubmissionOrder() {
        ReplicaQueue queue = new ReplicaQueue();
        UUID doc = UUID.randomUUID();
        List<Integer> order = Collections.synchronizedList(new ArrayList<>());
        CompletableFuture<Void> gate = new CompletableFuture<>();
        Uni<Integer> first = queue.submit(doc, 1, () -> Uni.createFrom().completionStage(gate).invoke(() -> order.add(1)).replaceWith(1));
        Uni<Integer> second = queue.submit(doc, 1, () -> Uni.createFrom().item(2).invoke(() -> order.add(2)));
        Uni<Integer> other = queue.submit(doc, 2, () -> Uni.createFrom().item(3).invoke(() -> order.add(3)));
        CompletableFuture<Integer> secondDone = second.subscribeAsCompletionStage().toCompletableFuture();
        CompletableFuture<Integer> firstDone = first.subscribeAsCompletionStage().toCompletableFuture();
        assertThat(other.await().atMost(Duration.ofSeconds(5))).isEqualTo(3);
        assertThat(secondDone).isNotDone();
        gate.complete(null);
        assertThat(firstDone.join()).isEqualTo(1);
        assertThat(secondDone.join()).isEqualTo(2);
        assertThat(order).containsExactly(3, 1, 2);
        assertThat(queue.active()).isZero();
    }

    @Test
    void aFailedTurnReleasesTheNext() {
        ReplicaQueue queue = new ReplicaQueue();
        UUID doc = UUID.randomUUID();
        Uni<Integer> failing = queue.submit(doc, 1, () -> Uni.createFrom().failure(new IllegalStateException("x")));
        Uni<Integer> next = queue.submit(doc, 1, () -> Uni.createFrom().item(7));
        assertThatThrownBy(() -> failing.await().atMost(Duration.ofSeconds(5))).isInstanceOf(IllegalStateException.class);
        assertThat(next.await().atMost(Duration.ofSeconds(5))).isEqualTo(7);
    }

    @Test
    void nodeIdsAreSixteenBytes() {
        UUID id = new UUID(0x0102030405060708L, 0x090a0b0c0d0e0f10L);
        assertThat(SyncBus.uuidBytes(id)).containsExactly(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
    }

    @Test
    void aPresenceRelayPassesPresenceOnlyAndHasNothingToResync() {
        LiveFeed feed = new LiveFeed(UUID.randomUUID(), null, null, Duration.ofSeconds(1));
        SyncGrpcService.PresenceRelay relay = new SyncGrpcService.PresenceRelay(feed);
        assertThat(relay.account()).isNull();
        assertThatCode(relay::resync).doesNotThrowAnyException();
        relay.frame(com.villagecompute.wiretuner.sync.v1.ServerFrame.newBuilder()
                .setPong(com.villagecompute.wiretuner.sync.v1.Pong.getDefaultInstance()).build());
        relay.frame(com.villagecompute.wiretuner.sync.v1.ServerFrame.newBuilder()
                .setPresenceUpdate(com.villagecompute.wiretuner.sync.v1.PresenceUpdate.getDefaultInstance()).build());
        java.util.List<com.villagecompute.wiretuner.sync.v1.ServerFrame> out = new ArrayList<>();
        io.smallrye.mutiny.Multi.createFrom().<com.villagecompute.wiretuner.sync.v1.ServerFrame>emitter(emitter -> {
            feed.start(1, emitter);
            emitter.complete();
        }).subscribe().with(out::add);
        assertThat(out).singleElement().satisfies(frame -> assertThat(frame.hasPresenceUpdate()).isTrue());
    }
}
