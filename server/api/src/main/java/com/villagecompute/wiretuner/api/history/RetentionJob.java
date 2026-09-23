package com.villagecompute.wiretuner.api.history;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The daily history Retention job (COLLAB-020; history.adoc, How long history is kept, and Server).
 * Each document keeps every change for its window -- {@code wt.history.retention} (30 days), or its
 * team's {@code history_retention_days} when that is longer -- and, beyond it, only its named
 * versions' pinned snapshots.
 *
 * <p>The cut is the newest snapshot made before the window began: every change at or below it was
 * sequenced before then, and the state at the cut stays whole in that snapshot. It is held down to
 * the document's stable point (a live replica has not yet acknowledged the changes above it, and may
 * still ask for them) and, for an active branch, to its fork or last merge point (a merge replays the
 * branch's changes after it). At or below the cut the job deletes the hot rows, the cold segments
 * wholly below it (a segment straddling the cut is kept whole, and the rows it holds with it), the
 * touched-node rows of the deleted changes, and every snapshot below the cut that no pinned version
 * names; then the deleted segments' and snapshots' objects. The names index ({@code node_name}) is
 * kept: a node's name at a later seq is its newest row at or before it. Blob references are per
 * document and outlive every change, so a pinned version's blobs stay (the Trash job removes blobs
 * only once no document references them).
 */
@ApplicationScoped
public class RetentionJob {

    private static final Logger LOG = Logger.getLogger(RetentionJob.class);

    /**
     * Documents with something to delete, with their cut ($1 the default window in seconds, $2 the
     * batch).
     */
    static final String CANDIDATES = """
            SELECT d.id, cut.seq FROM document d
            LEFT JOIN team t ON t.id = d.team_id
            LEFT JOIN branch b ON b.document_id = d.id AND b.state = 'active'
            CROSS JOIN LATERAL (
                SELECT max(s.server_seq) AS seq FROM snapshot s
                WHERE s.document_id = d.id
                  AND s.created_at < now() - GREATEST(make_interval(secs => $1),
                                                      coalesce(make_interval(days => t.history_retention_days),
                                                               make_interval(secs => $1)))
                  AND s.server_seq <= d.stable_seq
                  AND (b.document_id IS NULL OR s.server_seq <= GREATEST(b.fork_seq, b.merged_branch_seq))
            ) cut
            WHERE cut.seq IS NOT NULL
              AND (EXISTS (SELECT 1 FROM change_log c WHERE c.document_id = d.id AND c.server_seq <= cut.seq)
                   OR EXISTS (SELECT 1 FROM cold_segment c WHERE c.document_id = d.id AND c.to_seq <= cut.seq)
                   OR EXISTS (SELECT 1 FROM snapshot s WHERE s.document_id = d.id AND s.server_seq < cut.seq
                              AND NOT EXISTS (SELECT 1 FROM version v WHERE v.document_id = d.id
                                              AND v.server_seq = s.server_seq AND v.pinned)))
            ORDER BY d.id LIMIT $2
            """;

    /** The seq the log is deleted through: below a segment straddling the cut ($2), else the cut. */
    static final String LOG_CUT = """
            SELECT coalesce((SELECT min(from_seq) - 1 FROM cold_segment
                             WHERE document_id = $1 AND from_seq <= $2 AND to_seq > $2), $2)
            """;

    static final String DELETE_ROWS = "DELETE FROM change_log WHERE document_id = $1 AND server_seq <= $2";

    static final String DELETE_INDEX = "DELETE FROM change_node WHERE document_id = $1 AND server_seq <= $2";

    static final String DELETE_SEGMENTS = """
            DELETE FROM cold_segment WHERE document_id = $1 AND to_seq <= $2 RETURNING object_key
            """;

    static final String DELETE_SNAPSHOTS = """
            DELETE FROM snapshot s WHERE s.document_id = $1 AND s.server_seq < $2
              AND NOT EXISTS (SELECT 1 FROM version v
                              WHERE v.document_id = s.document_id AND v.server_seq = s.server_seq AND v.pinned)
            RETURNING object_key
            """;

    /** One document to trim: its cut. */
    record Due(UUID documentId, long cut) {
    }

    @ConfigProperty(name = "wt.history.retention", defaultValue = "30D")
    Duration retention;

    @ConfigProperty(name = "wt.history.retention-batch", defaultValue = "500")
    int batch;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    BlobStore store;

    @Scheduled(identity = "history-retention", every = "${wt.jobs.history-retention.every:24h}",
            delayed = "${wt.jobs.history-retention.delay:6m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("history-retention", this::run).replaceWithVoid();
    }

    /** One run: every document with history past its window, one at a time. */
    Uni<Void> run() {
        return pool.preparedQuery(CANDIDATES).execute(Tuple.of(retention.toSeconds(), batch))
                .map(RetentionJob::due)
                .chain(due -> Multi.createFrom().iterable(due)
                        .onItem().transformToUniAndConcatenate(this::trim)
                        .collect().asList()
                        .invoke(trimmed -> LOG.infof("history retention: %d documents trimmed", trimmed.size())))
                .replaceWithVoid();
    }

    /** Deletes one document's history at or below its cut, then the objects that held it; the result is how many objects. */
    Uni<Integer> trim(Due due) {
        UUID id = due.documentId();
        return pool.withTransaction(connection -> connection.preparedQuery(LOG_CUT).execute(Tuple.of(id, due.cut()))
                .map(rows -> rows.iterator().next().getLong(0))
                .chain(logCut -> connection.preparedQuery(DELETE_ROWS).execute(Tuple.of(id, logCut))
                        .chain(() -> connection.preparedQuery(DELETE_INDEX).execute(Tuple.of(id, logCut)))
                        .chain(() -> connection.preparedQuery(DELETE_SEGMENTS).execute(Tuple.of(id, logCut))))
                .map(RetentionJob::keys)
                .chain(keys -> connection.preparedQuery(DELETE_SNAPSHOTS).execute(Tuple.of(id, due.cut()))
                        .map(rows -> {
                            keys.addAll(keys(rows));
                            return keys;
                        })))
                .call(keys -> Multi.createFrom().iterable(keys)
                        .onItem().transformToUniAndConcatenate(store::delete)
                        .collect().last())
                .map(List::size)
                .invoke(objects -> LOG.debugf("history retention: %s through %d, %d objects", id, due.cut(), objects));
    }

    private static List<Due> due(RowSet<Row> rows) {
        List<Due> due = new ArrayList<>();
        rows.forEach(row -> due.add(new Due(row.getUUID(0), row.getLong(1))));
        return due;
    }

    private static List<String> keys(RowSet<Row> rows) {
        List<String> keys = new ArrayList<>();
        rows.forEach(row -> keys.add(row.getString(0)));
        return keys;
    }
}
