-- analytics_test.create_user_posts_engagement_view
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   analytics.  → analytics_test.

CREATE OR REPLACE PROCEDURE analytics_test.create_user_posts_engagement_view()
 LANGUAGE plpgsql
AS $procedure$
BEGIN
    DROP MATERIALIZED VIEW IF EXISTS analytics_test.mv_user_posts_engagement CASCADE;

    CREATE MATERIALIZED VIEW analytics_test.mv_user_posts_engagement AS
    WITH roots AS (
        SELECT
            p.*,
            u.x_username AS root_username
        FROM mindshare_test.user_post p
        LEFT JOIN mindshare_test.mindshare_user u ON p.user_x_id = u.x_id
        WHERE (p.is_post = true OR p.is_quote = true)
          AND p.is_reply = false
          AND p.is_retweet = false
    ),
    engaged_tweets AS (
        SELECT
            post_id,
            user_x_id,
            is_reply,
            is_quote,
            is_retweet,
            post_created_at,
            replied_post_id,
            quoted_post_id,
            retweeted_post_id
        FROM mindshare_test.user_post
        WHERE (
            replied_post_id  IS NOT NULL
            OR quoted_post_id IS NOT NULL
            OR retweeted_post_id IS NOT NULL
        )
    ),
    engagements AS (
        -- Replies to the root
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
        INNER JOIN engaged_tweets e ON e.replied_post_id = r.post_id

        UNION ALL

        -- Quotes of the root
        SELECT
            r.post_id, r.user_x_id, r.root_username, r.post_created_at,
            r.is_post, r.is_quote, r.is_reply,
            r.favorite_count, r.reply_count,
            e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet, e.post_created_at
        FROM roots r
        INNER JOIN engaged_tweets e ON e.quoted_post_id = r.post_id AND e.replied_post_id IS NULL

        UNION ALL

        -- Retweets of the root
        SELECT
            r.post_id, r.user_x_id, r.root_username, r.post_created_at,
            r.is_post, r.is_quote, r.is_reply,
            r.favorite_count, r.reply_count,
            e.post_id, e.user_x_id, e.is_reply, e.is_quote, e.is_retweet, e.post_created_at
        FROM roots r
        INNER JOIN engaged_tweets e ON e.retweeted_post_id = r.post_id
    ),
    engagements_with_scores AS (
        SELECT
            e.*,
            COALESCE(mu.score, 0) AS engaged_user_score
        FROM engagements e
        LEFT JOIN mindshare_test.mindshare_user mu ON mu.x_id = e.engaged_user_id
    )
    SELECT * FROM engagements_with_scores;

    CREATE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_root
        ON analytics_test.mv_user_posts_engagement (root_post_id);
    CREATE INDEX IF NOT EXISTS ix_mv_user_posts_engagement_root_user
        ON analytics_test.mv_user_posts_engagement (root_user_id);
END;
$procedure$;
