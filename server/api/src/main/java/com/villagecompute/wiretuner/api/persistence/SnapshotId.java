package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code snapshot}. */
@Embeddable
public record SnapshotId(
        @Column(name = "document_id", nullable = false) UUID documentId,
        @Column(name = "server_seq", nullable = false) long serverSeq) {
}
