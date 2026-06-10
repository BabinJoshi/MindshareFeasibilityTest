-- mindshare_score_test.contribution_scores definition
-- CockroachDB port:
--   _numeric → numeric[]
--   schema renamed mindshare_score → mindshare_score_test

CREATE TABLE mindshare_score_test.contribution_scores (
    project_keyword text NOT NULL,
    reply_post_id text NOT NULL,
    replier_x_id text NOT NULL,
    original_post_id text NOT NULL,
    original_author_x_id text NOT NULL,
    post_created_at timestamptz NOT NULL,
    replier_base_score numeric NOT NULL,
    effective_score numeric NOT NULL,
    contribution_score numeric NOT NULL,
    active_multipliers numeric[] NOT NULL,
    reply_number int4 NOT NULL,
    local_reply_count int4 NOT NULL,
    decay_type text NOT NULL
);

CREATE INDEX idx_cs_keyword_author ON mindshare_score_test.contribution_scores (project_keyword, original_author_x_id);
CREATE INDEX idx_cs_keyword_replier ON mindshare_score_test.contribution_scores (project_keyword, replier_x_id);
CREATE INDEX idx_cs_original_post_id ON mindshare_score_test.contribution_scores (original_post_id);
CREATE INDEX idx_cs_post_created ON mindshare_score_test.contribution_scores (post_created_at);
CREATE INDEX idx_cs_reply_post_id ON mindshare_score_test.contribution_scores (reply_post_id);
