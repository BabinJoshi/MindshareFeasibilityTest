-- mindshare.user_post — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare/Tables/user_post.sql):
--   * No partitioning in the original; PK is (post_created_at, post_id).
--   * Hash-sharded PK enabled (USING HASH WITH bucket_count=8) — post_created_at is sequential
--     and leads the PK with no project scoping, making this the highest-risk hotspot table.
--     Hashing spreads all-user writes across 8 buckets.
--   * GENERATED ALWAYS ... STORED columns kept verbatim.
--   * Indexes: dropped Postgres-only `USING btree`.

CREATE SCHEMA IF NOT EXISTS mindshare;

CREATE TABLE mindshare.user_post (
    post_id           TEXT NOT NULL,
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
    entities        JSONB NULL,
    project_keyword VARCHAR(255) NULL,
    CONSTRAINT user_post_pkey PRIMARY KEY (post_created_at, post_id)
        USING HASH WITH (bucket_count = 8)
);

CREATE INDEX idx_user_post_replied_post_id_time ON mindshare.user_post (replied_post_id, post_created_at);

CREATE INDEX idx_user_post_root_post_id ON mindshare.user_post (root_post_id);

CREATE INDEX idx_user_post_user_x_id_time ON mindshare.user_post (user_x_id, post_created_at);


CREATE INDEX ix_user_post_post_id ON mindshare.user_post (post_id);

CREATE INDEX ix_user_post_quoted_post_id ON mindshare.user_post (quoted_post_id);
