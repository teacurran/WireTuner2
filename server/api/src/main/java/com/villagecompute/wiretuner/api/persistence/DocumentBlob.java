package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** A document's reference to a blob; blobs are served only through such a reference. */
@Entity
@Table(name = "document_blob")
public class DocumentBlob {

    @EmbeddedId
    public DocumentBlobId id;

    @Column(name = "referenced_at", nullable = false)
    public Instant referencedAt = Instant.now();
}
