package com.villagecompute.wiretuner.api.persistence;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;

/** Primary key of {@code account_identity}: the provider and the subject it asserts. */
@Embeddable
public record AccountIdentityId(
        @Column(name = "provider", nullable = false, columnDefinition = "text") String provider,
        @Column(name = "provider_subject", nullable = false, columnDefinition = "text") String providerSubject) {
}
