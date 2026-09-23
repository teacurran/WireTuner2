-- SRV-003: content-addressed blobs and their per-document references (docs/spec/server.adoc,
-- Persistence). A blob is only served to principals with a role on a document that references it.

CREATE TABLE blob (
    -- sha256 of the content, lower-case hex.
    sha256      text        PRIMARY KEY CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    size_bytes  bigint      NOT NULL CHECK (size_bytes >= 0),
    media_type  text        NOT NULL,
    storage_key text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE document_blob (
    document_id   uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    sha256        text        NOT NULL REFERENCES blob (sha256),
    referenced_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, sha256)
);
CREATE INDEX document_blob_sha256_idx ON document_blob (sha256);

-- The thumbnail is a blob too.
ALTER TABLE document
    ADD CONSTRAINT document_thumbnail_fk FOREIGN KEY (thumbnail_blob) REFERENCES blob (sha256);

UPDATE schema_info SET value = 'SRV-003', updated_at = now() WHERE key = 'wiretuner.schema';
