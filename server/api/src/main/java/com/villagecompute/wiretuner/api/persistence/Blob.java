package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A content-addressed binary: keyed by its sha256 (hex). */
@Entity
@Table(name = "blob")
public class Blob {

    @Id
    public String sha256;

    @Column(name = "size_bytes", nullable = false)
    public long sizeBytes;

    @Column(name = "media_type", nullable = false)
    public String mediaType;

    @Column(name = "storage_key", nullable = false)
    public String storageKey;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt = Instant.now();
}
