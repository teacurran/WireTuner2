package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code workspace_domain}. */
@Embeddable
public record WorkspaceDomainId(
        @Column(name = "team_id", nullable = false) UUID teamId,
        @Column(name = "domain", nullable = false, columnDefinition = "text") String domain) {
}
