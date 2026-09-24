package com.villagecompute.wiretuner.api.sync;

import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

/**
 * Replica binding (docs/spec/security.adoc): a replica id is bound to (account, device) on first
 * use, and a call carrying it from any other principal is {@code REPLICA_CONFLICT}; a retired
 * replica is {@code REPLICA_EXPIRED}. A call without {@code wt-device} binds to the all-zero device; one
 * whose {@code wt-device} is not a UUID never gets here ({@code PrincipalInterceptor}).
 *
 * @param accountId the bound account
 * @param deviceId the bound device
 * @param lastSeq the replica's last accepted seq
 * @param retired whether the stability job retired it
 */
public record ReplicaBinding(UUID accountId, UUID deviceId, long lastSeq, boolean retired) {

    /** The device a replica is bound to when the call carried no {@code wt-device}. */
    public static final UUID NO_DEVICE = new UUID(0, 0);

    /** The device the caller binds replicas to. */
    public static UUID device(Principal principal) {
        UUID device = principal.deviceId();
        return device == null ? NO_DEVICE : device;
    }

    /**
     * Throws unless {@code binding} (null = unbound) may be used by the caller.
     */
    public static void check(ReplicaBinding binding, Principal principal, long replica) {
        if (binding == null) {
            return;
        }
        if (!binding.accountId.equals(principal.accountId()) || !binding.deviceId.equals(device(principal))) {
            throw StatusExceptions.replicaBound(replica);
        }
        if (binding.retired) {
            throw StatusExceptions.replicaExpired(replica);
        }
    }
}
