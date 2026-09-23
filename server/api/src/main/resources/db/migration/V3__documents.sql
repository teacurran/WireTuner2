-- SRV-003: documents, roles, branches, versions and the search record (docs/spec/server.adoc,
-- Persistence). Content hashes (sha256) are stored as lower-case hex text everywhere so they read
-- in psql and compare as strings in Java.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE document (
    id               uuid        PRIMARY KEY,
    -- The space: a personal account XOR a team, never both, never neither.
    owner_account_id uuid        REFERENCES account (id),
    team_id          uuid        REFERENCES team (id),
    name             text        NOT NULL DEFAULT '',
    folder           text        NOT NULL DEFAULT '',
    kind             text        NOT NULL DEFAULT 'document',
    -- The highest schema feature any change in the document has used.
    feature_level    integer     NOT NULL DEFAULT 0,
    head_seq         bigint      NOT NULL DEFAULT 0,
    stable_seq       bigint      NOT NULL DEFAULT 0,
    trashed_at       timestamptz,
    -- sha256 of the client-rendered thumbnail; the blob table arrives in V5 with the FK.
    thumbnail_blob   text        CHECK (thumbnail_blob ~ '^[0-9a-f]{64}$'),
    thumbnail_at     timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT document_space_xor CHECK ((owner_account_id IS NULL) <> (team_id IS NULL)),
    CONSTRAINT document_seqs CHECK (stable_seq >= 0 AND head_seq >= stable_seq)
);
CREATE INDEX document_owner_idx ON document (owner_account_id) WHERE owner_account_id IS NOT NULL;
CREATE INDEX document_team_idx ON document (team_id) WHERE team_id IS NOT NULL;
-- Document names are matched live ("logo" finds "Logotype v3"), so a rename is searchable at once.
CREATE INDEX document_name_trgm ON document USING gin (name gin_trgm_ops);

-- Explicit per-document roles. The owner of a personal document is document.owner_account_id;
-- a team document's owner is its single member with role 'owner' (team admins hold the owner's
-- administrative powers without a row here).
CREATE TABLE document_member (
    document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    account_id  uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    role        text        NOT NULL CHECK (role IN ('owner', 'editor', 'commenter', 'viewer')),
    added_by    uuid        REFERENCES account (id),
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, account_id)
);
CREATE INDEX document_member_account_idx ON document_member (account_id);
-- Exactly one owner per document.
CREATE UNIQUE INDEX document_member_one_owner ON document_member (document_id) WHERE role = 'owner';

CREATE TABLE share_link (
    id          uuid        PRIMARY KEY,
    document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    -- sha256 of the 128-bit link token, lower-case hex; the token itself is only in the URL.
    token_hash  text        NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    role        text        NOT NULL CHECK (role IN ('editor', 'commenter', 'viewer')),
    created_by  uuid        REFERENCES account (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz,
    revoked_at  timestamptz
);
CREATE INDEX share_link_document_idx ON share_link (document_id);

-- Which accounts opened which link: the effective role includes a link's role only for an
-- account that used it (docs/spec/security.adoc, Document roles).
CREATE TABLE share_link_use (
    share_link_id uuid        NOT NULL REFERENCES share_link (id) ON DELETE CASCADE,
    account_id    uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    used_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (share_link_id, account_id)
);
CREATE INDEX share_link_use_account_idx ON share_link_use (account_id);

-- A branch is a child document forked from a parent at a server_seq.
CREATE TABLE branch (
    document_id        uuid        PRIMARY KEY REFERENCES document (id) ON DELETE CASCADE,
    parent_document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    fork_seq           bigint      NOT NULL CHECK (fork_seq >= 0),
    created_at         timestamptz NOT NULL DEFAULT now(),
    merged_at          timestamptz
);
CREATE INDEX branch_parent_idx ON branch (parent_document_id);

CREATE TABLE version (
    document_id       uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    server_seq        bigint      NOT NULL CHECK (server_seq >= 0),
    name              text        NOT NULL,
    author_account_id uuid        REFERENCES account (id),
    created_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, server_seq)
);

-- The search record the snapshotter extracts; never read by sync (docs/spec/server.adoc, Search).
CREATE TABLE document_search (
    document_id uuid        PRIMARY KEY REFERENCES document (id) ON DELETE CASCADE,
    server_seq  bigint      NOT NULL,
    -- Object, swatch, style, symbol and page names and keywords, one per line with a field prefix.
    names       text        NOT NULL DEFAULT '',
    -- Text block contents and notes, 'simple' configuration.
    body        tsvector    NOT NULL DEFAULT ''::tsvector,
    -- The names again as words, so a name matches as a word as well as a substring.
    names_body  tsvector    NOT NULL DEFAULT ''::tsvector,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX document_search_names_trgm ON document_search USING gin (names gin_trgm_ops);
CREATE INDEX document_search_body_idx ON document_search USING gin (body);
CREATE INDEX document_search_names_body_idx ON document_search USING gin (names_body);
