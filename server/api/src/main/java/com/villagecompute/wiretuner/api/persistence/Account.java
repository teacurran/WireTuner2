package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A personal account: one row per Keycloak subject (docs/spec/security.adoc, Accounts). */
@Entity
@Table(name = "account")
public class Account {

    @Id
    public UUID id;

    @Column(nullable = false)
    public String subject;

    @Column(nullable = false)
    public String email = "";

    @Column(name = "display_name", nullable = false)
    public String displayName = "";

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();
}
