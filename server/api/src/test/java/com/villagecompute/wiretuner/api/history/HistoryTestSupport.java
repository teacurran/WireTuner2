package com.villagecompute.wiretuner.api.history;

import java.util.List;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeBatchResponse;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;

import io.quarkus.vertx.VertxContextSupport;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/** Pushing real changes, replaying them locally, and running reactive job steps for the history tests. */
public abstract class HistoryTestSupport extends SyncTestSupport {

    @Inject
    protected BlobStore store;

    /** Runs reactive work on a Vert.x context and waits for it. */
    public static <T> T run(Supplier<Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(work);
        } catch (Throwable t) {
            throw t instanceof RuntimeException re ? re : new IllegalStateException(t);
        }
    }

    /** Pushes each change as {@code user}; the result is the last server_seq. */
    protected long push(String user, UUID device, UUID document, Change... changes) {
        long seq = 0;
        for (Change change : changes) {
            seq = blocking(user, device).pushChange(PushChangeRequest.newBuilder().setDocumentId(document.toString())
                    .setChange(change).build()).getServerSeq();
        }
        return seq;
    }

    /** Pushes {@code changes} as {@code user} in batches of 32; the result is the last server_seq. */
    protected long pushAll(String user, UUID device, UUID document, List<Change> changes) {
        long seq = 0;
        for (int from = 0; from < changes.size(); from += 32) {
            PushChangeBatchResponse response = blocking(user, device).pushChangeBatch(PushChangeBatchRequest.newBuilder()
                    .setDocumentId(document.toString()).addAllChanges(changes.subList(from, Math.min(from + 32, changes.size())))
                    .build());
            seq = response.getServerSeqs(response.getServerSeqsCount() - 1);
        }
        return seq;
    }

    /** The state hash (hex) of {@code changes} applied in order at server_seq 1, 2, ... */
    protected static String replayHash(List<Change> changes) {
        return StateHash.hex(replay(changes).stateHash());
    }

    protected static Engine replay(List<Change> changes) {
        Engine engine = new Engine();
        for (int i = 0; i < changes.size(); i++) {
            engine.apply(changes.get(i), (long) i + 1);
        }
        return engine;
    }

    /** Appends a raw log row (the ingest bypassed) with a horizon, and moves the head to it. */
    protected void row(UUID document, long serverSeq, long replica, long seq, byte[] bytes, long horizonSeq, long horizonMs) {
        exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size, horizon_seq, horizon_ms)"
                + " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", document, serverSeq, replica, seq, bytes, bytes.length, horizonSeq, horizonMs);
        exec("UPDATE document SET head_seq = GREATEST(head_seq, ?) WHERE id = ?", serverSeq, document);
    }

    /** Whether the object exists in storage. */
    protected boolean stored(String key) {
        try {
            run(() -> store.bytes(key));
            return true;
        } catch (RuntimeException e) {
            return false;
        }
    }
}
