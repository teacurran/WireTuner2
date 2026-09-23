-- SRV-007, SRV-011, SRV-013, D-067: snapshots and cold segments as the snapshotter and compactor
-- write them, each change's horizon and the published collection point, branches and named
-- versions as BranchService and VersionService keep them (docs/spec/server.adoc, Persistence and
-- Jobs; docs/spec/crdt-model.adoc, "Stable points, horizons and collection points").

-- A snapshot object is the zstd-compressed DocumentSnapshot; FetchSnapshot's header needs the
-- decompressed size. collect_seq / collect_time_ms: the collection point the state was collected at.
ALTER TABLE snapshot
    ADD COLUMN uncompressed_size bigint NOT NULL DEFAULT 0 CHECK (uncompressed_size >= 0),
    ADD COLUMN collect_seq       bigint NOT NULL DEFAULT 0,
    ADD COLUMN collect_time_ms   bigint NOT NULL DEFAULT 0;

-- A segment's smallest change horizon, so the collection point is lowered past cold changes too.
ALTER TABLE cold_segment
    ADD COLUMN change_count    integer NOT NULL DEFAULT 0,
    ADD COLUMN min_horizon_seq bigint  NOT NULL DEFAULT 0,
    ADD COLUMN min_horizon_ms  bigint  NOT NULL DEFAULT 0;

-- D-067: the publication (stable point and server clock) the author had confirmed receiving when
-- the change was accepted, and, for a change a branch merge replayed, the branch it came from.
ALTER TABLE change_log
    ADD COLUMN horizon_seq           bigint NOT NULL DEFAULT 0,
    ADD COLUMN horizon_ms            bigint NOT NULL DEFAULT 0,
    ADD COLUMN merged_from_branch_id uuid;

-- D-067: the last publication an Ack answered (published_*) and the one before it, which the
-- replica confirmed receiving by acking again (horizon_*).
ALTER TABLE replica
    ADD COLUMN published_seq bigint NOT NULL DEFAULT 0,
    ADD COLUMN published_ms  bigint NOT NULL DEFAULT 0,
    ADD COLUMN horizon_seq   bigint NOT NULL DEFAULT 0,
    ADD COLUMN horizon_ms    bigint NOT NULL DEFAULT 0;
CREATE INDEX replica_last_seen_idx ON replica (last_seen_at) WHERE retired_at IS NULL;

-- The published collection point (C, T), and the snapshotter's "last subscription closed with
-- changes since the last snapshot" trigger.
ALTER TABLE document
    ADD COLUMN collect_seq      bigint      NOT NULL DEFAULT 0,
    ADD COLUMN collect_time_ms  bigint      NOT NULL DEFAULT 0,
    ADD COLUMN snapshot_due_at  timestamptz;
CREATE INDEX document_trashed_idx ON document (trashed_at) WHERE trashed_at IS NOT NULL;
CREATE INDEX document_snapshot_due_idx ON document (snapshot_due_at) WHERE snapshot_due_at IS NOT NULL;

-- SRV-011: a branch's name, state and merge bookkeeping (branch.proto).
ALTER TABLE branch
    ADD COLUMN name                  text   NOT NULL DEFAULT '',
    ADD COLUMN state                 text   NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'archived', 'merged')),
    ADD COLUMN merged_branch_seq     bigint NOT NULL DEFAULT 0,
    ADD COLUMN merged_parent_seq     bigint NOT NULL DEFAULT 0,
    ADD COLUMN created_by_account_id uuid   REFERENCES account (id) ON DELETE SET NULL;

-- SRV-011: named versions are client-identified bookmarks; two names at one seq are two versions.
DROP TABLE version;
CREATE TABLE version (
    id                uuid        PRIMARY KEY,
    document_id       uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    server_seq        bigint      NOT NULL CHECK (server_seq >= 0),
    name              text        NOT NULL,
    note              text        NOT NULL DEFAULT '',
    author_account_id uuid        REFERENCES account (id) ON DELETE SET NULL,
    pinned            boolean     NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX version_document_idx ON version (document_id, created_at DESC, id DESC);

UPDATE schema_info SET value = 'SRV-013', updated_at = now() WHERE key = 'wiretuner.schema';
