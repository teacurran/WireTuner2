package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** An unguessable link granting a role on one document; may expire or be revoked. */
@Entity
@Table(name = "share_link")
public class ShareLink {

    @Id
    public UUID id;

    @Column(name = "document_id", nullable = false)
    public UUID documentId;

    /** sha256 (hex) of the link token. */
    @Column(name = "token_hash", nullable = false)
    public String tokenHash;

    @Column(nullable = false)
    public String role;

    @Column(name = "created_by")
    public UUID createdBy;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "expires_at")
    public Instant expiresAt;

    @Column(name = "revoked_at")
    public Instant revokedAt;
}
