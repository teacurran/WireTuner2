package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** A Mac the account has signed in on; records the sign-in method seen first (SRV-002). */
@Entity
@Table(name = "device")
public class Device {

    @EmbeddedId
    public DeviceId id;

    @Column(nullable = false, columnDefinition = "text")
    public String name = "";

    @Column(nullable = false, columnDefinition = "text")
    public String platform = "";

    @Column(name = "auth_method", nullable = false, columnDefinition = "text")
    public String authMethod = "password";

    @Column(name = "last_seen_at", nullable = false)
    public Instant lastSeenAt = Instant.now();

    @Column(name = "revoked_at")
    public Instant revokedAt;
}
