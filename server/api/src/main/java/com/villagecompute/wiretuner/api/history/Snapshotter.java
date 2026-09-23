package com.villagecompute.wiretuner.api.history;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.observability.WtMetrics;
import com.villagecompute.wiretuner.api.persistence.DocumentSearchRepository;
import com.villagecompute.wiretuner.crdt.Engine;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The Snapshotter job (SRV-007; docs/spec/server.adoc, Jobs). Every {@code wt.jobs.snapshots.every}
 * (2 minutes) it snapshots each live document with changes since its newest snapshot that has more
 * than {@code wt.snapshots.changes} (2,000) of them, or whose newest snapshot (its creation, when it
 * has none) is older than {@code wt.snapshots.age} (30 minutes), or whose last subscription on a
 * node closed since ({@link #closed}). A snapshot is the state at the head: the newest snapshot
 * plus the tail through {@code wt-crdt} ({@link DocumentStates}), collected at the document's
 * published collection point (D-067) and stored by {@link Snapshots}; the document's search record
 * is then extracted from the same state ({@link SearchExtractor}) and its {@code document_search}
 * row rewritten. A document that fails is logged and left for the next run.
 */
@ApplicationScoped
public class Snapshotter {

    private static final Logger LOG = Logger.getLogger(Snapshotter.class);

    static final String DUE = """
            SELECT d.id FROM document d
            LEFT JOIN LATERAL (SELECT max(server_seq) AS seq, max(created_at) AS at FROM snapshot s
                               WHERE s.document_id = d.id) s ON true
            WHERE d.trashed_at IS NULL AND d.head_seq > COALESCE(s.seq, 0)
              AND (d.head_seq - COALESCE(s.seq, 0) > $1
                   OR COALESCE(s.at, d.created_at) < now() - make_interval(secs => $2)
                   OR d.snapshot_due_at IS NOT NULL)
            ORDER BY d.snapshot_due_at NULLS LAST, d.id
            LIMIT $3
            """;

    static final String DOCUMENT = "SELECT head_seq, collect_seq, collect_time_ms FROM document WHERE id = $1";

    static final String CLOSED = """
            UPDATE document SET snapshot_due_at = now()
            WHERE id = $1 AND head_seq > (SELECT COALESCE(max(server_seq), 0) FROM snapshot WHERE document_id = $1)
            """;

    static final String DONE = "UPDATE document SET snapshot_due_at = NULL WHERE id = $1";

    @ConfigProperty(name = "wt.snapshots.changes", defaultValue = "2000")
    long changes;

    @ConfigProperty(name = "wt.snapshots.age", defaultValue = "30M")
    Duration age;

    @ConfigProperty(name = "wt.snapshots.batch", defaultValue = "200")
    int batch;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    DocumentStates states;

    @Inject
    Snapshots snapshots;

    @Inject
    DocumentSearchRepository search;

    @Inject
    WtMetrics metrics;

    @Scheduled(identity = "snapshots", every = "${wt.jobs.snapshots.every:2m}", delayed = "${wt.jobs.snapshots.delay:1m}",
            concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("snapshots", this::run).replaceWithVoid();
    }

    /** One run: every due document, one at a time. */
    Uni<Void> run() {
        return pool.preparedQuery(DUE).execute(Tuple.of(changes, age.toSeconds(), batch))
                .map(rows -> {
                    List<UUID> due = new ArrayList<>();
                    rows.forEach(row -> due.add(row.getUUID(0)));
                    return due;
                })
                .chain(due -> Multi.createFrom().iterable(due)
                        .onItem().transformToUniAndConcatenate(id -> snapshot(id).onFailure().recoverWithItem(failure -> {
                            LOG.warnf(failure, "snapshots: document %s failed", id);
                            return 0L;
                        }))
                        .collect().asList()
                        .invoke(done -> LOG.infof("snapshots: %d documents", done.size())))
                .replaceWithVoid();
    }

    /**
     * Snapshots the document at its head, collected at its collection point, and rewrites its
     * search record; the result is the head.
     */
    public Uni<Long> snapshot(UUID documentId) {
        long started = System.nanoTime();
        return pool.preparedQuery(DOCUMENT).execute(Tuple.of(documentId)).chain(rows -> {
            Row row = rows.iterator().next();
            long head = row.getLong(0);
            long collectSeq = row.getLong(1);
            long collectTime = row.getLong(2);
            return states.at(documentId, head)
                    .invoke(engine -> collect(engine, collectSeq, collectTime))
                    .call(engine -> snapshots.write(documentId, head, engine, collectSeq, collectTime))
                    .invoke(() -> metrics.snapshot(System.nanoTime() - started))
                    .chain(engine -> index(documentId, head, engine))
                    .chain(() -> pool.preparedQuery(DONE).execute(Tuple.of(documentId)))
                    .replaceWith(head);
        });
    }

    /** Collects {@code engine} at the collection point (C, T) when one is published (C above 0). */
    static void collect(Engine engine, long collectSeq, long collectTimeMs) {
        if (collectSeq > 0) {
            engine.collect(collectSeq, Clock.fixed(Instant.ofEpochMilli(collectTimeMs), ZoneOffset.UTC));
        }
    }

    /** Extracts the search record from {@code engine} and rewrites the document's row. */
    private Uni<Integer> index(UUID documentId, long head, Engine engine) {
        long started = System.nanoTime();
        SearchExtractor.Record record = SearchExtractor.extract(engine.store());
        metrics.searchExtract(System.nanoTime() - started);
        return Panache.withTransaction(() -> search.upsert(documentId, head, record.names(), record.bodyText()));
    }

    /** The document's last subscription on this node closed: snapshot it at the next run if it changed since the newest snapshot. */
    public Uni<Void> closed(UUID documentId) {
        return pool.preparedQuery(CLOSED).execute(Tuple.of(documentId)).replaceWithVoid();
    }
}
