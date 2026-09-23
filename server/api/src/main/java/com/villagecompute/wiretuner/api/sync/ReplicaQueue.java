package com.villagecompute.wiretuner.api.sync;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.grpc.CallerContext;
import com.villagecompute.wiretuner.api.observability.WtMetrics;

import io.smallrye.mutiny.Uni;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The per-replica ingest queue of docs/spec/server.adoc (Ingest path): pushes from one replica of
 * one document run on this node one at a time, in the order they were submitted, so pipelined
 * unary calls keep their seq order without the client waiting for each ack.
 *
 * <p>{@link #submit} takes the replica's place in line synchronously, so callers submit in arrival
 * order (inside the gRPC handler, before anything asynchronous) and subscribe the returned Uni at
 * once; the work runs when every earlier submission for the same replica has terminated
 * (succeeded, failed or been cancelled). Different replicas never wait for each other.
 */
@ApplicationScoped
public class ReplicaQueue {

    record Key(UUID document, long replica) {
    }

    private final Map<Key, CompletableFuture<Void>> tails = new ConcurrentHashMap<>();

    @Inject
    WtMetrics metrics;

    /** Exports the queue's size as {@code wt_push_inflight}. */
    @PostConstruct
    void register() {
        metrics.pushInflight(tails::size);
    }

    /** Runs {@code work} after every earlier submission for the replica; the result is re-emitted on the caller's context. */
    public <T> Uni<T> submit(UUID document, long replica, Supplier<Uni<T>> work) {
        Key key = new Key(document, replica);
        CompletableFuture<Void> done = new CompletableFuture<>();
        CompletableFuture<Void> previous = tails.put(key, done);
        Uni<Void> turn = previous == null ? Uni.createFrom().voidItem() : Uni.createFrom().completionStage(previous);
        return turn.chain(() -> work.get())
                .onTermination().invoke(() -> {
                    tails.remove(key, done);
                    done.complete(null);
                })
                .emitOn(CallerContext.executor());
    }

    /** How many replicas have work queued or running (for tests and metrics). */
    int active() {
        return tails.size();
    }
}
