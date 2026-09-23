package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Snapshot records; the newest is the one sync bootstraps from. */
@ApplicationScoped
public class SnapshotRepository implements PanacheRepositoryBase<Snapshot, SnapshotId> {

    public Uni<Snapshot> findNewest(UUID documentId) {
        return find("id.documentId", Sort.descending("id.serverSeq"), documentId).firstResult();
    }
}
