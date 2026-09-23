-- SRV-003: the sync tables (docs/spec/server.adoc, Persistence and Ingest path).

-- A replica id (the 64-bit value in every OpId) is bound to (account, device) on first use;
-- changes carrying it from any other principal are rejected (docs/spec/security.adoc).
CREATE TABLE replica (
    document_id  uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    replica_id   bigint      NOT NULL,
    account_id   uuid        NOT NULL REFERENCES account (id),
    device_id    uuid        NOT NULL,
    last_seq     bigint      NOT NULL DEFAULT 0,
    last_ack_seq bigint      NOT NULL DEFAULT 0,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    retired_at   timestamptz,
    PRIMARY KEY (document_id, replica_id)
);
CREATE INDEX replica_account_idx ON replica (account_id);

-- The hot table: append-only, partitioned by hash of the document so one document's rows share
-- a partition and the compactor's deletes stay local.
CREATE TABLE change_log (
    document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    server_seq  bigint      NOT NULL,
    replica_id  bigint      NOT NULL,
    seq         bigint      NOT NULL,
    -- The encoded wiretuner.doc.v1.Change.
    bytes       bytea       NOT NULL,
    wall_time   timestamptz NOT NULL DEFAULT now(),
    byte_size   integer     NOT NULL,
    PRIMARY KEY (document_id, server_seq)
) PARTITION BY HASH (document_id);

CREATE TABLE change_log_p00 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE change_log_p01 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 1);
CREATE TABLE change_log_p02 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 2);
CREATE TABLE change_log_p03 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 3);
CREATE TABLE change_log_p04 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 4);
CREATE TABLE change_log_p05 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 5);
CREATE TABLE change_log_p06 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 6);
CREATE TABLE change_log_p07 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 7);
CREATE TABLE change_log_p08 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 8);
CREATE TABLE change_log_p09 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 9);
CREATE TABLE change_log_p10 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 10);
CREATE TABLE change_log_p11 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 11);
CREATE TABLE change_log_p12 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 12);
CREATE TABLE change_log_p13 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 13);
CREATE TABLE change_log_p14 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 14);
CREATE TABLE change_log_p15 PARTITION OF change_log FOR VALUES WITH (MODULUS 16, REMAINDER 15);

-- Idempotency by (replica, seq): the same key never lands twice (REPLICA_CONFLICT is the
-- different-content case the ingest checks before this index would fire).
CREATE UNIQUE INDEX change_log_replica_seq ON change_log (document_id, replica_id, seq);

-- One snapshot per (document, server_seq); the object itself lives in R2/MinIO.
CREATE TABLE snapshot (
    document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    server_seq  bigint      NOT NULL,
    object_key  text        NOT NULL,
    -- The merge engine's state hash of the snapshot, lower-case hex.
    state_hash  text        NOT NULL CHECK (state_hash ~ '^[0-9a-f]{64}$'),
    size_bytes  bigint      NOT NULL CHECK (size_bytes >= 0),
    node_count  integer     NOT NULL CHECK (node_count >= 0),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, server_seq)
);

-- change_log rows the compactor moved to object storage (zstd, 8 MiB each).
CREATE TABLE cold_segment (
    document_id     uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    from_seq        bigint      NOT NULL,
    to_seq          bigint      NOT NULL,
    object_key      text        NOT NULL,
    compressed_size bigint      NOT NULL CHECK (compressed_size >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, from_seq),
    CONSTRAINT cold_segment_range CHECK (to_seq >= from_seq)
);
