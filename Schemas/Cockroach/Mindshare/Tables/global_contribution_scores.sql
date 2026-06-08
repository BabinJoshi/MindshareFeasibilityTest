-- mindshare_score.global_contribution_scores — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare_score/Tables/global_contribution_scores.sql):
--   * active_multipliers: _numeric -> DECIMAL[].
--   * Added an explicit PRIMARY KEY on reply_post_id (cross-project table, so no
--     project_keyword column). One scored row per reply; reply_post_id is high-cardinality,
--     so no write hotspot. Widen the PK if a reply can be scored more than once.
--   * Indexes: dropped Postgres-only `USING btree`. idx_ucs_reply_post_id duplicates the
--     PK and can be dropped; kept here for parity with the source.

CREATE TABLE mindshare_score.global_contribution_scores (
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
    CONSTRAINT global_contribution_scores_pkey PRIMARY KEY (reply_post_id)
);

CREATE INDEX idx_ucs_original_author ON mindshare_score.global_contribution_scores (original_author_x_id);

CREATE INDEX idx_ucs_original_post_id ON mindshare_score.global_contribution_scores (original_post_id);

CREATE INDEX idx_ucs_post_created ON mindshare_score.global_contribution_scores (post_created_at);

CREATE INDEX idx_ucs_replier ON mindshare_score.global_contribution_scores (replier_x_id);

CREATE INDEX idx_ucs_reply_post_id ON mindshare_score.global_contribution_scores (reply_post_id);
