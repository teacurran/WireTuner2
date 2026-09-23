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

    /** Gives {@code toDocument} the role rows of {@code fromDocument} (a new branch, SRV-011). */
    public Uni<Integer> copyMembers(UUID fromDocument, UUID toDocument) {
        return getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO document_member (document_id, account_id, role, added_by)
                        SELECT ?1, account_id, role, added_by FROM document_member WHERE document_id = ?2 AND role <> 'none'
                        """)
                .setParameter(1, toDocument)
                .setParameter(2, fromDocument)
                .executeUpdate());
    }
}
