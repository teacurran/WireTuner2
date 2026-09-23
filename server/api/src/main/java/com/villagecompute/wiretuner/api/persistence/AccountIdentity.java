package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** One sign-in method linked to an account (docs/spec/security.adoc, Account linking). */
@Entity
@Table(name = "account_identity")
public class AccountIdentity {

    @EmbeddedId
    public AccountIdentityId id;

    @Column(name = "account_id", nullable = false)
    public UUID accountId;

    @Column(nullable = false, columnDefinition = "text")
    public String email = "";

    @Column(name = "email_verified", nullable = false)
    public boolean emailVerified;

    @Column(name = "is_relay", nullable = false)
    public boolean relay;

    @Column(name = "linked_at", nullable = false)
    public Instant linkedAt = Instant.now();
}
