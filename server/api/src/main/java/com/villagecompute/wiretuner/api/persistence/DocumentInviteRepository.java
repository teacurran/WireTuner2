package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Pending document invitations by email. */
@ApplicationScoped
public class DocumentInviteRepository implements PanacheRepositoryBase<DocumentInvite, UUID> {

    public Uni<List<DocumentInvite>> listForDocument(UUID documentId) {
        return list("documentId", Sort.by("createdAt"), documentId);
    }

    public Uni<DocumentInvite> findFor(UUID documentId, String email) {
        return find("documentId = ?1 and email = ?2", documentId, email).firstResult();
    }
}
