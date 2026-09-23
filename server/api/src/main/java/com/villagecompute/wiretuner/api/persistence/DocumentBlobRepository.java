package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.quarkus.hibernate.reactive.panache.PanacheRepositoryBase;
import io.quarkus.panache.common.Sort;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/** Blob references per document. */
@ApplicationScoped
public class DocumentBlobRepository implements PanacheRepositoryBase<DocumentBlob, DocumentBlobId> {

    public Uni<List<DocumentBlob>> listForDocument(UUID documentId) {
        return list("id.documentId", Sort.by("referencedAt"), documentId);
    }

    /** Gives {@code toDocument} every blob reference {@code fromDocument} has (fork and duplicate). */
    public Uni<Integer> copyReferences(UUID fromDocument, UUID toDocument) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO document_blob (document_id, sha256)
                        SELECT ?1, sha256 FROM document_blob WHERE document_id = ?2
                        ON CONFLICT DO NOTHING
                        """)
                .setParameter(1, toDocument)
                .setParameter(2, fromDocument)
                .executeUpdate());
    }

    /** Records that the document references the blob; a second reference is a no-op. */
    public Uni<Integer> reference(UUID documentId, String sha256) {
        return Panache.getSession().chain(session -> session.createNativeQuery("""
                        INSERT INTO document_blob (document_id, sha256) VALUES (?1, ?2) ON CONFLICT DO NOTHING
                        """)
                .setParameter(1, documentId)
                .setParameter(2, sha256)
                .executeUpdate());
    }
}
