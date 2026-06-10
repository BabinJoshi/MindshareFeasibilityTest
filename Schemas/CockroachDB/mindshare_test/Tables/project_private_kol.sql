-- mindshare_test.project_private_kol definition
-- CockroachDB port:
--   FK references mindshare_test.mindshare_project

CREATE TABLE mindshare_test.project_private_kol (
    id serial4 NOT NULL,
    project_name varchar(100) NOT NULL,
    twitter_user_id varchar(100) NOT NULL,
    created_at timestamptz DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    updated_at timestamptz DEFAULT (now() AT TIME ZONE 'utc'::text) NULL,
    CONSTRAINT project_private_kol_pkey PRIMARY KEY (id),
    CONSTRAINT project_private_kol_project_name_twitter_user_id_key UNIQUE (project_name, twitter_user_id),
    CONSTRAINT project_private_kol_project_name_fkey FOREIGN KEY (project_name)
        REFERENCES mindshare_test.mindshare_project (project_name) ON DELETE CASCADE ON UPDATE CASCADE
);
