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

    @Column(name = "verification_token", nullable = false)
    public String verificationToken;

    @Column(name = "verified_at")
    public Instant verifiedAt;
}
