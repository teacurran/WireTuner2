-- SRV-009, SRV-008, SEC-001: folders, library flags, blob tags, the text behind the search
-- record's highlights, and the columns TeamService needs (docs/spec/server.adoc, Persistence;
-- docs/spec/security.adoc, Schema).

-- Folders hold documents and folders; they carry no roles (access is per document and per space).
CREATE TABLE folder (
    id               uuid        PRIMARY KEY,
    owner_account_id uuid        REFERENCES account (id),
    team_id          uuid        REFERENCES team (id),
    parent_folder_id uuid        REFERENCES folder (id),
    name             text        NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT folder_space_xor CHECK ((owner_account_id IS NULL) <> (team_id IS NULL))
);
CREATE INDEX folder_parent_idx ON folder (parent_folder_id);
CREATE INDEX folder_owner_idx ON folder (owner_account_id) WHERE owner_account_id IS NOT NULL;
CREATE INDEX folder_team_idx ON folder (team_id) WHERE team_id IS NOT NULL;

-- The free-text folder column SRV-003 reserved becomes a reference to a folder row.
ALTER TABLE document DROP COLUMN folder;
ALTER TABLE document
    ADD COLUMN folder_id             uuid    REFERENCES folder (id),
    ADD COLUMN is_template           boolean NOT NULL DEFAULT false,
    ADD COLUMN is_library            boolean NOT NULL DEFAULT false,
    ADD COLUMN created_by_account_id uuid    REFERENCES account (id);
ALTER TABLE document ALTER COLUMN kind SET DEFAULT 'illustration_multi_page';
CREATE INDEX document_folder_idx ON document (folder_id) WHERE folder_id IS NOT NULL;

-- The tag a blob was first uploaded with: 'content' or 'thumbnail'.
ALTER TABLE blob ADD COLUMN tag text NOT NULL DEFAULT 'content' CHECK (tag IN ('content', 'thumbnail'));

-- The text lines behind document_search.body (text blocks 't:', notes 'n:'), so ts_headline has
-- source text to highlight; the tsvector alone cannot be highlighted.
ALTER TABLE document_search ADD COLUMN body_text text NOT NULL DEFAULT '';

-- Who sent an invitation.
ALTER TABLE team_invite ADD COLUMN invited_by_account_id uuid REFERENCES account (id) ON DELETE SET NULL;
CREATE INDEX team_invite_email_idx ON team_invite (team_id, lower(email));

-- Members may not export team documents as packages (WorkspaceSettings.restrict_package_export).
ALTER TABLE workspace ADD COLUMN restrict_package_export boolean NOT NULL DEFAULT false;

UPDATE schema_info SET value = 'SEC-001', updated_at = now() WHERE key = 'wiretuner.schema';
