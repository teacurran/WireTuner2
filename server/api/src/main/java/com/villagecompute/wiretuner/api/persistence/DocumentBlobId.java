package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code document_blob}. */
@Embeddable
public record DocumentBlobId(
        @Column(name = "document_id", nullable = false) UUID documentId,
        @Column(name = "sha256", nullable = false) String sha256) {
}
