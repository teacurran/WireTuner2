package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Replicas per document; {@link #listLive} is what the stability job reads. */
@ApplicationScoped
public class ReplicaRepository implements PanacheRepositoryBase<Replica, ReplicaId> {

    public Uni<List<Replica>> listLive(UUID documentId) {
        return list("id.documentId = ?1 and retiredAt is null", documentId);
    }
}
