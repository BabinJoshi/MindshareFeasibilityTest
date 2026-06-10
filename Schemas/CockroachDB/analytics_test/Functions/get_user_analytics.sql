-- analytics_test.get_user_analytics
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.
-- CRDB notes: format() with %L for user ID literals — unchanged

CREATE OR REPLACE FUNCTION analytics_test.get_user_analytics(target_user_id text, limit_cnt integer DEFAULT NULL::integer)
 RETURNS TABLE(total_unique_engaged_users bigint, total_post_count bigint, total_quote_post_count bigint, total_post_view_count bigint, total_quote_post_view_count bigint, total_view_count bigint, x_id text, x_username text, x_score numeric, engagements bigint, likes bigint, replies bigint, retweets bigint, like_to_reply_ratio numeric, reach numeric, unique_reach numeric, first_post_date timestamp with time zone, last_post_date timestamp with time zone, self_replies bigint, average_p90 numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
BEGIN
    sql_query := format($q$
    WITH target_posts AS (
        SELECT post_id
        FROM mindshare_test.user_post
        WHERE user_x_id = %L
          AND (is_post OR (is_quote AND NOT is_reply))
        ORDER BY post_created_at DESC
        LIMIT %s
    ),
    filtered AS (
        SELECT mp.*
        FROM mindshare_test.user_post mp
        JOIN target_posts tp ON mp.post_id = tp.post_id
    ),
    project_totals AS (
        SELECT
            COALESCE(COUNT(*) FILTER (WHERE is_post), 0) AS total_post_count,
            COALESCE(COUNT(*) FILTER (WHERE is_quote AND NOT is_reply), 0) AS total_quote_post_count,
            COALESCE(SUM(CASE WHEN is_post THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_post_view_count,
            COALESCE(SUM(CASE WHEN is_quote AND NOT is_reply THEN COALESCE(view_count,0) ELSE 0 END), 0) AS total_quote_post_view_count,
            MIN(post_created_at) AS first_post_date,
            MAX(post_created_at) AS last_post_date
        FROM filtered
    ),
    user_p90_stats AS (
        SELECT
            tp.user_x_id AS x_id,
            ROUND(AVG(fe.duration_days_p90)::numeric, 2) AS average_p90
        FROM filtered tp
        JOIN mindshare_score_test.mv_user_posts_engagement_features fe
            ON fe.root_post_id = tp.post_id
        GROUP BY tp.user_x_id
    ),
    user_stats AS (
        SELECT
            user_x_id AS x_id,
            SUM(CASE WHEN is_post OR (is_quote AND NOT is_reply) THEN COALESCE(favorite_count, 0) ELSE 0 END) AS likes,
            SUM(CASE WHEN is_post OR (is_quote AND NOT is_reply) THEN COALESCE(retweet_count, 0) ELSE 0 END) AS retweets,
            SUM(CASE WHEN is_post OR (is_quote AND NOT is_reply) THEN COALESCE(favorite_count, 0) + COALESCE(retweet_count, 0) ELSE 0 END) AS internal_engagements,
            COUNT(*) FILTER (WHERE is_post) AS post_count,
            COUNT(*) FILTER (WHERE is_quote AND NOT is_reply) AS quote_post_count,
            COUNT(*) FILTER (WHERE is_reply) AS replies_count,
            SUM(CASE WHEN is_post THEN COALESCE(view_count, 0) ELSE 0 END) AS post_view_count,
            SUM(CASE WHEN is_quote AND NOT is_reply THEN COALESCE(view_count, 0) ELSE 0 END) AS quote_view_count,
            SUM(CASE WHEN is_reply THEN COALESCE(view_count, 0) ELSE 0 END) AS replies_view_count
        FROM filtered
        GROUP BY user_x_id
    ),
    incoming_engagements AS (
        SELECT
            mp.user_x_id AS engaged_user_id,
            COALESCE(mu.score, 0) AS engaged_user_score,
            mp.post_id AS engaged_tweet_id,
            mp.is_reply AS is_engaged_reply,
            COALESCE(mp.replied_post_id, mp.quoted_post_id) AS target_post_id
        FROM mindshare_test.user_post mp
        LEFT JOIN mindshare_test.mindshare_user mu ON mp.user_x_id = mu.x_id
        WHERE mp.replied_post_id IN (SELECT post_id FROM target_posts)
           OR mp.quoted_post_id  IN (SELECT post_id FROM target_posts)
    ),
    unique_engager_scores AS (
        SELECT engaged_user_id, MAX(COALESCE(engaged_user_score, 0)) AS unique_score
        FROM incoming_engagements
        WHERE engaged_user_id != %L
        GROUP BY engaged_user_id
    ),
    final_unique_reach AS (
        SELECT SUM(unique_score) AS total_unique_reach FROM unique_engager_scores
    ),
    post_unique_reach AS (
        SELECT target_post_id, SUM(max_engager_score) AS p_unique_reach
        FROM (
            SELECT target_post_id, engaged_user_id, MAX(engaged_user_score) AS max_engager_score
            FROM incoming_engagements WHERE engaged_user_id != %L
            GROUP BY target_post_id, engaged_user_id
        ) sub
        GROUP BY target_post_id
    ),
    engagement_totals AS (
        SELECT
            COUNT(*) FILTER (WHERE engaged_user_id != %L) AS replies_received,
            COUNT(*) FILTER (WHERE engaged_user_id  = %L) AS self_replies_count,
            COUNT(DISTINCT engaged_user_id) FILTER (WHERE engaged_user_id != %L) AS total_unique_engaged_users,
            COALESCE((SELECT SUM(p_unique_reach) FROM post_unique_reach), 0) AS total_reach
        FROM incoming_engagements
    ),
    with_users AS (
        SELECT
            us.*,
            COALESCE(mu.score, 0) AS x_score,
            COALESCE(mu.x_username, '') AS combined_username,
            ups.average_p90
        FROM user_stats us
        LEFT JOIN mindshare_test.mindshare_user mu ON us.x_id = mu.x_id
        LEFT JOIN user_p90_stats ups ON us.x_id = ups.x_id
    )
    SELECT
        COALESCE(et.total_unique_engaged_users, 0) AS total_unique_engaged_users,
        pt.total_post_count,
        pt.total_quote_post_count,
        pt.total_post_view_count,
        pt.total_quote_post_view_count,
        (pt.total_post_view_count + pt.total_quote_post_view_count) AS total_view_count,
        wu.x_id::text,
        wu.combined_username::text AS x_username,
        wu.x_score::numeric,
        (wu.internal_engagements + COALESCE(et.replies_received, 0))::bigint AS engagements,
        wu.likes::bigint,
        COALESCE(et.replies_received, 0)::bigint AS replies,
        wu.retweets::bigint,
        CASE WHEN COALESCE(et.replies_received, 0) = 0 THEN 0
             ELSE ROUND(wu.likes::numeric / et.replies_received, 2)
        END::numeric AS like_to_reply_ratio,
        COALESCE(et.total_reach, 0)::numeric AS reach,
        COALESCE(fur.total_unique_reach, 0)::numeric AS unique_reach,
        pt.first_post_date,
        pt.last_post_date,
        COALESCE(et.self_replies_count, 0)::bigint AS self_replies,
        wu.average_p90
    FROM project_totals pt
    LEFT JOIN engagement_totals et ON true
    CROSS JOIN final_unique_reach fur
    JOIN with_users wu ON true
    $q$,
    target_user_id,
    COALESCE(limit_cnt::text, 'NULL'),
    target_user_id, target_user_id,
    target_user_id, target_user_id,
    target_user_id, target_user_id
    );

    RETURN QUERY EXECUTE sql_query;
END;
$function$;
