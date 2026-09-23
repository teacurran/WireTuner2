package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** A snapshot record; the object itself is in R2/MinIO under {@code objectKey}. */
@Entity
@Table(name = "snapshot")
public class Snapshot {

    @EmbeddedId
    public SnapshotId id;

    @Column(name = "object_key", nullable = false)
    public String objectKey;

    /** The merge engine's state hash, hex. */
    @Column(name = "state_hash", nullable = false)
    public String stateHash;

    @Column(name = "size_bytes", nullable = false)
    public long sizeBytes;

    /** The size of the decompressed {@code DocumentSnapshot}. */
    @Column(name = "uncompressed_size", nullable = false)
    public long uncompressedSize;

    @Column(name = "node_count", nullable = false)
    public int nodeCount;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();
}
