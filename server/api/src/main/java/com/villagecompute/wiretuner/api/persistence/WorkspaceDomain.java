package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** An email domain a workspace claims; it counts once {@code verifiedAt} is set. */
@Entity
@Table(name = "workspace_domain")
public class WorkspaceDomain {

    @EmbeddedId
    public WorkspaceDomainId id;

    @Column(name = "verification_token", nullable = false, columnDefinition = "text")
    public String verificationToken;

    @Column(name = "verified_at")
    public Instant verifiedAt;

    /** When the hourly job last looked the record up. */
    @Column(name = "checked_at")
    public Instant checkedAt;

    /** Lookups in a row that did not find the record. */
    @Column(name = "failed_checks", nullable = false)
    public int failedChecks;
}
