-- analytics_test.create_engagement_view
-- NEW: This procedure was called by run_create_engagement_views but was not defined
-- in the source codebase. Implemented here to match the pattern of the static
-- per-project MVs in materialzed_views.sql.
--
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   analytics.  → analytics_test.
--   TABLESPACE pg_default  → removed
--   Column alias list 'FROM roots r (col1, col2, ...)'  → removed (not supported in CRDB)
--   WITH DATA  → removed

CREATE OR REPLACE PROCEDURE analytics_test.create_engagement_view(IN p_project_keyword text)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_view_name  TEXT := 'mv_engagement_' || LOWER(REPLACE(p_project_keyword, ' ', '_'));
    v_idx_root   TEXT := 'ix_' || v_view_name || '_root';
    v_idx_tweet  TEXT := 'ix_' || v_view_name || '_tweet';
    v_idx_user   TEXT := 'ix_' || v_view_name || '_user';
BEGIN
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS analytics_test.%I CASCADE', v_view_name);

    EXECUTE format($sql$
        CREATE MATERIALIZED VIEW analytics_test.%I AS
        WITH roots AS (
            SELECT
                mp.post_id,
                mp.project_keyword,
                mp.user_x_id,
                mp.full_text,
                mp.retweeted_post_id,
                mp.replied_post_id,
                mp.quoted_post_id,
                mp.root_post_id,
                mp.is_retweet,
                mp.is_reply,
                mp.is_quote,
                mp.is_post,
                mp.view_count,
                mp.reply_count,
                mp.retweet_count,
                mp.quote_count,
                mp.favorite_count,
                mp.post_created_at,
                mp.created_at,
                mp.updated_at,
                mp.sentiment_score,
                mp.sentiment_label,
                mp.entities,
                mp.content_score,
                mu.x_username AS root_username
            FROM mindshare_test.mindshare_post mp
            LEFT JOIN mindshare_test.mindshare_user mu ON mu.x_id = mp.user_x_id
            WHERE mp.project_keyword = %L
              AND (mp.is_post = true OR mp.is_reply = true OR mp.is_quote = true)
        ),
        engaged_tweets AS (
            SELECT post_id, user_x_id, is_reply, is_quote, is_retweet,
                   post_created_at, replied_post_id, quoted_post_id, retweeted_post_id
            FROM mindshare_test.mindshare_post
            WHERE project_keyword = %L
              AND (replied_post_id IS NOT NULL OR quoted_post_id IS NOT NULL)
        ),
        engagements AS (
            SELECT
                r.post_id               AS root_post_id,
                r.user_x_id             AS root_user_id,
                r.root_username,
                r.post_created_at       AS root_tweet_created_at,
                r.is_post               AS is_root_post,
                r.is_quote              AS is_root_quote,
                r.is_reply              AS is_root_reply,
                r.favorite_count        AS root_favorite_count,
                r.reply_count           AS root_reply_count,
                e.post_id               AS engaged_tweet_id,
                e.user_x_id             AS engaged_user_id,
                e.is_reply              AS is_engaged_reply,
                e.is_quote              AS is_engaged_quote,
                e.is_retweet            AS is_engaged_repost,
                e.post_created_at       AS engaged_tweet_created_at
            FROM roots r
            JOIN engaged_tweets e ON e.replied_post_id = r.post_id
            UNION ALL
            SELECT
                r.post_id, r.user_x_id, r.root_username, r.post_created_at,
                r.is_post, r.is_quote, r.is_reply,
                r.favorite_count, r.reply_count,
                e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet, e.post_created_at
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
            LEFT JOIN mindshare_test.mindshare_user eu ON eu.x_id = e.engaged_user_id
        ),
        posts_with_no_engagement AS (
            SELECT
                r.post_id               AS root_post_id,
                r.user_x_id             AS root_user_id,
                r.root_username,
                r.post_created_at       AS root_tweet_created_at,
                r.is_post               AS is_root_post,
                r.is_quote              AS is_root_quote,
                r.is_reply              AS is_root_reply,
                r.favorite_count        AS root_favorite_count,
                r.reply_count           AS root_reply_count,
                NULL::text              AS engaged_tweet_id,
                NULL::text              AS engaged_user_id,
                NULL::boolean           AS is_engaged_reply,
                NULL::boolean           AS is_engaged_quote,
                NULL::boolean           AS is_engaged_repost,
                NULL::timestamptz       AS engaged_tweet_created_at,
                NULL::numeric           AS engaged_user_score
            FROM roots r
            WHERE NOT EXISTS (
                SELECT 1 FROM engagements_with_scores e WHERE e.root_post_id = r.post_id
            )
        )
        SELECT * FROM engagements_with_scores
        UNION ALL
        SELECT * FROM posts_with_no_engagement;
    $sql$, v_view_name, p_project_keyword, p_project_keyword);

    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_test.%I (root_post_id)',  v_idx_root,  v_view_name);
    -- UNIQUE index on engaged_tweet_id excluded: NULL values in CRDB cause issues with partial uniqueness.
    -- Use a partial unique index if enforcement is needed: WHERE engaged_tweet_id IS NOT NULL
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON analytics_test.%I (engaged_user_id)', v_idx_user,  v_view_name);
END;
$procedure$;
