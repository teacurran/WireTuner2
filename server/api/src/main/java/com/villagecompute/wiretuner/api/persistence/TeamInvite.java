package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** An invitation to a team; the token itself is only ever in the mail, the row holds its sha256. */
@Entity
@Table(name = "team_invite")
public class TeamInvite {

    @Id
    public UUID id;

    @Column(name = "team_id", nullable = false)
    public UUID teamId;

    /** The invited address, lower-case. */
    @Column(nullable = false)
    public String email;

    /** {@code admin}, {@code member} or {@code guest}. */
    @Column(nullable = false)
    public String role;

    @Column(name = "token_hash", nullable = false)
    public String tokenHash;

    @Column(name = "invited_by_account_id")
    public UUID invitedByAccountId;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();

    @Column(name = "expires_at", nullable = false)
    public Instant expiresAt;

    @Column(name = "accepted_at")
    public Instant acceptedAt;
}
