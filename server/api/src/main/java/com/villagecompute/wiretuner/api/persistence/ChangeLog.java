package com.villagecompute.wiretuner.api.persistence;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

/** One accepted change; the table is hash-partitioned by document (docs/spec/server.adoc). */
@Entity
@Table(name = "change_log")
public class ChangeLog {

    @EmbeddedId
    public ChangeLogId id;

    @Column(name = "replica_id", nullable = false)
    public long replicaId;

    @Column(nullable = false)
    public long seq;

    /** The encoded {@code wiretuner.doc.v1.Change}. */
    @Column(nullable = false)
    public byte[] bytes;

    @Column(name = "wall_time", nullable = false)
    public Instant wallTime = Instant.now();

    @Column(name = "byte_size", nullable = false)
    public int byteSize;
}
