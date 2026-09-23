package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A request for access to a document (sharing.adoc, Requesting access); pending until resolved. */
@Entity
@Table(name = "access_request")
public class AccessRequest {

    @Id
    public UUID id;

    @Column(name = "document_id", nullable = false)
    public UUID documentId;

    @Column(name = "account_id", nullable = false)
    public UUID accountId;

    @Column(nullable = false, columnDefinition = "text")
    public String message = "";

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "resolved_at")
    public Instant resolvedAt;

    /** The role granted; null when declined or pending. */
    @Column(name = "granted_role", columnDefinition = "text")
    public String grantedRole;
}
