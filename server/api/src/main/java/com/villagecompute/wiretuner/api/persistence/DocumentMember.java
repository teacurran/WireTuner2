package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/**
 * An explicit per-document role (docs/spec/security.adoc, Document roles), or with role {@code none}
 * a row that only holds the account's presence color on the document (presence.adoc, Data model).
 */
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

    /** Presence color, an index into the 12-color palette; null until the account first subscribes. */
    @Column(name = "color_index")
    public Short colorIndex;
}
