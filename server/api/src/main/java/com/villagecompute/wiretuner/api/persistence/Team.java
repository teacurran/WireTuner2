package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A named group of accounts with a shared document space (docs/spec/security.adoc, Teams). */
@Entity
@Table(name = "team")
public class Team {

    @Id
    public UUID id;

    @Column(nullable = false, columnDefinition = "text")
    public String name;

    @Column(nullable = false, columnDefinition = "text")
    public String slug;

    @Column(name = "owner_account_id", nullable = false)
    public UUID ownerAccountId;

    /** The document role a member holds on team documents without an explicit share. */
    @Column(name = "default_document_role", nullable = false, columnDefinition = "text")
    public String defaultDocumentRole = "editor";

    /** The days the team's documents keep every change, at least 30; null = the configured default (history.adoc). */
    @Column(name = "history_retention_days")
    public Integer historyRetentionDays;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "deleted_at")
    public Instant deletedAt;
}
