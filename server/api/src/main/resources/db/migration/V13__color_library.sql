-- COLOR-020: team color libraries (docs/_includes/color/exporting-colors.adoc, Specification,
-- Server).  A document whose named colors are published to a team: the row is the flag.  In
-- automatic mode the published version is the document's head, read when asked, so the ingest
-- path writes nothing here; in manual mode published_seq holds the version the owner published
-- and colors the wiretuner.lib.v1.ColorLibrary extracted from it at publish time, so a version
-- older than the history retention window still answers.
-- A trashed document's library is hidden from List and Fetch; purging the document deletes it.
CREATE TABLE color_library (
    document_id   uuid        PRIMARY KEY REFERENCES document (id) ON DELETE CASCADE,
    team_id       uuid        NOT NULL REFERENCES team (id) ON DELETE CASCADE,
    name          text        NOT NULL,
    manual        boolean     NOT NULL DEFAULT false,
    published_seq bigint      NOT NULL DEFAULT 0 CHECK (published_seq >= 0),
    colors        bytea,
    published_by  uuid        REFERENCES account (id) ON DELETE SET NULL,
    published_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX color_library_team_idx ON color_library (team_id, name, document_id);
