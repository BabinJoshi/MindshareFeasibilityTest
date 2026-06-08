-- mindshare_score.contribution_scores — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare_score/Tables/contribution_scores.sql):
--   * active_multipliers: _numeric -> DECIMAL[] (CRDB array spelling).
--   * Added an explicit PRIMARY KEY. The Postgres table has none, so CRDB would add a
--     hidden rowid; (project_keyword, reply_post_id) is a natural key — one scored row
--     per reply — and reply_post_id is high-cardinality, so no write hotspot.
--     If a reply can be scored more than once, widen the PK accordingly.
--   * Indexes: dropped Postgres-only `USING btree`. The idx_cs_reply_post_id index is
--     now redundant with the PK prefix and can be dropped if (project_keyword, reply_post_id)
--     is the PK; kept here for parity with the source.

CREATE TABLE mindshare_score.contribution_scores (
    project_keyword      TEXT NOT NULL,
    reply_post_id        TEXT NOT NULL,
    replier_x_id         TEXT NOT NULL,
    original_post_id     TEXT NOT NULL,
    original_author_x_id TEXT NOT NULL,
    post_created_at      TIMESTAMPTZ NOT NULL,
    replier_base_score   NUMERIC NOT NULL,
    effective_score      NUMERIC NOT NULL,
    contribution_score   NUMERIC NOT NULL,
    active_multipliers   DECIMAL[] NOT NULL,
    reply_number         INT4 NOT NULL,
    local_reply_count    INT4 NOT NULL,
    decay_type           TEXT NOT NULL,
    CONSTRAINT contribution_scores_pkey PRIMARY KEY (project_keyword, reply_post_id)
);

CREATE INDEX idx_cs_keyword_author ON mindshare_score.contribution_scores (project_keyword, original_author_x_id);

CREATE INDEX idx_cs_keyword_replier ON mindshare_score.contribution_scores (project_keyword, replier_x_id);

CREATE INDEX idx_cs_original_post_id ON mindshare_score.contribution_scores (original_post_id);

CREATE INDEX idx_cs_post_created ON mindshare_score.contribution_scores (post_created_at);

CREATE INDEX idx_cs_reply_post_id ON mindshare_score.contribution_scores (reply_post_id);
