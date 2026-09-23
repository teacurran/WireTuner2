package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * A document's identity and sequencing state. The space is {@code ownerAccountId} XOR
 * {@code teamId}; the database enforces it ({@code document_space_xor}).
 */
@Entity
@Table(name = "document")
public class Document {

    @Id
    public UUID id;

    @Column(name = "owner_account_id")
    public UUID ownerAccountId;

    @Column(name = "team_id")
    public UUID teamId;

    @Column(nullable = false)
    public String name = "";

    @Column(nullable = false)
    public String folder = "";

    @Column(nullable = false)
    public String kind = "document";

    @Column(name = "feature_level", nullable = false)
    public int featureLevel;

    @Column(name = "head_seq", nullable = false)
    public long headSeq;

    @Column(name = "stable_seq", nullable = false)
    public long stableSeq;

    @Column(name = "trashed_at")
    public Instant trashedAt;

    /** sha256 (hex) of the client-rendered thumbnail blob; null until the client sends one. */
    @Column(name = "thumbnail_blob")
    public String thumbnailBlob;

    @Column(name = "thumbnail_at")
    public Instant thumbnailAt;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "updated_at", nullable = false)
    public Instant updatedAt = Instant.now();
}
