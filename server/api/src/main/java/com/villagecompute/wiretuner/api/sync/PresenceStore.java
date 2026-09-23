package com.villagecompute.wiretuner.api.sync;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import com.villagecompute.wiretuner.sync.v1.PresenceSnapshot;
import com.villagecompute.wiretuner.sync.v1.PresenceState;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.redis.client.Command;
import io.vertx.mutiny.redis.client.Redis;
import io.vertx.mutiny.redis.client.Request;
import io.vertx.mutiny.redis.client.Response;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Minimal presence (SRV-005; the full model, rate limit and branch relay are SRV-012): the last
 * state of each replica on a document lives in Valkey under {@code presence:<doc>:<replica>} with a
 * 15 s time to live, the document's replicas in the set {@code presence:<doc>}; every update is
 * fanned out as a {@code PresenceUpdate} frame. {@code GONE}, or the end of the replica's
 * subscription, removes the entry and fans out {@code GONE} at once.
 */
@ApplicationScoped
public class PresenceStore {

    /** An entry expires this long after its last update (docs/spec/sync-protocol.adoc, Presence). */
    static final int TTL_SECONDS = 15;

    @Inject
    Redis redis;

    @Inject
    SyncBus bus;

    static String entry(UUID documentId, long replica) {
        return members(documentId) + ":" + Long.toUnsignedString(replica);
    }

    static String members(UUID documentId) {
        return "presence:" + documentId;
    }

    /** Stores and fans out a server-filled update; {@code GONE} removes the entry instead. */
    public Uni<Void> update(UUID documentId, long replica, PresenceUpdate update) {
        if (update.getState() == PresenceState.PRESENCE_STATE_GONE) {
            return leave(documentId, replica, update);
        }
        String key = entry(documentId, replica);
        return redis.send(Request.cmd(Command.SET).arg(key).arg(Buffer.buffer(update.toByteArray()))
                        .arg("EX").arg(TTL_SECONDS))
                .chain(() -> redis.send(Request.cmd(Command.SADD).arg(members(documentId)).arg(Long.toUnsignedString(replica))))
                .chain(() -> bus.publish(documentId, ServerFrame.newBuilder().setPresenceUpdate(update).build()));
    }

    /** Removes the replica's entry; if it had one, fans out {@code gone} (a GONE update). */
    public Uni<Void> leave(UUID documentId, long replica, PresenceUpdate gone) {
        return redis.send(Request.cmd(Command.DEL).arg(entry(documentId, replica)))
                .call(() -> redis.send(Request.cmd(Command.SREM).arg(members(documentId)).arg(Long.toUnsignedString(replica))))
                .chain(deleted -> deleted.toInteger() == 0 ? Uni.createFrom().voidItem()
                        : bus.publish(documentId, ServerFrame.newBuilder().setPresenceUpdate(gone).build()));
    }

    /** Everyone present on the document now; expired entries are dropped from the set. */
    public Uni<PresenceSnapshot> snapshot(UUID documentId) {
        String set = members(documentId);
        return redis.send(Request.cmd(Command.SMEMBERS).arg(set)).chain(members -> {
            if (members.size() == 0) {
                return Uni.createFrom().item(PresenceSnapshot.getDefaultInstance());
            }
            Request get = Request.cmd(Command.MGET);
            List<String> replicas = new ArrayList<>();
            for (Response member : members) {
                replicas.add(member.toString());
                get.arg(set + ":" + member);
            }
            return redis.send(get).chain(values -> {
                PresenceSnapshot.Builder snapshot = PresenceSnapshot.newBuilder();
                Request expired = Request.cmd(Command.SREM).arg(set);
                boolean anyExpired = false;
                for (int i = 0; i < replicas.size(); i++) {
                    Response value = values.get(i);
                    if (value == null) {
                        expired.arg(replicas.get(i));
                        anyExpired = true;
                    } else {
                        snapshot.addParticipants(Protos.parse(PresenceUpdate.parser(), value.toBytes()));
                    }
                }
                Uni<?> cleaned = anyExpired ? redis.send(expired) : Uni.createFrom().voidItem();
                return cleaned.replaceWith(snapshot.build());
            });
        });
    }
}
