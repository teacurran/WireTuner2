package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.ForkRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesResponse;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SRV-007: the compactor moves snapshot-covered rows beyond the newest {@code wt.compactor.keep}
 * (4 in tests) into cold segments (120 bytes each in tests), and reads serve them.
 */
@QuarkusTest
class CompactorTest extends HistoryTestSupport {

    @Inject
    Compactor compactor;

    @Inject
    Snapshotter snapshotter;

    List<SequencedChange> fetch(UUID document, long after, long until) {
        List<SequencedChange> changes = new ArrayList<>();
        blocking(ALICE, null).fetchChanges(FetchChangesRequest.newBuilder().setDocumentId(document.toString())
                .setAfterServerSeq(after).setUntilServerSeq(until).build())
                .forEachRemaining((FetchChangesResponse page) -> changes.addAll(page.getChangesList()));
        return changes;
    }

    @Test
    void oldRowsMoveToColdSegmentsAndStillRead() {
        UUID doc = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = new ArrayList<>();
        for (int i = 0; i < 12; i++) {
            changes.add(a.change("Object " + i, DocOps.create(wellKnown(LAYERS), DocOps.path("Object " + i, ""))));
        }
        push(ALICE, null, doc, changes.toArray(Change[]::new));
        // Without a snapshot nothing is covered, so nothing moves.
        assertThat(run(() -> compactor.compact(doc))).isZero();
        run(() -> snapshotter.snapshot(doc));

        int segments = run(() -> compactor.compact(doc));
        assertThat(segments).isGreaterThan(1);
        assertThat(column("SELECT server_seq FROM change_log WHERE document_id = ? ORDER BY server_seq", doc))
                .containsExactly(9L, 10L, 11L, 12L);
        List<Object> ranges = column("SELECT from_seq || '-' || to_seq FROM cold_segment WHERE document_id = ? ORDER BY from_seq", doc);
        assertThat(ranges).hasSize(segments);
        assertThat(ranges.get(0).toString()).startsWith("1-");
        assertThat(ranges.get(segments - 1).toString()).endsWith("-8");
        assertThat(count("SELECT sum(change_count) FROM cold_segment WHERE document_id = ?", doc)).isEqualTo(8);
        assertThat(stored((String) value("SELECT object_key FROM cold_segment WHERE document_id = ? AND from_seq = 1", doc))).isTrue();
        // Nothing more to move until the log grows.
        assertThat(run(() -> compactor.compact(doc))).isZero();

        // Catch-up reads the cold range with its authors, then the hot rows; a range inside a segment is cut to size.
        List<SequencedChange> all = fetch(doc, 0, 0);
        assertThat(all).extracting(SequencedChange::getServerSeq).containsExactly(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 12L);
        assertThat(all).extracting(SequencedChange::getChange).containsExactlyElementsOf(changes);
        assertThat(all).allMatch(c -> c.getAuthor().getUserId().equals(alice.toString()));
        assertThat(fetch(doc, 2, 3)).extracting(SequencedChange::getServerSeq).containsExactly(3L);

        // A fork inside the cold range rebuilds the state from the segments.
        UUID fork = uuid7();
        TestUsers.as(docs, ALICE).fork(ForkRequest.newBuilder().setSourceDocumentId(doc.toString())
                .setNewDocumentId(fork.toString()).setAtServerSeq(5).build());
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ?", fork))
                .isEqualTo(replayHash(changes.subList(0, 5)));
    }

    @Test
    void aColdChangeOfAnUnboundReplicaHasNoAuthorAndTheRunSurvivesABrokenLog() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        for (long s = 1; s <= 6; s++) {
            row(doc, s, replica, s, change(replica, s).toByteArray(), 0, 0);
        }
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 6, 'unused', ?, 0, 0)", doc, "0".repeat(64));
        UUID broken = document(ALICE);
        for (long s = 1; s <= 6; s++) {
            row(broken, s, replica, s, new byte[] {(byte) 0xff, (byte) s}, 0, 0);
        }
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 6, 'unused', ?, 0, 0)", broken, "0".repeat(64));

        run(() -> compactor.scheduled());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(4);
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", broken)).isEqualTo(6);
        List<SequencedChange> cold = fetch(doc, 0, 2);
        assertThat(cold).extracting(SequencedChange::getServerSeq).containsExactly(1L, 2L);
        assertThat(cold).noneMatch(SequencedChange::hasAuthor);
    }
}
