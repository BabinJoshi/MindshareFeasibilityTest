-- mindshare.nucleus_post — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare/Tables/nucleus_post.sql):
--   * PARTITION BY LIST (project_keyword) removed. CRDB auto-shards by PK range and
--     rebalances across nodes; declarative LIST partitioning is an enterprise
--     geo/data-domiciling feature, not a query-pruning one. project_keyword still
--     leads the PK, so per-project clustering is preserved for free.
--   * Hash-sharded PK enabled (USING HASH WITH bucket_count=8). post_created_at is sequential;
--     hashing spreads writes across 8 buckets at the cost of slightly less efficient
--     unbounded time-range scans (filtered scans by project_keyword are unaffected).
--   * GENERATED ALWAYS ... STORED columns kept verbatim — CRDB accepts the syntax.
--   * Indexes: dropped Postgres-only `ON ONLY` and `USING btree`.

CREATE SCHEMA IF NOT EXISTS mindshare;

CREATE TABLE mindshare.nucleus_post (
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
    sentiment_score NUMERIC(3, 2) NULL,
    sentiment_label VARCHAR(20) NULL,
    entities        JSONB NULL,
    content_score   NUMERIC(5, 2) NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NULL     DEFAULT now(),
    is_reply_fetched BOOL NOT NULL DEFAULT false,
    CONSTRAINT nucleus_post_pkey PRIMARY KEY (project_keyword, post_created_at, post_id)
        USING HASH WITH (bucket_count = 8)
);

CREATE INDEX ix_nucleus_post_post_created_at ON mindshare.nucleus_post (post_created_at);

CREATE INDEX ix_nucleus_post_post_id ON mindshare.nucleus_post (post_id);

CREATE INDEX ix_nucleus_post_user_x_id_time ON mindshare.nucleus_post (user_x_id, post_created_at);
