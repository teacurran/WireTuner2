package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

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
}
