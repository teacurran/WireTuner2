package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.sync.v1.AckRequest;
import com.villagecompute.wiretuner.sync.v1.AckResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;

import io.grpc.Status;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SRV-013, D-067: horizons recorded with each change, the collection point the Stability job
 * publishes, and replica retirement.
 */
@QuarkusTest
class StabilityTest extends HistoryTestSupport {

    @Inject
    Stability stability;

    AckResponse ack(String user, UUID device, UUID document, long replica, long applied) {
        return blocking(user, device).ack(AckRequest.newBuilder().setDocumentId(document.toString()).setReplica(replica)
                .setAppliedServerSeq(applied).build());
    }

    @Test
    void anAckPublishesAndTheNextConfirmsItAsTheReplicasHorizon() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        DocOps.Author a = new DocOps.Author(replica);
        push(ALICE, null, doc, a.change("One", DocOps.noop()), a.change("Two", DocOps.noop()));
        assertThat(value("SELECT horizon_seq FROM change_log WHERE document_id = ? AND server_seq = 2", doc)).isEqualTo(0L);

        AckResponse first = ack(ALICE, null, doc, replica, 2);
        assertThat(first.getStableSeq()).isEqualTo(2);
        assertThat(first.getCollectSeq()).isZero();
        assertThat(value("SELECT published_seq FROM replica WHERE document_id = ? AND replica_id = ?", doc, replica)).isEqualTo(2L);
        assertThat(value("SELECT horizon_seq FROM replica WHERE document_id = ? AND replica_id = ?", doc, replica)).isEqualTo(0L);
        // Pushed before the replica confirmed receiving that answer: still the old horizon.
        push(ALICE, null, doc, a.base(2).change("Three", DocOps.noop()));
        assertThat(value("SELECT horizon_seq FROM change_log WHERE document_id = ? AND server_seq = 3", doc)).isEqualTo(0L);

        ack(ALICE, null, doc, replica, 3);
        assertThat(value("SELECT horizon_seq FROM replica WHERE document_id = ? AND replica_id = ?", doc, replica)).isEqualTo(2L);
        push(ALICE, null, doc, a.base(3).change("Four", DocOps.noop()));
        assertThat(value("SELECT horizon_seq FROM change_log WHERE document_id = ? AND server_seq = 4", doc)).isEqualTo(2L);
        assertThat((Long) value("SELECT horizon_ms FROM change_log WHERE document_id = ? AND server_seq = 4", doc)).isPositive();
        // A change made against an older head cannot have seen a newer publication: capped by its base.
        push(ALICE, null, doc, a.base(1).change("Five", DocOps.noop()));
        assertThat(value("SELECT horizon_seq FROM change_log WHERE document_id = ? AND server_seq = 5", doc)).isEqualTo(1L);
    }

    @Test
    void theCollectionPointIsLoweredPastEveryLaterChangeWithALowerHorizon() {
        UUID doc = document(ALICE);
        long r1 = replicaId();
        long r2 = replicaId();
        for (long s = 1; s <= 12; s++) {
            row(doc, s, r1, s, new byte[] {1}, s >= 11 ? 3 : 10, 5_000 + s);
        }
        exec("INSERT INTO replica (document_id, replica_id, account_id, device_id, last_ack_seq, horizon_seq, horizon_ms)"
                + " VALUES (?, ?, ?, ?, 12, 12, 9000), (?, ?, ?, ?, 12, 10, 8000)",
                doc, r1, alice, new UUID(0, 0), doc, r2, alice, new UUID(0, 0));
        // Start at the smallest replica horizon, 10; seqs 11 and 12 were pushed with horizon 3, so C drops to 3.
        Stability.Point point = run(() -> stability.publish(doc));
        assertThat(point).isEqualTo(new Stability.Point(3, 5_004));
        assertThat(value("SELECT stable_seq FROM document WHERE id = ?", doc)).isEqualTo(12L);

        // A cold segment after C with a lower horizon lowers it again; with nothing after C, T stays the replicas'.
        exec("INSERT INTO cold_segment (document_id, from_seq, to_seq, object_key, compressed_size, min_horizon_seq,"
                + " min_horizon_ms) VALUES (?, 1, 4, 'k', 1, 2, 7000)", doc);
        exec("UPDATE change_log SET horizon_seq = 20 WHERE document_id = ?", doc);
        exec("UPDATE replica SET horizon_seq = 12 WHERE document_id = ?", doc);
        assertThat(run(() -> stability.publish(doc))).isEqualTo(new Stability.Point(12, 8000));
        // From 11: seq 12 has horizon 5, so C drops to 5; the segment reaching past 5 has horizon 1, so to 1.
        exec("UPDATE replica SET horizon_seq = 11 WHERE document_id = ?", doc);
        exec("UPDATE change_log SET horizon_seq = 5, horizon_ms = 100 WHERE document_id = ? AND server_seq = 12", doc);
        exec("UPDATE cold_segment SET to_seq = 8, min_horizon_seq = 1, min_horizon_ms = 50 WHERE document_id = ?", doc);
        assertThat(run(() -> stability.publish(doc))).isEqualTo(new Stability.Point(1, 50));

        // Every Ack answers the published point.
        AckResponse response = ack(ALICE, null, doc, r1, 12);
        assertThat(response.getCollectSeq()).isEqualTo(1);
        assertThat(response.getCollectTimeMs()).isEqualTo(50);
    }

    @Test
    void aDocumentWithoutLiveReplicasKeepsItsPoint() {
        UUID doc = document(ALICE);
        exec("UPDATE document SET collect_seq = 0, collect_time_ms = 7 WHERE id = ?", doc);
        assertThat(run(() -> stability.publish(doc))).isNull();
        assertThat(value("SELECT collect_time_ms FROM document WHERE id = ?", doc)).isEqualTo(7L);
    }

    @Test
    void aSilentReplicaIsRetiredAndTheStablePointMovesPastIt() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        long quiet = replicaId();
        long busy = replicaId();
        UUID device = UUID.randomUUID();
        push(BOB, device, doc, change(quiet, 1));
        push(ALICE, null, doc, change(busy, 1), change(busy, 2));
        ack(BOB, device, doc, quiet, 1);
        ack(ALICE, null, doc, busy, 3);
        assertThat(value("SELECT stable_seq FROM document WHERE id = ?", doc)).isEqualTo(1L);
        exec("UPDATE replica SET last_seen_at = now() - interval '91 days' WHERE document_id = ? AND replica_id = ?", doc, quiet);

        run(() -> stability.scheduled());
        assertThat(value("SELECT retired_at FROM replica WHERE document_id = ? AND replica_id = ?", doc, quiet)).isNotNull();
        assertThat(value("SELECT stable_seq FROM document WHERE id = ?", doc)).isEqualTo(3L);
        assertThat(value("SELECT collect_seq FROM document WHERE id = ?", doc)).isEqualTo(0L);

        // The retired replica's reconnect is refused, whichever call it makes.
        assertFails(() -> blocking(BOB, device).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change(quiet, 2)).build()), Status.Code.FAILED_PRECONDITION, "REPLICA_EXPIRED");
        assertFails(() -> ack(BOB, device, doc, quiet, 3), Status.Code.FAILED_PRECONDITION, "REPLICA_EXPIRED");
        Subscription subscription = subscribe(BOB, device, doc, quiet, 0);
        await(subscription.done::isDone);
        assertThat(com.villagecompute.wiretuner.api.grpc.StatusExceptions.reasonOf(subscription.done.exceptionNow()))
                .contains("REPLICA_EXPIRED");
        assertThat(run(() -> stability.retire())).isZero();
    }
}
