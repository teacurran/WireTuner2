package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Devices per account, most recently seen first. */
@ApplicationScoped
public class DeviceRepository implements PanacheRepositoryBase<Device, DeviceId> {

    public Uni<List<Device>> listForAccount(UUID accountId) {
        return list("id.accountId", Sort.descending("lastSeenAt"), accountId);
    }

    /**
     * Records a device seen for the first time. Pipelined calls from a new device race to do this,
     * so a row another call inserted first wins and this is a no-op.
     */
    public Uni<Void> insertIfAbsent(Device device) {
        // Flush first: the account row this device references may still be pending in the session.
        return Panache.getSession().chain(session -> session.flush().chain(() -> session.createNativeQuery("""
                        INSERT INTO device (account_id, id, name, platform, auth_method, last_seen_at)
                        VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT (account_id, id) DO NOTHING
                        """)
                .setParameter(1, device.id.accountId())
                .setParameter(2, device.id.deviceId())
                .setParameter(3, device.name)
                .setParameter(4, device.platform)
                .setParameter(5, device.authMethod)
                .setParameter(6, device.lastSeenAt)
                .executeUpdate()))
                .replaceWithVoid();
    }
}
