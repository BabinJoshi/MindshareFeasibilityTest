-- mindshare_score_test.get_mindshare_leaderboard
-- CockroachDB port:
--   analytics.  → analytics_test.
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.

CREATE OR REPLACE FUNCTION mindshare_score_test.get_mindshare_leaderboard(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(x_user_id text, x_username character varying, x_display_name character varying, x_avatar_url character varying, mindshare_score numeric, mindshare_percent numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query     TEXT;
    view_name     TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));
    v_post_cap    INT         := 5;
    v_cap_period  TEXT        := 'week';
    v_week_anchor TIMESTAMPTZ := NULL;
BEGIN

    SELECT
        COALESCE(post_cap,    5),
        COALESCE(cap_period,  'week'),
        COALESCE(cap_start_date, project_start_date)
    INTO
        v_post_cap,
        v_cap_period,
        v_week_anchor
    FROM mindshare_test.project_post_cap
    WHERE project_keyword  = projectname
      AND leaderboard_type = 'global';

    v_post_cap   := COALESCE(v_post_cap,   5);
    v_cap_period := COALESCE(v_cap_period, 'week');

    sql_query := FORMAT($q$

WITH

filtered_data AS (
    SELECT
        root_post_id,
        root_user_id,
        root_username,
        root_tweet_created_at,
        is_root_post,
        is_root_quote,
        is_root_reply,
        engaged_user_id,
        engaged_user_score,
        engaged_tweet_created_at,
        is_engaged_reply
    FROM analytics_test.%I
    WHERE root_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND root_user_id != ''
),

base_user AS (
    SELECT
        root_user_id,
        root_username,
        COUNT(DISTINCT root_post_id) FILTER (WHERE NOT is_root_reply) AS post_count,
        COUNT(DISTINCT root_post_id) FILTER (WHERE     is_root_reply) AS reply_count
    FROM filtered_data
    GROUP BY root_user_id, root_username
),

user_posts AS (
    SELECT DISTINCT
        root_post_id,
        root_user_id,
        root_tweet_created_at,
        is_root_post,
        is_root_quote,
        is_root_reply
    FROM filtered_data
),

unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        cs.original_post_id AS post_id,
        cs.original_author_x_id,
        cs.contribution_score
    FROM mindshare_score_test.contribution_scores cs
    WHERE cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND cs.replier_x_id <> cs.original_author_x_id
      AND cs.project_keyword = $3
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

post_sr_preview AS (
    SELECT
        uc.post_id AS original_post_id,
        SUM(uc.contribution_score)::NUMERIC AS post_smart_reach
    FROM unique_contributions uc
    GROUP BY uc.post_id
),

ranked_posts AS (
    SELECT
        up.root_post_id,
        up.root_user_id,
        COALESCE(psr.post_smart_reach, 0) * (COALESCE(mp.content_score, 50) / 100) AS post_score,
        ROW_NUMBER() OVER (
            PARTITION BY
                up.root_user_id,
                CASE $5
                    WHEN 'day' THEN
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                $6 + (FLOOR(EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6)) / 86400) * INTERVAL '1 day')
                            ELSE DATE_TRUNC('day', up.root_tweet_created_at)
                        END
                    WHEN 'week' THEN
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                $6 + (FLOOR(EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6)) / (7 * 86400)) * INTERVAL '7 days')
                            ELSE DATE_TRUNC('week', up.root_tweet_created_at + INTERVAL '1 day') - INTERVAL '1 day'
                        END
                    WHEN 'month' THEN
                        CASE
                            WHEN $6 IS NOT NULL THEN
                                $6 + (FLOOR(EXTRACT(EPOCH FROM (up.root_tweet_created_at - $6)) / (30 * 86400)) * INTERVAL '30 days')
                            ELSE DATE_TRUNC('month', up.root_tweet_created_at)
                        END
                    ELSE NULL
                END
            ORDER BY COALESCE(psr.post_smart_reach, 0) * (COALESCE(mp.content_score, 50) / 100) DESC
        ) AS post_rank
    FROM user_posts up
    LEFT JOIN post_sr_preview psr
        ON psr.original_post_id = up.root_post_id
    LEFT JOIN mindshare_test.mindshare_post mp
        ON  mp.post_id         = up.root_post_id
        AND mp.project_keyword = $3
    WHERE NOT up.is_root_reply
),

capped_posts AS (
    SELECT root_post_id, root_user_id, post_score
    FROM ranked_posts
    WHERE $4 = 0
       OR post_rank <= $4
),

user_post_scores AS (
    SELECT
        root_user_id AS handle,
        SUM(post_score)::NUMERIC AS user_post_score,
        COUNT(root_post_id)      AS post_count
    FROM capped_posts
    GROUP BY root_user_id
),

scores AS (
    SELECT
        bu.root_user_id              AS x_user_id,
        bu.root_username             AS x_username,
        COALESCE(u.display_name, '') AS x_display_name,
        u.avatar_url                 AS x_avatar_url,
        ROUND(
            COALESCE(ups.user_post_score, 0)
            + (COALESCE(ups.post_count, 0) * COALESCE(NULLIF(u.score, 0), 0.01))
            + (COALESCE(bu.reply_count, 0) * COALESCE(NULLIF(u.score, 0), 0.01) / 100),
            3
        ) AS mindshare_score
    FROM base_user bu
    LEFT JOIN user_post_scores ups
        ON  ups.handle = bu.root_user_id
    LEFT JOIN mindshare_test.mindshare_user u
        ON  u.x_id     = bu.root_user_id
)

SELECT
    s.x_user_id,
    s.x_username,
    s.x_display_name,
    s.x_avatar_url,
    s.mindshare_score,
    CASE
        WHEN SUM(s.mindshare_score) OVER () = 0 THEN 0
        ELSE ROUND(
            s.mindshare_score * 100.0 / SUM(s.mindshare_score) OVER (),
            2
        )
    END AS mindshare_percent
FROM scores s
WHERE s.x_username != $3
ORDER BY s.mindshare_score DESC NULLS LAST
LIMIT 1100

$q$, view_name);

    RETURN QUERY EXECUTE sql_query
        USING startdate, enddate, projectname, v_post_cap, v_cap_period, v_week_anchor;

END;
$function$;
