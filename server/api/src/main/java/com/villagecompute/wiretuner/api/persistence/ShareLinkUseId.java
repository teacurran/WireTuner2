package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code share_link_use}. */
@Embeddable
public record ShareLinkUseId(
        @Column(name = "share_link_id", nullable = false) UUID shareLinkId,
        @Column(name = "account_id", nullable = false) UUID accountId) {
}
