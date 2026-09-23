-- SRV-010, SRV-012, SEC-002: sharing (pending invitations by email, link options, access requests),
-- presence colors, and the domain re-verification bookkeeping (docs/_includes/collaboration/
-- sharing.adoc and presence.adoc, Data model; docs/spec/security.adoc, Teams).

-- A member row with role 'none' only holds a presence color: someone with access through the team
-- default or a link who has opened the document (presence.adoc, Data model). It grants nothing.
ALTER TABLE document_member DROP CONSTRAINT document_member_role_check;
ALTER TABLE document_member ADD CONSTRAINT document_member_role_check
    CHECK (role IN ('owner', 'editor', 'commenter', 'viewer', 'none'));
-- Index into the 12-color palette, assigned on the account's first Subscribe; null until then.
ALTER TABLE document_member ADD COLUMN color_index smallint CHECK (color_index BETWEEN 0 AND 11);

-- Link options (sharing.adoc, Share links): a password (argon2id, PHC string), whether the access a
-- link granted ends with its expiry, and whether only members of the document's team may open it.
ALTER TABLE share_link
    ADD COLUMN password_hash     text,
    ADD COLUMN revoke_on_expiry  boolean NOT NULL DEFAULT false,
    ADD COLUMN team_members_only boolean NOT NULL DEFAULT false;

-- An invitation by email to an address no account has yet: it becomes a document_member row when an
-- account with that address, verified, first signs in.
CREATE TABLE document_invite (
    id          uuid        PRIMARY KEY,
    document_id uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    email       text        NOT NULL,
    role        text        NOT NULL CHECK (role IN ('editor', 'commenter', 'viewer')),
    invited_by  uuid        REFERENCES account (id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX document_invite_email ON document_invite (document_id, lower(email));
CREATE INDEX document_invite_email_idx ON document_invite (lower(email));

-- Requests for access (sharing.adoc, Requesting access); one pending request per person and document.
CREATE TABLE access_request (
    id           uuid        PRIMARY KEY,
    document_id  uuid        NOT NULL REFERENCES document (id) ON DELETE CASCADE,
    account_id   uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    message      text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    resolved_at  timestamptz,
    -- The role granted; null when declined (or still pending).
    granted_role text        CHECK (granted_role IN ('editor', 'commenter', 'viewer'))
);
CREATE UNIQUE INDEX access_request_pending ON access_request (document_id, account_id) WHERE resolved_at IS NULL;

-- The hourly re-verification (server.adoc, Jobs): when the record was last looked up, and how many
-- lookups in a row found it missing. A verified domain is dropped after three misses, so one DNS
-- outage does not end auto-admit.
ALTER TABLE workspace_domain
    ADD COLUMN checked_at    timestamptz,
    ADD COLUMN failed_checks integer NOT NULL DEFAULT 0;

UPDATE schema_info SET value = 'SRV-010', updated_at = now() WHERE key = 'wiretuner.schema';
