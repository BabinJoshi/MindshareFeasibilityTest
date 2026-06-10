-- analytics_test materialized views — static per-project snapshots
-- CockroachDB port:
--   analytics.         → analytics_test.
--   mindshare.         → mindshare_test.
--   TABLESPACE pg_default → removed (unsupported)
--   WITH DATA          → removed (CRDB always creates with data)
--   FROM roots r (col1, col2, ...) column alias list → removed (pg_dump artifact, not valid SQL)
--     mu.created_at aliased AS mu_created_at (was created_at_1 in pg_dump alias list)
--     mu.updated_at aliased AS mu_updated_at (was updated_at_1 in pg_dump alias list)
--   USING btree        → removed from CREATE INDEX (CRDB index syntax)
--   UNIQUE INDEX on engaged_tweet_id: CRDB allows multiple NULLs in a unique index — kept as-is

-- ----------------------------------------------------------------------------
-- mv_engagement__technotainment
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW analytics_test.mv_engagement__technotainment AS
WITH roots AS (
    SELECT
        mindshare_post.post_id,
        mindshare_post.project_keyword,
        mindshare_post.user_x_id,
        mindshare_post.full_text,
        mindshare_post.retweeted_post_id,
        mindshare_post.replied_post_id,
        mindshare_post.quoted_post_id,
        mindshare_post.root_post_id,
        mindshare_post.is_retweet,
        mindshare_post.is_reply,
        mindshare_post.is_quote,
        mindshare_post.is_post,
        mindshare_post.view_count,
        mindshare_post.reply_count,
        mindshare_post.retweet_count,
        mindshare_post.quote_count,
        mindshare_post.favorite_count,
        mindshare_post.post_created_at,
        mindshare_post.created_at,
        mindshare_post.updated_at,
        mindshare_post.sentiment_score,
        mindshare_post.sentiment_label,
        mindshare_post.entities,
        mindshare_post.content_score,
        mu.x_id,
        mu.x_username,
        mu.display_name,
        mu.score,
        mu.avatar_url,
        mu.adjustment_config,
        mu.followers_count,
        mu.verified,
        mu.created_at AS mu_created_at,
        mu.updated_at AS mu_updated_at,
        mu.x_username AS root_username
    FROM mindshare_test.mindshare_post
    LEFT JOIN mindshare_test.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
    WHERE mindshare_post.project_keyword = '_technotainment'::text
      AND (
          mindshare_post.is_post = true
          OR mindshare_post.is_reply = true
          OR mindshare_post.is_quote = true
      )
),
engaged_tweets AS (
    SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
    FROM mindshare_test.mindshare_post
    WHERE mindshare_post.project_keyword = '_technotainment'::text
      AND (
          mindshare_post.replied_post_id IS NOT NULL
          OR mindshare_post.quoted_post_id IS NOT NULL
      )
),
engagements AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.replied_post_id = r.post_id
    UNION ALL
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL
),
engagements_with_scores AS (
    SELECT
        e.root_post_id,
        e.root_user_id,
        e.root_username,
        e.root_tweet_created_at,
        e.is_root_post,
        e.is_root_quote,
        e.is_root_reply,
        e.root_favorite_count,
        e.root_reply_count,
        e.engaged_tweet_id,
        e.engaged_user_id,
        e.is_engaged_reply,
        e.is_engaged_quote,
        e.is_engaged_repost,
        e.engaged_tweet_created_at,
        eu.score AS engaged_user_score
    FROM engagements e
    LEFT JOIN mindshare_test.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
),
posts_with_no_engagement AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        NULL::text AS engaged_tweet_id,
        NULL::text AS engaged_user_id,
        NULL::boolean AS is_engaged_reply,
        NULL::boolean AS is_engaged_quote,
        NULL::boolean AS is_engaged_repost,
        NULL::timestamp with time zone AS engaged_tweet_created_at,
        NULL::numeric AS engaged_user_score
    FROM roots r
    WHERE NOT EXISTS (
        SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id
    )
)
SELECT * FROM engagements_with_scores
UNION ALL
SELECT * FROM posts_with_no_engagement;

CREATE INDEX ix_mv_engagement__technotainment_root  ON analytics_test.mv_engagement__technotainment (root_post_id);
CREATE UNIQUE INDEX ix_mv_engagement__technotainment_tweet ON analytics_test.mv_engagement__technotainment (engaged_tweet_id);
CREATE INDEX ix_mv_engagement__technotainment_user  ON analytics_test.mv_engagement__technotainment (engaged_user_id);

-- ----------------------------------------------------------------------------
-- mv_engagement_quipnetwork
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW analytics_test.mv_engagement_quipnetwork AS
WITH roots AS (
    SELECT
        mindshare_post.post_id,
        mindshare_post.project_keyword,
        mindshare_post.user_x_id,
        mindshare_post.full_text,
        mindshare_post.retweeted_post_id,
        mindshare_post.replied_post_id,
        mindshare_post.quoted_post_id,
        mindshare_post.root_post_id,
        mindshare_post.is_retweet,
        mindshare_post.is_reply,
        mindshare_post.is_quote,
        mindshare_post.is_post,
        mindshare_post.view_count,
        mindshare_post.reply_count,
        mindshare_post.retweet_count,
        mindshare_post.quote_count,
        mindshare_post.favorite_count,
        mindshare_post.post_created_at,
        mindshare_post.created_at,
        mindshare_post.updated_at,
        mindshare_post.sentiment_score,
        mindshare_post.sentiment_label,
        mindshare_post.entities,
        mindshare_post.content_score,
        mu.x_id,
        mu.x_username,
        mu.display_name,
        mu.score,
        mu.avatar_url,
        mu.adjustment_config,
        mu.followers_count,
        mu.verified,
        mu.created_at AS mu_created_at,
        mu.updated_at AS mu_updated_at,
        mu.x_username AS root_username
    FROM mindshare_test.mindshare_post
    LEFT JOIN mindshare_test.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
    WHERE mindshare_post.project_keyword = 'quipnetwork'::text
      AND (
          mindshare_post.is_post = true
          OR mindshare_post.is_reply = true
          OR mindshare_post.is_quote = true
      )
),
engaged_tweets AS (
    SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
    FROM mindshare_test.mindshare_post
    WHERE mindshare_post.project_keyword = 'quipnetwork'::text
      AND (
          mindshare_post.replied_post_id IS NOT NULL
          OR mindshare_post.quoted_post_id IS NOT NULL
      )
),
engagements AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.replied_post_id = r.post_id
    UNION ALL
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL
),
engagements_with_scores AS (
    SELECT
        e.root_post_id,
        e.root_user_id,
        e.root_username,
        e.root_tweet_created_at,
        e.is_root_post,
        e.is_root_quote,
        e.is_root_reply,
        e.root_favorite_count,
        e.root_reply_count,
        e.engaged_tweet_id,
        e.engaged_user_id,
        e.is_engaged_reply,
        e.is_engaged_quote,
        e.is_engaged_repost,
        e.engaged_tweet_created_at,
        eu.score AS engaged_user_score
    FROM engagements e
    LEFT JOIN mindshare_test.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
),
posts_with_no_engagement AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        NULL::text AS engaged_tweet_id,
        NULL::text AS engaged_user_id,
        NULL::boolean AS is_engaged_reply,
        NULL::boolean AS is_engaged_quote,
        NULL::boolean AS is_engaged_repost,
        NULL::timestamp with time zone AS engaged_tweet_created_at,
        NULL::numeric AS engaged_user_score
    FROM roots r
    WHERE NOT EXISTS (
        SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id
    )
)
SELECT * FROM engagements_with_scores
UNION ALL
SELECT * FROM posts_with_no_engagement;

CREATE INDEX ix_mv_engagement_quipnetwork_root  ON analytics_test.mv_engagement_quipnetwork (root_post_id);
CREATE UNIQUE INDEX ix_mv_engagement_quipnetwork_tweet ON analytics_test.mv_engagement_quipnetwork (engaged_tweet_id);
CREATE INDEX ix_mv_engagement_quipnetwork_user  ON analytics_test.mv_engagement_quipnetwork (engaged_user_id);

-- ----------------------------------------------------------------------------
-- mv_engagement_pact_swap
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW analytics_test.mv_engagement_pact_swap AS
WITH roots AS (
    SELECT
        mindshare_post.post_id,
        mindshare_post.project_keyword,
        mindshare_post.user_x_id,
        mindshare_post.full_text,
        mindshare_post.retweeted_post_id,
        mindshare_post.replied_post_id,
        mindshare_post.quoted_post_id,
        mindshare_post.root_post_id,
        mindshare_post.is_retweet,
        mindshare_post.is_reply,
        mindshare_post.is_quote,
        mindshare_post.is_post,
        mindshare_post.view_count,
        mindshare_post.reply_count,
        mindshare_post.retweet_count,
        mindshare_post.quote_count,
        mindshare_post.favorite_count,
        mindshare_post.post_created_at,
        mindshare_post.created_at,
        mindshare_post.updated_at,
        mindshare_post.sentiment_score,
        mindshare_post.sentiment_label,
        mindshare_post.entities,
        mindshare_post.content_score,
        mu.x_id,
        mu.x_username,
        mu.display_name,
        mu.score,
        mu.avatar_url,
        mu.adjustment_config,
        mu.followers_count,
        mu.verified,
        mu.created_at AS mu_created_at,
        mu.updated_at AS mu_updated_at,
        mu.x_username AS root_username
    FROM mindshare_test.mindshare_post
    LEFT JOIN mindshare_test.mindshare_user mu ON mu.x_id::text = mindshare_post.user_x_id
    WHERE mindshare_post.project_keyword = 'Pact_Swap'::text
      AND (
          mindshare_post.is_post = true
          OR mindshare_post.is_reply = true
          OR mindshare_post.is_quote = true
      )
),
engaged_tweets AS (
    SELECT mindshare_post.post_id, mindshare_post.user_x_id, mindshare_post.is_reply, mindshare_post.is_quote, mindshare_post.is_retweet, mindshare_post.post_created_at, mindshare_post.replied_post_id, mindshare_post.quoted_post_id, mindshare_post.retweeted_post_id
    FROM mindshare_test.mindshare_post
    WHERE mindshare_post.project_keyword = 'Pact_Swap'::text
      AND (
          mindshare_post.replied_post_id IS NOT NULL
          OR mindshare_post.quoted_post_id IS NOT NULL
      )
),
engagements AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.replied_post_id = r.post_id
    UNION ALL
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        e.post_id AS engaged_tweet_id,
        e.user_x_id AS engaged_user_id,
        e.is_reply AS is_engaged_reply,
        e.is_quote AS is_engaged_quote,
        e.is_retweet AS is_engaged_repost,
        e.post_created_at AS engaged_tweet_created_at
    FROM roots r
    JOIN engaged_tweets e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL
),
engagements_with_scores AS (
    SELECT
        e.root_post_id,
        e.root_user_id,
        e.root_username,
        e.root_tweet_created_at,
        e.is_root_post,
        e.is_root_quote,
        e.is_root_reply,
        e.root_favorite_count,
        e.root_reply_count,
        e.engaged_tweet_id,
        e.engaged_user_id,
        e.is_engaged_reply,
        e.is_engaged_quote,
        e.is_engaged_repost,
        e.engaged_tweet_created_at,
        eu.score AS engaged_user_score
    FROM engagements e
    LEFT JOIN mindshare_test.mindshare_user eu ON eu.x_id::text = e.engaged_user_id
),
posts_with_no_engagement AS (
    SELECT
        r.post_id AS root_post_id,
        r.user_x_id AS root_user_id,
        r.root_username,
        r.post_created_at AS root_tweet_created_at,
        r.is_post AS is_root_post,
        r.is_quote AS is_root_quote,
        r.is_reply AS is_root_reply,
        r.favorite_count AS root_favorite_count,
        r.reply_count AS root_reply_count,
        NULL::text AS engaged_tweet_id,
        NULL::text AS engaged_user_id,
        NULL::boolean AS is_engaged_reply,
        NULL::boolean AS is_engaged_quote,
        NULL::boolean AS is_engaged_repost,
        NULL::timestamp with time zone AS engaged_tweet_created_at,
        NULL::numeric AS engaged_user_score
    FROM roots r
    WHERE NOT EXISTS (
        SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id
    )
)
SELECT * FROM engagements_with_scores
UNION ALL
SELECT * FROM posts_with_no_engagement;

CREATE INDEX ix_mv_engagement_pact_swap_root  ON analytics_test.mv_engagement_pact_swap (root_post_id);
CREATE UNIQUE INDEX ix_mv_engagement_pact_swap_tweet ON analytics_test.mv_engagement_pact_swap (engaged_tweet_id);
CREATE INDEX ix_mv_engagement_pact_swap_user  ON analytics_test.mv_engagement_pact_swap (engaged_user_id);
