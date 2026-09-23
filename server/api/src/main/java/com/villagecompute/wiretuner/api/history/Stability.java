package com.villagecompute.wiretuner.api.history;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.observability.WtMetrics;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The Stability job (SRV-013, D-067; docs/spec/server.adoc, Jobs). Every
 * {@code wt.jobs.stability.every} (5 minutes) it retires the replicas silent (no push or ack) for
 * {@code wt.replica.retire-after} (90 days) -- their pushes, subscriptions and acks then answer
 * {@code REPLICA_EXPIRED} -- and, for every document with a live replica, raises the stable point
 * to the smallest {@code last_ack_seq} of its live replicas and publishes its collection point
 * (C, T) (crdt-model.adoc, "Stable points, horizons and collection points"):
 *
 * <ol>
 * <li>start from the smallest horizon over the live replicas -- the publication every one of them
 * has confirmed receiving ({@code replica.horizon_seq} and {@code horizon_ms});</li>
 * <li>lower C to the horizon of any change sequenced after C whose horizon is below C (hot rows,
 * and cold segments by their smallest horizon), until none is;</li>
 * <li>lower T to the smallest horizon clock of the changes sequenced after C.</li>
 * </ol>
 *
 * The point is written to {@code document.collect_seq} and {@code collect_time_ms}; every Ack
 * answers it, and the snapshotter collects at it. A document whose replicas are all retired keeps
 * its last point: nothing more can be pushed to it that the point does not already account for.
 */
@ApplicationScoped
public class Stability {

    private static final Logger LOG = Logger.getLogger(Stability.class);

    static final String RETIRE = """
            UPDATE replica SET retired_at = now()
            WHERE retired_at IS NULL AND last_seen_at < now() - make_interval(secs => $1)
            """;

    static final String DOCUMENTS = "SELECT DISTINCT document_id FROM replica WHERE retired_at IS NULL";

    static final String STABLE = """
            UPDATE document SET stable_seq = GREATEST(stable_seq, LEAST(head_seq,
                (SELECT COALESCE(min(last_ack_seq), 0) FROM replica WHERE document_id = $1 AND retired_at IS NULL)))
            WHERE id = $1
            """;

    static final String HORIZON = """
            SELECT min(horizon_seq), min(horizon_ms) FROM replica WHERE document_id = $1 AND retired_at IS NULL
            """;

    /** The smallest horizon below C of a change sequenced after C, hot or cold; null when there is none. */
    static final String LOWER = """
            SELECT LEAST(
                (SELECT min(horizon_seq) FROM change_log
                 WHERE document_id = $1 AND server_seq > $2 AND horizon_seq < $2),
                (SELECT min(min_horizon_seq) FROM cold_segment
                 WHERE document_id = $1 AND to_seq > $2 AND min_horizon_seq < $2))
            """;

    /** The smallest horizon clock of the changes sequenced after C, hot or cold; null when there is none. */
    static final String CLOCK = """
            SELECT LEAST(
                (SELECT min(horizon_ms) FROM change_log WHERE document_id = $1 AND server_seq > $2),
                (SELECT min(min_horizon_ms) FROM cold_segment WHERE document_id = $1 AND to_seq > $2))
            """;

    static final String PUBLISH = "UPDATE document SET collect_seq = $2, collect_time_ms = $3 WHERE id = $1";

    /** A collection point. */
    public record Point(long seq, long timeMs) {
    }

    @ConfigProperty(name = "wt.replica.retire-after", defaultValue = "90D")
    Duration retireAfter;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    WtMetrics metrics;

    @Scheduled(identity = "stability", every = "${wt.jobs.stability.every:5m}", delayed = "${wt.jobs.stability.delay:1m}",
            concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("stability", this::run).replaceWithVoid();
    }

    /** One run: retire silent replicas, then publish every document's stable and collection points. */
    Uni<Void> run() {
        return retire()
                .chain(() -> pool.preparedQuery(DOCUMENTS).execute())
                .map(rows -> {
                    List<UUID> documents = new ArrayList<>();
                    rows.forEach(row -> documents.add(row.getUUID(0)));
                    return documents;
                })
                .chain(documents -> Multi.createFrom().iterable(documents)
                        .onItem().transformToUniAndConcatenate(this::publish)
                        .collect().asList()
                        .invoke(points -> LOG.debugf("stability: %d documents", points.size())))
                .replaceWithVoid();
    }

    /** Retires the replicas silent past the window; the result is how many. */
    public Uni<Integer> retire() {
        return pool.preparedQuery(RETIRE).execute(Tuple.of(retireAfter.toSeconds()))
                .map(rows -> rows.rowCount())
                .invoke(retired -> {
                    metrics.replicasRetired(retired);
                    LOG.infof("stability: %d replicas retired", retired);
                });
    }

    /**
     * Raises the document's stable point and publishes its collection point; the result is the
     * point, or null when the document has no live replica (its point is then left as it was).
     */
    public Uni<Point> publish(UUID documentId) {
        return pool.preparedQuery(STABLE).execute(Tuple.of(documentId))
                .chain(() -> pool.preparedQuery(HORIZON).execute(Tuple.of(documentId)))
                .chain(rows -> {
                    Row row = rows.iterator().next();
                    Long seq = row.getLong(0);
                    return seq == null ? Uni.createFrom().nullItem()
                            : lowered(documentId, seq, row.getLong(1)).call(point -> pool.preparedQuery(PUBLISH)
                                    .execute(Tuple.of(documentId, point.seq(), point.timeMs())));
                });
    }

    /** Lowers (C, T) from the smallest replica horizon past every change sequenced after C with a lower horizon. */
    private Uni<Point> lowered(UUID documentId, long seq, long timeMs) {
        return pool.preparedQuery(LOWER).execute(Tuple.of(documentId, seq)).chain(rows -> {
            Long lower = rows.iterator().next().getLong(0);
            if (lower != null) {
                return lowered(documentId, lower, timeMs);
            }
            return pool.preparedQuery(CLOCK).execute(Tuple.of(documentId, seq)).map(clock -> {
                Long least = clock.iterator().next().getLong(0);
                return new Point(seq, least == null ? timeMs : Math.min(timeMs, least));
            });
        });
    }
}
