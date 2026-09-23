package com.villagecompute.wiretuner.api.sync;

import java.time.Duration;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.auth.CallMetadata;
import com.villagecompute.wiretuner.api.sync.ChangeIngest.Pusher;

import io.quarkus.scheduler.Scheduled;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * A short-lived per-node memo of push authorisations (docs/spec/server.adoc, Ingest path): a client
 * pipelines up to 32 pushes and sends them for as long as the user edits, and resolving the caller
 * and their role for every one of them costs several database round trips. The decision is kept
 * for {@code wt.sync.grant-ttl} (2 s) under the exact bearer token, device and document it was made
 * for, so a token, device or role change is seen by pushes within that time; a new token is a new
 * key, and anything else resolves afresh. A role change made on this node forgets the document's
 * decisions at once ({@link #forget}).
 */
@ApplicationScoped
public class PushGrants {

    record Key(String authorization, String device, UUID document, String purpose) {
    }

    record Grant(Object value, long expiresAt) {
    }

    @ConfigProperty(name = "wt.sync.grant-ttl", defaultValue = "2S")
    Duration ttl;

    @Inject
    CallMetadata callMetadata;

    private final Map<Key, Grant> grants = new ConcurrentHashMap<>();

    /** The remembered pusher for this call's token, device and document, or {@code resolve}'s, remembered. */
    public Uni<Pusher> pusher(UUID documentId, Supplier<Uni<Pusher>> resolve) {
        return memo(documentId, "push", resolve);
    }

    /**
     * The value remembered for this call's token, device and document under {@code purpose}, or
     * {@code resolve}'s, remembered for the TTL: a pusher, or who a caller is in presence.
     */
    @SuppressWarnings("unchecked")
    public <T> Uni<T> memo(UUID documentId, String purpose, Supplier<Uni<T>> resolve) {
        Key key = new Key(callMetadata.authorization(), callMetadata.deviceId(), documentId, purpose);
        long now = System.nanoTime();
        Grant grant = grants.get(key);
        if (grant != null && grant.expiresAt() - now > 0) {
            return Uni.createFrom().item((T) grant.value());
        }
        return resolve.get().invoke(value -> grants.put(key, new Grant(value, now + ttl.toNanos())));
    }

    /**
     * Forgets every decision about the document on this node: ShareService calls it when a role
     * changes, so the next push here is checked afresh. Other nodes see the change within the TTL.
     */
    public void forget(UUID documentId) {
        grants.keySet().removeIf(key -> key.document().equals(documentId));
    }

    /** Drops expired grants. */
    @Scheduled(every = "${wt.sync.grant-ttl:2S}", delayed = "${wt.sync.grant-ttl:2S}")
    void purge() {
        long now = System.nanoTime();
        grants.values().removeIf(grant -> grant.expiresAt() - now <= 0);
    }

    int size() {
        return grants.size();
    }
}
