-- mindshare_test."admin" definition
-- CockroachDB port: schema renamed mindshare → mindshare_test

CREATE TABLE mindshare_test."admin" (
    username varchar(255) NOT NULL,
    hashed_password varchar(255) NOT NULL,
    is_active bool DEFAULT true NOT NULL,
    created_at timestamptz DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    updated_at timestamptz DEFAULT (now() AT TIME ZONE 'utc'::text) NULL,
    CONSTRAINT admin_pkey PRIMARY KEY (username)
);
