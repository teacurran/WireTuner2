package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code replica}: the document and the 64-bit replica id from the client's OpIds. */
@Embeddable
public record ReplicaId(
        @Column(name = "document_id", nullable = false) UUID documentId,
        @Column(name = "replica_id", nullable = false) long replicaId) {
}
