-- DATA-005, DATA-007, DATA-008: the data service's server state (docs/_includes/automation/
-- data-merge.adoc, Server state and the data service): envelope-encrypted credentials, permitted
-- hosts, and the fetch audit trail. Each row belongs to a team XOR one account's personal space.

-- A credential: metadata in clear, the secret sealed. `ciphertext` is the secret material sealed
-- with a per-row data key (AES-256-GCM, 12-byte nonce first, the scope and name as associated
-- data); `wrapped_key` is that data key sealed with the master key `key_id` names
-- (WT_DATA_MASTER_KEY). Rotation rewrites wrapped_key and key_id only.
CREATE TABLE data_credential (
    id          uuid        PRIMARY KEY,
    team_id     uuid        REFERENCES team (id) ON DELETE CASCADE,
    account_id  uuid        REFERENCES account (id) ON DELETE CASCADE,
    name        text        NOT NULL CHECK (name ~ '^[A-Za-z0-9_.-]{1,64}$'),
    kind        text        NOT NULL CHECK (kind IN ('bearer', 'basic', 'header', 'oauth2_client')),
    -- The only host (host[:port], lower case, port 443 omitted) the secret is ever sent to.
    host        text        NOT NULL,
    key_id      text        NOT NULL,
    wrapped_key bytea       NOT NULL,
    ciphertext  bytea       NOT NULL,
    created_by  uuid        REFERENCES account (id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    -- When the secret was last replaced; null when never.
    rotated_at  timestamptz,
    CONSTRAINT data_credential_scope_xor CHECK ((team_id IS NULL) <> (account_id IS NULL))
);
CREATE UNIQUE INDEX data_credential_team_name ON data_credential (team_id, name) WHERE team_id IS NOT NULL;
CREATE UNIQUE INDEX data_credential_account_name ON data_credential (account_id, name) WHERE account_id IS NOT NULL;
CREATE INDEX data_credential_key_idx ON data_credential (key_id);

-- A permitted host: host[:port], lower case, port 443 omitted; exact match, no wildcards.
CREATE TABLE data_allowed_host (
    id         uuid        PRIMARY KEY,
    team_id    uuid        REFERENCES team (id) ON DELETE CASCADE,
    account_id uuid        REFERENCES account (id) ON DELETE CASCADE,
    host       text        NOT NULL,
    added_by   uuid        REFERENCES account (id) ON DELETE SET NULL,
    added_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT data_allowed_host_scope_xor CHECK ((team_id IS NULL) <> (account_id IS NULL))
);
CREATE UNIQUE INDEX data_allowed_host_team ON data_allowed_host (team_id, host) WHERE team_id IS NOT NULL;
CREATE UNIQUE INDEX data_allowed_host_account ON data_allowed_host (account_id, host) WHERE account_id IS NOT NULL;

-- One row per Fetch, FetchAsset or Proxy call, written when it ends. The scope is the document's
-- (team_id XOR owner_account_id); account_id is who called. Deliberately no column for a query
-- string, a header or a body: `path` is the first request's path alone. Retained 90 days.
CREATE TABLE data_fetch_audit (
    id               uuid        PRIMARY KEY,
    team_id          uuid,
    owner_account_id uuid,
    document_id      uuid        NOT NULL,
    source_counter   bigint,
    source_replica   bigint,
    account_id       uuid        REFERENCES account (id) ON DELETE SET NULL,
    host             text        NOT NULL,
    path             text        NOT NULL CHECK (position('?' in path) = 0),
    kind             text        NOT NULL CHECK (kind IN ('source', 'script', 'asset')),
    started_at       timestamptz NOT NULL,
    finished_at      timestamptz NOT NULL,
    status           text        NOT NULL,
    pages            integer     NOT NULL DEFAULT 0,
    records          bigint      NOT NULL DEFAULT 0,
    bytes            bigint      NOT NULL DEFAULT 0,
    CONSTRAINT data_fetch_audit_scope_xor CHECK ((team_id IS NULL) <> (owner_account_id IS NULL))
);
CREATE INDEX data_fetch_audit_team_idx ON data_fetch_audit (team_id, started_at DESC, id) WHERE team_id IS NOT NULL;
CREATE INDEX data_fetch_audit_account_idx ON data_fetch_audit (owner_account_id, started_at DESC, id)
    WHERE owner_account_id IS NOT NULL;
CREATE INDEX data_fetch_audit_started_idx ON data_fetch_audit (started_at);

UPDATE schema_info SET value = 'DATA-005', updated_at = now() WHERE key = 'wiretuner.schema';
