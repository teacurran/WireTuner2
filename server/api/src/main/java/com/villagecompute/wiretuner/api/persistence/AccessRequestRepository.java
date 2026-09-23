package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Access requests: the pending one per person and document, and a document's pending list. */
@ApplicationScoped
public class AccessRequestRepository implements PanacheRepositoryBase<AccessRequest, UUID> {

    public Uni<AccessRequest> findPending(UUID documentId, UUID accountId) {
        return find("documentId = ?1 and accountId = ?2 and resolvedAt is null", documentId, accountId).firstResult();
    }

    /** Pending requests, oldest first, from {@code offset}, at most {@code limit}. */
    public Uni<List<AccessRequest>> listPending(UUID documentId, int offset, int limit) {
        return find("documentId = ?1 and resolvedAt is null order by createdAt, id", documentId)
                .range(offset, offset + limit - 1).list();
    }
}
