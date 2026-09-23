package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code team_member}. */
@Embeddable
public record TeamMemberId(
        @Column(name = "team_id", nullable = false) UUID teamId,
        @Column(name = "account_id", nullable = false) UUID accountId) {
}
