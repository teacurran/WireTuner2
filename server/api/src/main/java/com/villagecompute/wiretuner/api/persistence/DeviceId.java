package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code device}: the account and the client's per-install id ({@code wt-device}). */
@Embeddable
public record DeviceId(
        @Column(name = "account_id", nullable = false) UUID accountId,
        @Column(name = "id", nullable = false) UUID deviceId) {
}
