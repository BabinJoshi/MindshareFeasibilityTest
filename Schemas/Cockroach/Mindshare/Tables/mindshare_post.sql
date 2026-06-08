-- mindshare.mindshare_post — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare/Tables/mindshare_post.sql):
--   * PARTITION BY LIST (project_keyword) removed (see nucleus_post.sql for rationale).
--   * Hash-sharded PK enabled (USING HASH WITH bucket_count=8) to spread sequential-time writes.
--   * GENERATED ALWAYS ... STORED columns kept verbatim.
--   * Indexes: dropped Postgres-only `ON ONLY` and `USING btree`.
--
-- Differs from nucleus_post: no is_reply_fetched / no sentiment-after-counts ordering;
-- has latest_reply_at. Column set matches the Postgres source.

CREATE SCHEMA IF NOT EXISTS mindshare;

CREATE TABLE mindshare.mindshare_post (
    post_id           TEXT NOT NULL,
    project_keyword   TEXT NOT NULL,
    user_x_id         TEXT NOT NULL,
    full_text         TEXT NOT NULL,
    retweeted_post_id TEXT NULL,
    replied_post_id   TEXT NULL,
    quoted_post_id    TEXT NULL,
    root_post_id      TEXT NULL,
    is_retweet BOOL NOT NULL GENERATED ALWAYS AS (retweeted_post_id IS NOT NULL) STORED,
    is_reply   BOOL NOT NULL GENERATED ALWAYS AS (replied_post_id   IS NOT NULL) STORED,
    is_quote   BOOL NOT NULL GENERATED ALWAYS AS (quoted_post_id    IS NOT NULL) STORED,
    is_post    BOOL NOT NULL GENERATED ALWAYS AS (
        retweeted_post_id IS NULL
        AND replied_post_id IS NULL
        AND quoted_post_id IS NULL
    ) STORED,
    view_count      INT4 NOT NULL,
    reply_count     INT4 NOT NULL,
    retweet_count   INT4 NOT NULL,
    quote_count     INT4 NOT NULL,
    favorite_count  INT4 NOT NULL,
    post_created_at TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NULL     DEFAULT now(),
    sentiment_score NUMERIC(3, 2) NULL,
    sentiment_label VARCHAR(20) NULL,
    entities        JSONB NULL,
    content_score   NUMERIC(5, 2) NULL,
    latest_reply_at TIMESTAMPTZ NULL,
    CONSTRAINT mindshare_post_pkey PRIMARY KEY (project_keyword, post_created_at, post_id)
        USING HASH WITH (bucket_count = 8)
);

CREATE INDEX ix_mindshare_post_post_created_at ON mindshare.mindshare_post (post_created_at);

CREATE INDEX ix_mindshare_post_post_id ON mindshare.mindshare_post (post_id);

CREATE INDEX ix_mindshare_post_user_x_id_time ON mindshare.mindshare_post (user_x_id, post_created_at);
