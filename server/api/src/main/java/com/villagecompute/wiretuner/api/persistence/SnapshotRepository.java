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

    /** The newest snapshot at or before {@code serverSeq}, or null. */
    public Uni<Snapshot> findAtOrBefore(UUID documentId, long serverSeq) {
        return find("id.documentId = ?1 and id.serverSeq <= ?2", Sort.descending("id.serverSeq"), documentId, serverSeq)
                .firstResult();
    }
}
