package com.villagecompute.wiretuner.api.persistence;

import java.util.List;
import java.util.UUID;

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
}
