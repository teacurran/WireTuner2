-- BASIC-023 (server half): a team's floor for the review thresholds (docs/_includes/basics/
-- preferences.adoc, "Server").  The wiretuner.sync.v1.ReviewFloor message as proto JSON, read
-- into the Welcome of every session on the team's documents; the client applies it over the
-- user's thresholds.  NULL: the team has set none.  Plans and admin tooling set the column.
ALTER TABLE team ADD COLUMN review_floor jsonb
    CHECK (review_floor IS NULL OR jsonb_typeof(review_floor) = 'object');
