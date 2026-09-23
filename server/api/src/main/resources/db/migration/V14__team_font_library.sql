-- TXT-002 (server half): team font libraries (docs/_includes/document/font-substitution.adoc,
-- Specification, Server).  A font file a team's admins uploaded: a content-addressed blob the team
-- references, with the faces read from the file's name and OS/2 tables at upload.  Removing a font
-- sets removed_at (hidden from List and Fetch at once); the Trash job deletes the row 30 days later
-- and the blob with the other orphans, unless the font was uploaded again meanwhile.  Deleting the
-- team row deletes its rows.  team.font_library_version moves with every upload and removal, so a client
-- that cached the catalog can ask whether it is current (ListFonts.known_version).
CREATE TABLE team_font (
    team_id     uuid        NOT NULL REFERENCES team (id) ON DELETE CASCADE,
    sha256      text        NOT NULL REFERENCES blob (sha256),
    file_name   text        NOT NULL,
    -- font/otf, font/ttf or font/collection, as read from the file.
    media_type  text        NOT NULL,
    -- The first face's family: the list's order.
    family      text        NOT NULL,
    -- The faces, as the encoded wiretuner.account.v1.TeamFont holding only `faces`.
    faces       bytea       NOT NULL,
    uploaded_by uuid        REFERENCES account (id) ON DELETE SET NULL,
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz,
    PRIMARY KEY (team_id, sha256)
);
CREATE INDEX team_font_list_idx ON team_font (team_id, family, file_name, sha256) WHERE removed_at IS NULL;
CREATE INDEX team_font_sha256_idx ON team_font (sha256);
CREATE INDEX team_font_removed_idx ON team_font (removed_at) WHERE removed_at IS NOT NULL;

ALTER TABLE team ADD COLUMN font_library_version bigint NOT NULL DEFAULT 0 CHECK (font_library_version >= 0);
