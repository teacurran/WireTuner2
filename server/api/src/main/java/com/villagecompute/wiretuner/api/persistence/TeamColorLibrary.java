package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * A document whose named colors are published to a team (COLOR-020; exporting-colors.adoc, Team
 * color libraries). In automatic mode the published version is the document's head; in manual mode
 * {@link #publishedSeq} holds it and {@link #colors} the {@code wiretuner.lib.v1.ColorLibrary}
 * extracted from it when it was published.
 */
@Entity
@Table(name = "color_library")
public class TeamColorLibrary {

    @Id
    @Column(name = "document_id")
    public UUID documentId;

    @Column(name = "team_id", nullable = false)
    public UUID teamId;

    /** The name the Team Libraries submenu shows. */
    @Column(nullable = false, columnDefinition = "text")
    public String name;

    /** Manual mode: the version moves only when the owner publishes one. */
    @Column(nullable = false)
    public boolean manual;

    /** Manual mode: the published server_seq. */
    @Column(name = "published_seq", nullable = false)
    public long publishedSeq;

    /** Manual mode: the encoded {@code ColorLibrary} at {@link #publishedSeq}. */
    public byte[] colors;

    @Column(name = "published_by")
    public UUID publishedBy;

    /** When the library, or in manual mode its version, was last published. */
    @Column(name = "published_at", nullable = false)
    public Instant publishedAt = Instant.now();
}
