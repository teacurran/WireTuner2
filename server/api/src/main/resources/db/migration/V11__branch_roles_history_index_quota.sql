-- COLLAB-019, COLLAB-020, IO-008: roles through a branch's parent, the history index written at
-- ingest, and blob storage quotas (docs/spec/server.adoc, Persistence).

-- COLLAB-019: a branch has no member rows of its own; roles and presence colors resolve through
-- its parent. Rows SRV-011 copied at creation are dropped.
DELETE FROM document_member m USING branch b WHERE m.document_id = b.document_id;

-- COLLAB-020: the touched-node index. One row per (change, node it names), written with the
-- change (ingest, branch merge, copies); it outlives the compactor, so node history reaches cold
-- segments. Not partitioned: routing an insert through 16 partitions costs every ingest statement
-- even when the change names no node.
CREATE TABLE change_node (
    document_id  uuid   NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    node_replica bigint NOT NULL,
    node_counter bigint NOT NULL,
    server_seq   bigint NOT NULL,
    PRIMARY KEY (document_id, node_replica, node_counter, server_seq)
);

-- COLLAB-020: every name a node was given, with the change that gave it: a CreateNode (its kind,
-- and its name, empty when unnamed) or a SetFields writing CommonProps.name (empty = cleared). A
-- node's name at a server_seq is its row with the greatest seq at or before it.
CREATE TABLE node_name (
    document_id  uuid    NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    node_replica bigint  NOT NULL,
    node_counter bigint  NOT NULL,
    server_seq   bigint  NOT NULL,
    kind         integer NOT NULL,
    name         text    NOT NULL,
    PRIMARY KEY (document_id, node_replica, node_counter, server_seq)
);

-- IO-008: a space's blob storage quota in bytes; null = the configured default for the space kind.
ALTER TABLE account ADD COLUMN storage_limit_bytes bigint CHECK (storage_limit_bytes >= 0);
ALTER TABLE team ADD COLUMN storage_limit_bytes bigint CHECK (storage_limit_bytes >= 0);

UPDATE schema_info SET value = 'COLLAB-020', updated_at = now() WHERE key = 'wiretuner.schema';
