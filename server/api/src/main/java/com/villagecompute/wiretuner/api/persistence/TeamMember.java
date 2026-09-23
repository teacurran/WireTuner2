package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** A membership: {@code owner}, {@code admin}, {@code member} or {@code guest}. */
@Entity
@Table(name = "team_member")
public class TeamMember {

    @EmbeddedId
    public TeamMemberId id;

    @Column(nullable = false, columnDefinition = "text")
    public String role;

    @Column(name = "joined_at", nullable = false)
    public Instant joinedAt = Instant.now();
}
