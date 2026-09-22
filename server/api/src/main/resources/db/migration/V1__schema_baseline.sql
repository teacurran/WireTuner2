-- Baseline: the schema exists and can say which spec revision it implements. The real tables
-- (docs/spec/server.adoc, Persistence) arrive with SRV-003.
CREATE TABLE schema_info (
    key        text        PRIMARY KEY,
    value      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_info (key, value) VALUES ('wiretuner.schema', 'baseline');
