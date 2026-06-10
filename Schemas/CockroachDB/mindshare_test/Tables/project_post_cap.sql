-- mindshare_test.project_post_cap definition
-- CockroachDB port: schema renamed mindshare → mindshare_test

CREATE TABLE mindshare_test.project_post_cap (
    id serial4 NOT NULL,
    project_keyword text NOT NULL,
    leaderboard_type text NOT NULL,
    post_cap int4 DEFAULT 5 NOT NULL,
    cap_period text DEFAULT 'week'::text NOT NULL,
    cap_start_date timestamptz NULL,
    project_start_date timestamptz NULL,
    CONSTRAINT project_post_cap_cap_period_check CHECK (
        cap_period = ANY (ARRAY['day'::text, 'week'::text, 'month'::text, 'none'::text])
    ),
    CONSTRAINT project_post_cap_leaderboard_type_check CHECK (
        leaderboard_type = ANY (ARRAY['global'::text, 'private'::text])
    ),
    CONSTRAINT project_post_cap_pkey PRIMARY KEY (id),
    CONSTRAINT project_post_cap_project_keyword_leaderboard_type_key UNIQUE (project_keyword, leaderboard_type)
);
