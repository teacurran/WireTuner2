package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Explicit document roles. */
@ApplicationScoped
public class DocumentMemberRepository implements PanacheRepositoryBase<DocumentMember, DocumentMemberId> {

    public Uni<List<DocumentMember>> listForDocument(UUID documentId) {
        return list("id.documentId", Sort.by("addedAt"), documentId);
    }
}
