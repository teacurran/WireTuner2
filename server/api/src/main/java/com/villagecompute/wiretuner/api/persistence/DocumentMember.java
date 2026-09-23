package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** An explicit per-document role (docs/spec/security.adoc, Document roles). */
@Entity
@Table(name = "document_member")
public class DocumentMember {

    @EmbeddedId
    public DocumentMemberId id;

    @Column(nullable = false)
    public String role;

    @Column(name = "added_by")
    public UUID addedBy;

    @Column(name = "added_at", nullable = false)
    public Instant addedAt = Instant.now();
}
