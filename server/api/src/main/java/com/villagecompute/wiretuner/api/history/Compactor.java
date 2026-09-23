package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.sync.Protos;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The Compactor job (SRV-007; docs/spec/server.adoc, Jobs). Hourly it moves each document's
 * {@code change_log} rows that a snapshot covers and that are not among the newest
 * {@code wt.compactor.keep} (10,000) into cold segments: the rows in server_seq order, cut into
 * segments of about {@code wt.compactor.segment-bytes} (8 MiB) of change bytes, each stored as one
 * zstd object ({@link SegmentCodec}) under {@code cold/<document>/<from>-<to>} with a
 * {@code cold_segment} row carrying the smallest change horizon in it (D-067), and the rows deleted
 * in the same transaction as the row is written. {@link com.villagecompute.wiretuner.api.sync.ChangeReader}
 * serves the moved range from the segments.
 */
@ApplicationScoped
public class Compactor {

    private static final Logger LOG = Logger.getLogger(Compactor.class);

    /** Where a document's compaction stops: its newest snapshot, and the newest rows kept hot. */
    static final String BOUNDARY = "LEAST(COALESCE(s.newest, 0), d.head_seq - $1)";

    static final String CANDIDATES = """
            SELECT d.id FROM document d
            JOIN (SELECT document_id, max(server_seq) AS newest FROM snapshot GROUP BY document_id) s ON s.document_id = d.id
            WHERE EXISTS (SELECT 1 FROM change_log c WHERE c.document_id = d.id AND c.server_seq <= %s)
            ORDER BY d.id LIMIT $2
            """.formatted(BOUNDARY);

    static final String DOCUMENT_BOUNDARY = """
            SELECT %s FROM document d
            LEFT JOIN (SELECT document_id, max(server_seq) AS newest FROM snapshot WHERE document_id = $2
                       GROUP BY document_id) s ON s.document_id = d.id
            WHERE d.id = $2
            """.formatted(BOUNDARY);

    /** The oldest rows up to the boundary whose bytes before them in the run are under the segment size. */
    static final String SEGMENT = """
            SELECT server_seq, bytes, horizon_seq, horizon_ms FROM (
                SELECT server_seq, bytes, horizon_seq, horizon_ms,
                       sum(byte_size) OVER (ORDER BY server_seq) - byte_size AS before
                FROM change_log WHERE document_id = $1 AND server_seq <= $2) r
            WHERE before < $3 ORDER BY server_seq
            """;

    static final String INSERT_SEGMENT = """
            INSERT INTO cold_segment (document_id, from_seq, to_seq, object_key, compressed_size, change_count,
                                      min_horizon_seq, min_horizon_ms)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            """;

    static final String DELETE_ROWS = "DELETE FROM change_log WHERE document_id = $1 AND server_seq BETWEEN $2 AND $3";

    /** One segment about to be written: its range, changes and smallest horizon. */
    record Segment(UUID documentId, long fromSeq, long toSeq, List<SequencedChange> changes, long minHorizonSeq,
            long minHorizonMs) {

        String key() {
            return "cold/" + documentId + "/" + fromSeq + "-" + toSeq;
        }
    }

    @ConfigProperty(name = "wt.compactor.keep", defaultValue = "10000")
    long keep;

    @ConfigProperty(name = "wt.compactor.segment-bytes", defaultValue = "8388608")
    long segmentBytes;

    @ConfigProperty(name = "wt.compactor.batch", defaultValue = "200")
    int batch;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    BlobStore store;

    @Scheduled(identity = "compactor", every = "${wt.jobs.compactor.every:1h}", delayed = "${wt.jobs.compactor.delay:5m}",
            concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("compactor", this::run).replaceWithVoid();
    }

    /** One run: every document with rows to move, one at a time. */
    Uni<Void> run() {
        return pool.preparedQuery(CANDIDATES).execute(Tuple.of(keep, batch))
                .map(rows -> {
                    List<UUID> documents = new ArrayList<>();
                    rows.forEach(row -> documents.add(row.getUUID(0)));
                    return documents;
                })
                .chain(documents -> Multi.createFrom().iterable(documents)
                        .onItem().transformToUniAndConcatenate(id -> compact(id).onFailure().recoverWithItem(failure -> {
                            LOG.warnf(failure, "compactor: document %s failed", id);
                            return 0;
                        }))
                        .collect().asList()
                        .invoke(done -> LOG.infof("compactor: %d documents", done.size())))
                .replaceWithVoid();
    }

    /** Moves the document's rows up to its boundary into cold segments; the result is how many segments were written. */
    public Uni<Integer> compact(UUID documentId) {
        return pool.preparedQuery(DOCUMENT_BOUNDARY).execute(Tuple.of(keep, documentId))
                .chain(rows -> segments(documentId, rows.iterator().next().getLong(0), 0));
    }

    private Uni<Integer> segments(UUID documentId, long boundary, int written) {
        return pool.preparedQuery(SEGMENT).execute(Tuple.of(documentId, boundary, segmentBytes)).chain(rows -> {
            if (rows.rowCount() == 0) {
                return Uni.createFrom().item(written);
            }
            List<SequencedChange> changes = new ArrayList<>(rows.rowCount());
            long minSeq = Long.MAX_VALUE;
            long minMs = Long.MAX_VALUE;
            for (Row row : rows) {
                changes.add(SequencedChange.newBuilder().setServerSeq(row.getLong(0))
                        .setChange(Protos.change(row.getBuffer(1).getBytes())).build());
                minSeq = Math.min(minSeq, row.getLong(2));
                minMs = Math.min(minMs, row.getLong(3));
            }
            Segment segment = new Segment(documentId, changes.get(0).getServerSeq(),
                    changes.get(changes.size() - 1).getServerSeq(), changes, minSeq, minMs);
            return write(segment).chain(() -> segments(documentId, boundary, written + 1));
        });
    }

    private Uni<Void> write(Segment segment) {
        byte[] object = SegmentCodec.encode(segment.changes());
        return store.put(segment.key(), object, SegmentCodec.MEDIA_TYPE)
                .chain(() -> pool.withTransaction(connection -> connection.preparedQuery(INSERT_SEGMENT)
                        .execute(Tuple.from(new Object[] {segment.documentId(), segment.fromSeq(), segment.toSeq(),
                                segment.key(), (long) object.length, segment.changes().size(), segment.minHorizonSeq(),
                                segment.minHorizonMs()}))
                        .chain(() -> connection.preparedQuery(DELETE_ROWS)
                                .execute(Tuple.of(segment.documentId(), segment.fromSeq(), segment.toSeq())))))
                .invoke(() -> LOG.debugf("compactor: %s %d..%d cold", segment.documentId(), segment.fromSeq(),
                        segment.toSeq()))
                .replaceWithVoid();
    }
}
