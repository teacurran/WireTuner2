package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code document_member}. */
@Embeddable
public record DocumentMemberId(
        @Column(name = "document_id", nullable = false) UUID documentId,
        @Column(name = "account_id", nullable = false) UUID accountId) {
}
