package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.TreeMap;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.subscription.MultiEmitter;

/**
 * The live part of one subscription: frames from the {@link SyncBus}, with changes put back into
 * {@code server_seq} order without gap or duplicate. It is registered before the subscription
 * reads the head (so nothing committed later is missed) and collects until {@link #start} names
 * the first seq the subscriber has not had from the replay; from then on changes below that are
 * dropped, changes above a gap wait for it, and a gap still open after {@code gapWait} is filled
 * from the log (a frame can overtake another between nodes, or be lost with a Valkey connection).
 * Frames other than changes pass straight through, after the replay; an {@code AccessRemoved} event
 * (sent to this subscription's account only) ends the subscription after it is delivered.
 */
final class LiveFeed implements SyncBus.Listener {

    private final UUID documentId;
    private final UUID account;
    private final ChangeReader reader;
    private final Duration gapWait;
    private final TreeMap<Long, ServerFrame> pending = new TreeMap<>();
    private final List<ServerFrame> early = new ArrayList<>();
    private MultiEmitter<? super ServerFrame> out;
    /** The next seq to emit; until {@link #start}, beyond any seq, so a resync reads nothing. */
    private long next = Long.MAX_VALUE;
    private boolean filling;

    LiveFeed(UUID documentId, UUID account, ChangeReader reader, Duration gapWait) {
        this.documentId = documentId;
        this.account = account;
        this.reader = reader;
        this.gapWait = gapWait;
    }

    /** Starts emitting at {@code next}: the seq after the replay. */
    synchronized void start(long next, MultiEmitter<? super ServerFrame> out) {
        this.next = next;
        this.out = out;
        early.forEach(this::emit);
        early.clear();
        drain();
    }

    @Override
    public UUID account() {
        return account;
    }

    /** A heartbeat frame; only called after {@link #start}. */
    synchronized void heartbeat(ServerFrame pong) {
        out.emit(pong);
    }

    /** Emits a frame; {@code AccessRemoved} is the subscription's last. */
    private void emit(ServerFrame frame) {
        out.emit(frame);
        if (frame.getEvent().hasAccessRemoved()) {
            out.complete();
        }
    }

    @Override
    public synchronized void frame(ServerFrame frame) {
        if (frame.hasChange()) {
            pending.put(frame.getChange().getServerSeq(), frame);
            if (out != null) {
                drain();
            }
        } else if (out == null) {
            early.add(frame);
        } else {
            emit(frame);
        }
    }

    @Override
    public void resync() {
        fill(() -> reader.head(documentId).map(head -> new long[] {nextSeq() - 1, head}));
    }

    private synchronized long nextSeq() {
        return next;
    }

    /** Emits the contiguous run at {@code next}; a remaining gap is filled after {@code gapWait}. */
    private void drain() {
        pending.headMap(next).clear();
        while (!pending.isEmpty() && pending.firstKey() == next) {
            out.emit(pending.pollFirstEntry().getValue());
            next++;
        }
        if (!pending.isEmpty() && !filling) {
            filling = true;
            fill(() -> Uni.createFrom().voidItem().onItem().delayIt().by(gapWait).map(ignored -> gap()));
        }
    }

    /**
     * The open gap as (after, until), or null once it has closed by itself. Every frame is drained on
     * arrival, so whatever is pending lies beyond a gap.
     */
    private synchronized long[] gap() {
        filling = false;
        return pending.isEmpty() ? null : new long[] {next - 1, pending.firstKey() - 1};
    }

    /** Reads the log over the range {@code range} yields (null = nothing to read) and feeds it in. */
    private void fill(Supplier<Uni<long[]>> range) {
        range.get()
                .chain(r -> r == null ? Uni.createFrom().item(List.<SequencedChange>of())
                        : reader.range(documentId, r[0], r[1]).collect().asList())
                .subscribe().with(
                        changes -> changes.forEach(change -> frame(ServerFrame.newBuilder().setChange(change).build())),
                        this::fail);
    }

    private synchronized void fail(Throwable failure) {
        out.fail(failure);
    }
}
