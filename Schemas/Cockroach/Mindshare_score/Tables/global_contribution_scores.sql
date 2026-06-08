-- mindshare_score.global_contribution_scores — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare_score/Tables/global_contribution_scores.sql):
--   * active_multipliers: _numeric -> DECIMAL[].
--   * Added an explicit PRIMARY KEY on reply_post_id (cross-project table, so no
--     project_keyword column). One scored row per reply; reply_post_id is high-cardinality,
--     so no write hotspot. Widen the PK if a reply can be scored more than once.
--   * Indexes: dropped Postgres-only `USING btree`. idx_ucs_reply_post_id was a full
--     duplicate of the PK and has been removed.
--
-- ⚠ INSERT SEMANTICS CHANGE vs Postgres:
--   The Postgres source has no PK, so calculate_global_decay_scores can INSERT duplicate
--   rows for the same reply_post_id without error (e.g. if run twice).
--   With this PK, a duplicate INSERT raises a unique-constraint violation and aborts.
--   When porting calculate_global_decay_scores, change the INSERT to use:
--     INSERT ... ON CONFLICT (reply_post_id) DO UPDATE SET ...
--   Or truncate this table before each scoring run.

CREATE SCHEMA IF NOT EXISTS mindshare_score;

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
