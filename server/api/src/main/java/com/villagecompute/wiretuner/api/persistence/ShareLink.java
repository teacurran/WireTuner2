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
    @Column(name = "token_hash", nullable = false, columnDefinition = "text")
    public String tokenHash;

    @Column(nullable = false, columnDefinition = "text")
    public String role;

    @Column(name = "created_by")
    public UUID createdBy;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "expires_at")
    public Instant expiresAt;

    @Column(name = "revoked_at")
    public Instant revokedAt;

    /** argon2id PHC string of the link password; null when the link has none. */
    @Column(name = "password_hash", columnDefinition = "text")
    public String passwordHash;

    /** Whether the access the link granted ends when it expires. */
    @Column(name = "revoke_on_expiry", nullable = false)
    public boolean revokeOnExpiry;

    /** When the Invitations job told the people who opened it that its expiry ended their access (COLLAB-011). */
    @Column(name = "expiry_announced_at")
    public Instant expiryAnnouncedAt;

    /** Whether only members of the document's team may open it. */
    @Column(name = "team_members_only", nullable = false)
    public boolean teamMembersOnly;
}
