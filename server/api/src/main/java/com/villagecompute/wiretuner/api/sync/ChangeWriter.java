package com.villagecompute.wiretuner.api.sync;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.subscription.UniEmitter;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.RowSet;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Group commit of change inserts per document on this node. The document row lock serialises
 * {@code server_seq}, and it is held until the transaction commits, so one insert per commit caps a
 * document at one change per commit latency (the WAL flush). Instead, while a write for a document
 * is in flight, further inserts for it wait, and are then sent together as one prepared batch: one
 * round trip and one implicit transaction, the lock taken once, the statements executed in arrival
 * order, one commit. Each statement keeps its own conditions ({@link ChangeIngest#INSERT}), so a
 * change that is refused inserts nothing and the others still go in; the result per change is its
 * {@code server_seq}, or null when refused. A statement error fails the whole batch, and every call
 * in it fails.
 */
@ApplicationScoped
public class ChangeWriter {

    /** One insert waiting for its batch. */
    record Pending(Tuple args, UniEmitter<? super Long> result) {
    }

    /** The waiting inserts of one document, and whether a batch of it is in flight. */
    static final class Queue {
        final UUID documentId;
        final List<Pending> pending = new ArrayList<>();
        boolean flushing;

        Queue(UUID documentId) {
            this.documentId = documentId;
        }
    }

    /** At most this many inserts go in one batch (a batch is also bounded by what arrived meanwhile). */
    static final int MAX_BATCH = 256;

    @Inject
    Pool pool;

    private final Map<UUID, Queue> queues = new HashMap<>();

    /** Inserts one change ({@link ChangeIngest#INSERT}'s arguments); the result is its server_seq, or null when refused. */
    public Uni<Long> write(UUID documentId, Tuple args) {
        return Uni.createFrom().emitter(result -> enqueue(documentId, new Pending(args, result)));
    }

    private synchronized void enqueue(UUID documentId, Pending insert) {
        Queue queue = queues.computeIfAbsent(documentId, Queue::new);
        queue.pending.add(insert);
        if (!queue.flushing) {
            flush(queue);
        }
    }

    /** Sends what is waiting as one batch; called holding the lock. */
    private void flush(Queue queue) {
        List<Pending> batch = new ArrayList<>(queue.pending.subList(0, Math.min(queue.pending.size(), MAX_BATCH)));
        queue.pending.subList(0, batch.size()).clear();
        queue.flushing = true;
        pool.preparedQuery(ChangeIngest.INSERT).executeBatch(batch.stream().map(Pending::args).toList())
                .subscribe().with(rows -> written(queue, batch, rows), failure -> failed(queue, batch, failure));
    }

    private void written(Queue queue, List<Pending> batch, RowSet<Row> rows) {
        RowSet<Row> result = rows;
        for (Pending insert : batch) {
            insert.result().complete(result.rowCount() == 0 ? null : result.iterator().next().getLong(0));
            result = result.next();
        }
        next(queue);
    }

    private void failed(Queue queue, List<Pending> batch, Throwable failure) {
        batch.forEach(insert -> insert.result().fail(failure));
        next(queue);
    }

    private synchronized void next(Queue queue) {
        queue.flushing = false;
        if (queue.pending.isEmpty()) {
            queues.remove(queue.documentId);
        } else {
            flush(queue);
        }
    }
}
