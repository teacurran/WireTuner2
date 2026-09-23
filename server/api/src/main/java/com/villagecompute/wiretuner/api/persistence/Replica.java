package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;
import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** A replica bound to (account, device) on first use (docs/spec/security.adoc, Replica binding). */
@Entity
@Table(name = "replica")
public class Replica {

    @EmbeddedId
    public ReplicaId id;

    @Column(name = "account_id", nullable = false)
    public UUID accountId;

    @Column(name = "device_id", nullable = false)
    public UUID deviceId;

    @Column(name = "last_seq", nullable = false)
    public long lastSeq;

    @Column(name = "last_ack_seq", nullable = false)
    public long lastAckSeq;

    @Column(name = "last_seen_at", nullable = false)
    public Instant lastSeenAt = Instant.now();

    @Column(name = "retired_at")
    public Instant retiredAt;
}
