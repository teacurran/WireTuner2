-- COLLAB-020's remaining items (docs/_includes/collaboration/history.adoc, Server): a team's longer
-- history window for the Retention job, and the queue of the one-shot history index backfill.

-- The days a team's documents keep every change; null = the configured default (30 days). A team may
-- lengthen the window, never shorten it.
ALTER TABLE team ADD COLUMN history_retention_days integer CHECK (history_retention_days >= 30);

-- Documents with changes logged before V11 wrote change_node and node_name at ingest, and the head
-- their index is backfilled through. IndexBackfillJob drains it; writing an index row twice is a
-- no-op, so a change indexed at ingest since V11 costs nothing.
CREATE TABLE history_backfill (
    document_id uuid   PRIMARY KEY REFERENCES document (id) ON DELETE CASCADE,
    through_seq bigint NOT NULL CHECK (through_seq > 0)
);
INSERT INTO history_backfill (document_id, through_seq)
SELECT id, head_seq FROM document WHERE head_seq > 0;
