package com.villagecompute.wiretuner.api.history;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.api.jobs.JobLocks;
import com.villagecompute.wiretuner.api.sync.ChangeReader;
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
 * The history index backfill (COLLAB-020; history.adoc, Server): a one-shot job for the changes logged
 * before V11 wrote {@code change_node} and {@code node_name} with each change. V12 queued every
 * document that had changes then in {@code history_backfill}, with its head at the time; this job,
 * under its advisory lock, reads each queued document's log from its oldest retained change through
 * that head -- hot rows and cold segments, as catch-up reads them -- writes each change's index rows
 * ({@link ChangeIndex#WRITE}, which ignores rows already there, so changes indexed at ingest after V11
 * cost nothing), and takes the document off the queue. A document whose log cannot be read is left
 * queued for the next run. Once the queue is empty a run is one empty query.
 */
@ApplicationScoped
public class IndexBackfillJob {

    private static final Logger LOG = Logger.getLogger(IndexBackfillJob.class);

    /** Changes per index batch. */
    static final int CHUNK = ChangeReader.PAGE;

    static final String PENDING = "SELECT document_id, through_seq FROM history_backfill ORDER BY document_id LIMIT $1";

    /** The seq before the document's oldest retained change, hot or cold ($2 the queued head). */
    static final String BEFORE_OLDEST = """
            SELECT LEAST(coalesce((SELECT min(server_seq) FROM change_log WHERE document_id = $1), $2 + 1),
                         coalesce((SELECT min(from_seq) FROM cold_segment WHERE document_id = $1), $2 + 1)) - 1
            """;

    static final String DONE = "DELETE FROM history_backfill WHERE document_id = $1";

    /** One queued document: the head its index is backfilled through. */
    record Queued(UUID documentId, long throughSeq) {
    }

    @ConfigProperty(name = "wt.history.backfill-batch", defaultValue = "100")
    int batch;

    @Inject
    Pool pool;

    @Inject
    JobLocks locks;

    @Inject
    ChangeReader reader;

    @Scheduled(identity = "history-backfill", every = "${wt.jobs.history-backfill.every:1h}",
            delayed = "${wt.jobs.history-backfill.delay:2m}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> scheduled() {
        return locks.exclusively("history-backfill", this::run).replaceWithVoid();
    }

    /** One run: up to a batch of queued documents, one at a time; a failed one stays queued. */
    Uni<Void> run() {
        return pool.preparedQuery(PENDING).execute(Tuple.of(batch))
                .map(rows -> {
                    List<Queued> queued = new ArrayList<>();
                    for (Row row : rows) {
                        queued.add(new Queued(row.getUUID(0), row.getLong(1)));
                    }
                    return queued;
                })
                .chain(queued -> Multi.createFrom().iterable(queued)
                        .onItem().transformToUniAndConcatenate(q -> backfill(q).onFailure().recoverWithItem(failure -> {
                            LOG.warnf(failure, "history backfill: document %s stays queued", q.documentId());
                            return 0L;
                        }))
                        .collect().asList()
                        .invoke(done -> LOG.infof("history backfill: %d documents", done.size())))
                .replaceWithVoid();
    }

    /** Indexes one document's changes through its queued head and takes it off the queue; the result is how many. */
    Uni<Long> backfill(Queued queued) {
        UUID id = queued.documentId();
        return pool.preparedQuery(BEFORE_OLDEST).execute(Tuple.of(id, queued.throughSeq()))
                .map(rows -> rows.iterator().next().getLong(0))
                .chain(after -> reader.range(id, after, queued.throughSeq())
                        .group().intoLists().of(CHUNK)
                        .onItem().transformToUniAndConcatenate(changes -> index(id, changes))
                        .collect().with(Collectors.summingLong(Integer::longValue)))
                .call(() -> pool.preparedQuery(DONE).execute(Tuple.of(id)))
                .invoke(count -> LOG.debugf("history backfill: %s, %d changes", id, count));
    }

    private Uni<Integer> index(UUID documentId, List<SequencedChange> changes) {
        List<Tuple> rows = new ArrayList<>(changes.size());
        for (SequencedChange change : changes) {
            rows.add(ChangeIndex.entries(change.getChange()).tuple(documentId, change.getServerSeq()));
        }
        return pool.preparedQuery(ChangeIndex.WRITE).executeBatch(rows).replaceWith(changes.size());
    }
}
