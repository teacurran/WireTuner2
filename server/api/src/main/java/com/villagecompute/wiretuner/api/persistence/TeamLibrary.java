package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A team document marked as a team library (COLLAB-012; sharing.adoc, Team libraries). */
@Entity
@Table(name = "library")
public class TeamLibrary {

    @Id
    @Column(name = "document_id")
    public UUID documentId;

    @Column(name = "team_id", nullable = false)
    public UUID teamId;

    /** The name the panels show. */
    @Column(nullable = false, columnDefinition = "text")
    public String name;

    @Column(name = "published_by")
    public UUID publishedBy;

    @Column(name = "published_at", nullable = false)
    public Instant publishedAt = Instant.now();
}
