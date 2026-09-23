-- COLLAB-011, COLLAB-012, COLLAB-030/031, WEB-012: the per-document team access override, the
-- expiry job's bookkeeping, team libraries, the server's record of comments with read marks and
-- notifications, synced preferences, and published web links (docs/_includes/collaboration/
-- sharing.adoc and comments.adoc, docs/_includes/web/publish-html.adoc, Specification).

-- The role the team's members get on this one document instead of the team default (SetTeamAccess);
-- null = the team default.
ALTER TABLE document ADD COLUMN team_access_override text
    CHECK (team_access_override IN ('editor', 'commenter', 'viewer'));

-- When the Invitations job told the people who opened a revoke-on-expiry link that its access ended.
ALTER TABLE share_link ADD COLUMN expiry_announced_at timestamptz;

-- Team libraries: a team document marked as a library, with the name the panels show.
-- document.is_library mirrors the row's existence for the library window.
CREATE TABLE library (
    document_id  uuid        PRIMARY KEY REFERENCES document (id) ON DELETE CASCADE,
    team_id      uuid        NOT NULL REFERENCES team (id) ON DELETE CASCADE,
    name         text        NOT NULL,
    published_by uuid        REFERENCES account (id) ON DELETE SET NULL,
    published_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX library_team_idx ON library (team_id, name, document_id);

-- The server's record of every comment thread and comment, kept from the ingested ops under the
-- comments node 0:12 (D-050): who opened each thread, who wrote each comment, and the resolved and
-- deleted registers (last writer wins by op id). Ids are OpId / ElementId (counter, replica); a
-- replica is a fixed64 stored as bigint, compared unsigned where order matters.
CREATE TABLE comment_thread (
    document_id       uuid    NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    node_counter      bigint  NOT NULL,
    node_replica      bigint  NOT NULL,
    opener_account_id uuid    REFERENCES account (id) ON DELETE SET NULL,
    resolved          boolean NOT NULL DEFAULT false,
    resolved_counter  bigint  NOT NULL DEFAULT 0,
    resolved_replica  bigint  NOT NULL DEFAULT 0,
    created_seq       bigint  NOT NULL,
    PRIMARY KEY (document_id, node_counter, node_replica)
);

CREATE TABLE comment (
    document_id       uuid    NOT NULL,
    thread_counter    bigint  NOT NULL,
    thread_replica    bigint  NOT NULL,
    element_counter   bigint  NOT NULL,
    element_replica   bigint  NOT NULL,
    author_account_id uuid    REFERENCES account (id) ON DELETE SET NULL,
    deleted           boolean NOT NULL DEFAULT false,
    deleted_counter   bigint  NOT NULL DEFAULT 0,
    deleted_replica   bigint  NOT NULL DEFAULT 0,
    -- The first 200 characters as first typed, for the digest's quote; later edits do not change it.
    preview           text    NOT NULL DEFAULT '',
    server_seq        bigint  NOT NULL,
    PRIMARY KEY (document_id, thread_counter, thread_replica, element_counter, element_replica),
    FOREIGN KEY (document_id, thread_counter, thread_replica)
        REFERENCES comment_thread (document_id, node_counter, node_replica) ON DELETE CASCADE
);
CREATE INDEX comment_element_idx ON comment (document_id, element_counter, element_replica);

-- Read marks (COLLAB-030): per account, document and thread, the newest comment seen.
CREATE TABLE comment_read (
    account_id      uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    document_id     uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    thread_counter  bigint      NOT NULL,
    thread_replica  bigint      NOT NULL,
    through_counter bigint      NOT NULL,
    through_replica bigint      NOT NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, document_id, thread_counter, thread_replica)
);

-- Notifications (COLLAB-030): a mention of the account, a reply to a thread it takes part in, its
-- thread resolved. `comment_*` is the comment element (the resolving op for 'resolved').
CREATE TABLE comment_notification (
    id                uuid        PRIMARY KEY,
    account_id        uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    document_id       uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    thread_counter    bigint      NOT NULL,
    thread_replica    bigint      NOT NULL,
    comment_counter   bigint      NOT NULL,
    comment_replica   bigint      NOT NULL,
    kind              text        NOT NULL CHECK (kind IN ('mention', 'reply', 'resolved')),
    author_account_id uuid        REFERENCES account (id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    seen_at           timestamptz,
    emailed_at        timestamptz
);
-- A reply or a resolve is notified once per recipient; a mention again only after 24 hours.
CREATE UNIQUE INDEX comment_notification_once ON comment_notification
    (account_id, document_id, thread_counter, thread_replica, comment_counter, comment_replica, kind)
    WHERE kind <> 'mention';
CREATE INDEX comment_notification_account_idx ON comment_notification (account_id, document_id, kind);
CREATE INDEX comment_notification_digest_idx ON comment_notification (created_at)
    WHERE kind = 'mention' AND seen_at IS NULL AND emailed_at IS NULL;

-- Synced preferences (account.v1 preferences.proto): the map from preference id to value, merged per
-- key by the server, as JSON.
ALTER TABLE account ADD COLUMN preferences jsonb NOT NULL DEFAULT '{}';

-- Published web links (WEB-012): a registered bundle of blobs, the one the document's link serves
-- marked current.
CREATE TABLE publish (
    id           uuid        PRIMARY KEY,
    document_id  uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    server_seq   bigint      NOT NULL DEFAULT 0,
    setting_name text        NOT NULL DEFAULT '',
    published_by uuid        REFERENCES account (id) ON DELETE SET NULL,
    published_at timestamptz NOT NULL DEFAULT now(),
    access       text        NOT NULL CHECK (access IN ('members', 'anyone')),
    is_current   boolean     NOT NULL DEFAULT false,
    file_count   integer     NOT NULL,
    total_size   bigint      NOT NULL
);
CREATE INDEX publish_document_idx ON publish (document_id, published_at DESC, id DESC);
CREATE UNIQUE INDEX publish_one_current ON publish (document_id) WHERE is_current;

CREATE TABLE publish_file (
    publish_id uuid   NOT NULL REFERENCES publish (id) ON DELETE CASCADE,
    path       text   NOT NULL,
    sha256     text   NOT NULL REFERENCES blob (sha256),
    media_type text   NOT NULL,
    PRIMARY KEY (publish_id, path)
);

UPDATE schema_info SET value = 'WEB-012', updated_at = now() WHERE key = 'wiretuner.schema';
