package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import com.villagecompute.wiretuner.sync.v1.PresenceSnapshot;
import com.villagecompute.wiretuner.sync.v1.PresenceState;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;
import io.vertx.mutiny.redis.client.Response;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Presence (SRV-012; docs/spec/sync-protocol.adoc, Presence): the last state of each replica on a
 * document lives in Valkey -- the state in the hash {@code presence:<doc>:state}, its expiry time in
 * the sorted set {@code presence:<doc>} -- and every update is fanned out as a {@code PresenceUpdate}
 * frame on the document's subscriptions.
 *
 * <p>A document and its branches share one presence (COLLAB-005): a session on a branch is stored
 * under the parent (the family's root), keyed by its document and replica, and every update is
 * published on the parent's channel, which a branch's subscriptions also listen to for presence
 * ({@link SyncGrpcService}). So the parent's sessions see the branch's people (with
 * {@code branch_id} set) and the other way round.
 *
 * <ul>
 * <li><b>20 Hz, coalesced.</b> A replica's updates go out at most once per {@code wt.presence.interval}
 * (50 ms) on this node; one that arrives sooner waits for the end of the interval, and a later one
 * replaces it meanwhile, so the newest state always goes out and nothing queues up. The call itself
 * always succeeds: presence is current state, and a dropped intermediate state costs nothing.</li>
 * <li><b>15 s expiry.</b> An entry expires {@code wt.presence.ttl} after its last update. Every second
 * each node sweeps the documents it has subscriptions on and fans out {@code GONE} for expired
 * entries (the node that removes the entry from the set announces it, so exactly one does): a crashed
 * client whose stream the server has not noticed disappears for the others within the TTL plus a
 * second. {@code GONE} from the client, or the end of its subscription, removes it at once.</li>
 * </ul>
 */
@ApplicationScoped
public class PresenceStore {

    private static final Logger LOG = Logger.getLogger(PresenceStore.class);

    @ConfigProperty(name = "wt.presence.ttl", defaultValue = "15S")
    Duration ttl;

    @ConfigProperty(name = "wt.presence.interval", defaultValue = "50MS")
    Duration interval;

    @Inject
    Redis redis;

    @Inject
    SyncBus bus;

    record Key(UUID document, long replica) {
    }

    /** One replica's rate-limit slot on this node: when it last went out, and the update waiting to. */
    static final class Slot {
        long sentAt;
        PresenceUpdate pending;

        Slot(long sentAt) {
            this.sentAt = sentAt;
        }

        synchronized void cancel() {
            pending = null;
        }
    }

    final Map<Key, Slot> slots = new ConcurrentHashMap<>();

    /** The sorted set of the document's replicas by expiry time (epoch ms). */
    static String deadlines(UUID documentId) {
        return "presence:" + documentId;
    }

    /** The hash of the document's replicas' last states. */
    static String states(UUID documentId) {
        return "presence:" + documentId + ":state";
    }

    /** A session's member in its family's set and hash: the document it is on and its replica. */
    static String member(UUID documentId, long replica) {
        return documentId + ":" + Long.toUnsignedString(replica);
    }

    /**
     * Stores and fans out a server-filled update of the session on {@code documentId} (whose presence
     * family is {@code root}: the document, or a branch's parent), at most one per interval per
     * replica; {@code GONE} removes the entry.
     */
    public Uni<Void> update(UUID root, UUID documentId, long replica, PresenceUpdate update) {
        if (update.getState() == PresenceState.PRESENCE_STATE_GONE) {
            return leave(root, documentId, replica, update);
        }
        long now = System.nanoTime();
        Slot slot = slots.computeIfAbsent(new Key(documentId, replica), k -> new Slot(now - interval.toNanos()));
        synchronized (slot) {
            boolean waiting = slot.pending != null;
            long wait = slot.sentAt + interval.toNanos() - now;
            if (waiting || wait > 0) {
                slot.pending = update;
                if (!waiting) {
                    flushLater(root, documentId, replica, slot, wait);
                }
                return Uni.createFrom().voidItem();
            }
            slot.sentAt = now;
        }
        return store(root, member(documentId, replica), update);
    }

    /** Sends the slot's waiting update when its interval ends, unless the replica left meanwhile. */
    private void flushLater(UUID root, UUID documentId, long replica, Slot slot, long waitNanos) {
        Uni.createFrom().voidItem().onItem().delayIt().by(Duration.ofNanos(waitNanos))
                .chain(() -> {
                    PresenceUpdate next;
                    synchronized (slot) {
                        next = slot.pending;
                        slot.pending = null;
                        slot.sentAt = System.nanoTime();
                    }
                    return next == null ? Uni.createFrom().voidItem() : store(root, member(documentId, replica), next);
                })
                .subscribe().with(ignored -> { }, failure -> LOG.warnf(failure, "presence flush for %s failed", documentId));
    }

    /** Stores the entry in the family's set and hash and fans it out on the family's channel (the root document's). */
    private Uni<Void> store(UUID root, String member, PresenceUpdate update) {
        long ttlMillis = ttl.toMillis();
        return redis.batch(List.of(
                        Request.cmd(Command.ZADD).arg(deadlines(root)).arg(System.currentTimeMillis() + ttlMillis).arg(member),
                        Request.cmd(Command.HSET).arg(states(root)).arg(member).arg(Buffer.buffer(update.toByteArray())),
                        Request.cmd(Command.PEXPIRE).arg(deadlines(root)).arg(2 * ttlMillis),
                        Request.cmd(Command.PEXPIRE).arg(states(root)).arg(2 * ttlMillis)))
                .chain(() -> bus.publish(root, ServerFrame.newBuilder().setPresenceUpdate(update).build()));
    }

    /** Removes the session's entry; if it had one, fans out {@code gone} (a GONE update). */
    public Uni<Void> leave(UUID root, UUID documentId, long replica, PresenceUpdate gone) {
        Optional.ofNullable(slots.remove(new Key(documentId, replica))).ifPresent(Slot::cancel);
        String member = member(documentId, replica);
        return redis.send(Request.cmd(Command.ZREM).arg(deadlines(root)).arg(member))
                .call(() -> redis.send(Request.cmd(Command.HDEL).arg(states(root)).arg(member)))
                .chain(removed -> removed.toInteger() == 0 ? Uni.createFrom().voidItem()
                        : bus.publish(root, ServerFrame.newBuilder().setPresenceUpdate(gone).build()));
    }

    /** Everyone present in the family of {@code documentId} (the document and its branches) now. */
    public Uni<PresenceSnapshot> snapshot(UUID documentId) {
        return redis.send(Request.cmd(Command.ZRANGEBYSCORE).arg(deadlines(documentId))
                        .arg(System.currentTimeMillis()).arg("+inf"))
                .chain(live -> {
                    if (live.size() == 0) {
                        return Uni.createFrom().item(PresenceSnapshot.getDefaultInstance());
                    }
                    Request get = Request.cmd(Command.HMGET).arg(states(documentId));
                    live.forEach(member -> get.arg(member.toString()));
                    return redis.send(get).map(values -> {
                        PresenceSnapshot.Builder snapshot = PresenceSnapshot.newBuilder();
                        for (Response value : values) {
                            if (value != null) {
                                snapshot.addParticipants(Protos.parse(PresenceUpdate.parser(), value.toBytes()));
                            }
                        }
                        return snapshot.build();
                    });
                });
    }

    /**
     * Fans out {@code GONE} for every expired entry on the documents this node has subscriptions on,
     * and forgets the rate-limit slots of replicas silent for longer than the TTL.
     */
    @Scheduled(every = "${wt.presence.sweep:1S}", concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    Uni<Void> sweep() {
        long now = System.nanoTime();
        slots.values().removeIf(slot -> now - slot.sentAt > ttl.toNanos());
        List<UUID> documents = new ArrayList<>(bus.documents());
        return Multi.createFrom().iterable(documents)
                .onItem().transformToUniAndConcatenate(this::expire)
                .collect().last()
                .replaceWithVoid();
    }

    /** Removes and announces the document's expired entries. */
    Uni<Void> expire(UUID documentId) {
        return redis.send(Request.cmd(Command.ZRANGEBYSCORE).arg(deadlines(documentId)).arg("-inf")
                        .arg(System.currentTimeMillis()))
                .onItem().transformToMulti(expired -> Multi.createFrom().iterable(expired))
                .onItem().transformToUniAndConcatenate(member -> expire(documentId, member.toString()))
                .collect().last()
                .replaceWithVoid();
    }

    /** Removes and announces one expired entry, unless another node already has. */
    Uni<Void> expire(UUID documentId, String member) {
        return redis.send(Request.cmd(Command.ZREM).arg(deadlines(documentId)).arg(member)).chain(removed -> {
            if (removed.toInteger() == 0) {
                return Uni.createFrom().voidItem();
            }
            return redis.send(Request.cmd(Command.HGET).arg(states(documentId)).arg(member))
                    .call(() -> redis.send(Request.cmd(Command.HDEL).arg(states(documentId)).arg(member)))
                    .chain(state -> state == null ? Uni.createFrom().voidItem()
                            : bus.publish(documentId, ServerFrame.newBuilder().setPresenceUpdate(gone(
                                    Protos.parse(PresenceUpdate.parser(), state.toBytes()))).build()));
        });
    }

    /** The GONE update announcing that the participant of {@code last} left. */
    static PresenceUpdate gone(PresenceUpdate last) {
        return PresenceUpdate.newBuilder().setUser(last.getUser()).setColorIndex(last.getColorIndex())
                .setBranchId(last.getBranchId()).setSession(last.getSession()).setState(PresenceState.PRESENCE_STATE_GONE)
                .build();
    }
}
