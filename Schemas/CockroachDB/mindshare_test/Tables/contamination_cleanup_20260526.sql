-- mindshare_test.contamination_cleanup_20260526 definition
-- CockroachDB port: schema renamed mindshare → mindshare_test

CREATE TABLE mindshare_test.contamination_cleanup_20260526 (
    post_id text NULL,
    project_keyword text NULL,
    user_x_id text NULL,
    full_text text NULL,
    mindshare_inserted_at timestamptz NULL
);
