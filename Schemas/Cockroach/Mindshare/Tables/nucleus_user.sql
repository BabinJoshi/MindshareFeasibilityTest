-- mindshare.nucleus_user — CockroachDB port
--
-- Divergences from the Postgres source (Schemas/Mindshare/Tables/nuclues_user.sql):
--   * Indexes: dropped Postgres-only `USING btree`.
--   * No hotspot concern: PK is the high-cardinality x_id, not a sequential key.
--   * Types, jsonb, and now()-AT-TIME-ZONE defaults port unchanged.

CREATE SCHEMA IF NOT EXISTS mindshare;

CREATE TABLE mindshare.nucleus_user (
    x_id              VARCHAR(50) NOT NULL,
    x_username        VARCHAR(255) NOT NULL,
    display_name      VARCHAR(255) NOT NULL,
    score             NUMERIC(10, 2) NOT NULL,
    avatar_url        VARCHAR(1000) NOT NULL,
    adjustment_config JSONB NOT NULL,
    followers_count   INT4 NOT NULL,
    verified          BOOL NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NULL     DEFAULT now(),
    CONSTRAINT nucleus_user_pkey PRIMARY KEY (x_id)
);

CREATE INDEX ix_mindshare_nucleus_user_x_username ON mindshare.nucleus_user (x_username);
