package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.doc.v1.Change;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * COLLAB-020's history index backfill: a queued document's changes logged before V11, hot and cold,
 * get their {@code change_node} and {@code node_name} rows once, and the document leaves the queue; one
 * whose log cannot be read stays queued.
 */
@QuarkusTest
class IndexBackfillJobTest extends HistoryTestSupport {

    @Inject
    IndexBackfillJob backfill;

    @Inject
    Snapshotter snapshotter;

    @Inject
    Compactor compactor;

    List<Object> index(UUID doc) {
        return column("""
                SELECT 'n' || node_replica || ':' || node_counter || '@' || server_seq FROM change_node WHERE document_id = ?
                UNION ALL
                SELECT 'k' || node_replica || ':' || node_counter || '@' || server_seq || '=' || kind || '/' || name
                FROM node_name WHERE document_id = ?
                ORDER BY 1
                """, doc, doc);
    }

    @Test
    void changesLoggedBeforeTheIndexAreIndexedOnce() {
        UUID doc = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = new ArrayList<>();
        for (int i = 0; i < 10; i++) {
            changes.add(a.change("Object " + i, DocOps.create(wellKnown(LAYERS), DocOps.path("Object " + i, ""))));
        }
        push(ALICE, null, doc, changes.toArray(Change[]::new));
        run(() -> snapshotter.snapshot(doc));
        assertThat(run(() -> compactor.compact(doc))).isPositive();
        List<Object> indexed = index(doc);
        assertThat(indexed).isNotEmpty();

        // As if logged before V11: no index rows; V12 queued the document with its head.
        exec("DELETE FROM change_node WHERE document_id = ?", doc);
        exec("DELETE FROM node_name WHERE document_id = ?", doc);
        exec("INSERT INTO history_backfill (document_id, through_seq) VALUES (?, 10)", doc);
        // A document whose log has a hole cannot be read: it stays queued, and the run goes on.
        UUID broken = document(ALICE);
        long replica = replicaId();
        row(broken, 1, replica, 1, change(replica, 1).toByteArray(), 0, 0);
        row(broken, 3, replica, 3, change(replica, 3).toByteArray(), 0, 0);
        exec("INSERT INTO history_backfill (document_id, through_seq) VALUES (?, 3)", broken);

        run(() -> backfill.scheduled());
        assertThat(index(doc)).isEqualTo(indexed);
        assertThat(column("SELECT document_id FROM history_backfill WHERE document_id IN (?, ?)", doc, broken))
                .containsExactly(broken);
        exec("DELETE FROM history_backfill WHERE document_id = ?", broken);

        // Nothing queued: a run does nothing.
        run(() -> backfill.run());
        assertThat(index(doc)).isEqualTo(indexed);
    }
}
