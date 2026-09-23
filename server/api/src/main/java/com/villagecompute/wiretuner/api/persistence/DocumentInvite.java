package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * A pending invitation to a document by an email no account has yet (SRV-010): it becomes a
 * {@code document_member} row when an account with that address, verified, signs in.
 */
@Entity
@Table(name = "document_invite")
public class DocumentInvite {

    @Id
    public UUID id;

    @Column(name = "document_id", nullable = false)
    public UUID documentId;

    /** Lower-case address. */
    @Column(nullable = false, columnDefinition = "text")
    public String email;

    @Column(nullable = false, columnDefinition = "text")
    public String role;

    @Column(name = "invited_by")
    public UUID invitedBy;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();
}
