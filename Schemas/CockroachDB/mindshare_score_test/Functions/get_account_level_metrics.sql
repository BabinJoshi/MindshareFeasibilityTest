-- mindshare_score_test.get_account_level_metrics
-- CockroachDB port:
--   analytics.  → analytics_test.
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.

CREATE OR REPLACE FUNCTION mindshare_score_test.get_account_level_metrics(startdate bigint, enddate bigint, projectname text)
 RETURNS TABLE(handle text, username character varying, score numeric, post_count bigint, smart_reach numeric, mindshare_score numeric, keyword_unique_reach numeric, account_unique_reach numeric, account_keyword_unique_reach_ratio numeric)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    sql_query TEXT;
    view_name TEXT := 'mv_engagement_' || LOWER(REPLACE(projectname, ' ', '_'));
BEGIN

sql_query := FORMAT($q$

WITH

engagements AS (
    SELECT
        root_post_id,
        root_user_id,
        root_username,
        engaged_user_id,
        engaged_user_score,
        is_engaged_reply,
        root_favorite_count,
        root_reply_count
    FROM analytics_test.%I
    WHERE engaged_tweet_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND root_tweet_created_at    BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND is_root_reply   = FALSE
      AND is_engaged_reply = TRUE
      AND root_user_id   != engaged_user_id
),

keyword_unique_engagements AS (
    SELECT DISTINCT ON (root_user_id, engaged_user_id)
        root_user_id,
        root_username,
        engaged_user_score
    FROM engagements
),

keyword_unique_reach_cte AS (
    SELECT
        root_user_id,
        root_username,
        SUM(engaged_user_score)::NUMERIC AS keyword_unique_reach
    FROM keyword_unique_engagements
    GROUP BY root_user_id, root_username
),

user_posts AS (
    SELECT
        post_id   AS root_post_id,
        user_x_id AS root_user_id
    FROM mindshare_test.user_post
    WHERE post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND (is_post = TRUE OR (is_quote = TRUE AND is_reply = FALSE))
),

all_engagements AS (
    SELECT
        up.root_user_id,
        e.user_x_id AS engaged_user_id,
        u.score     AS engaged_user_score
    FROM user_posts up
    JOIN mindshare_test.user_post e
        ON e.replied_post_id = up.root_post_id
    JOIN mindshare_test.mindshare_user u
        ON u.x_id = e.user_x_id
    WHERE e.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND e.user_x_id != up.root_user_id
),

unique_engagers AS (
    SELECT
        root_user_id,
        engaged_user_id,
        MAX(engaged_user_score) AS max_engager_score
    FROM all_engagements
    GROUP BY root_user_id, engaged_user_id
),

account_unique_reach_cte AS (
    SELECT
        root_user_id,
        SUM(max_engager_score)::NUMERIC AS account_unique_reach
    FROM unique_engagers
    GROUP BY root_user_id
),

unique_engagements_per_post AS (
    SELECT DISTINCT ON (root_post_id, engaged_user_id)
        root_post_id,
        root_user_id,
        root_username,
        engaged_user_score,
        root_favorite_count,
        root_reply_count
    FROM engagements
),

post_metrics AS (
    SELECT
        ue.root_post_id,
        ue.root_user_id,
        ue.root_username,
        COUNT(*)                          AS unique_engagers,
        SUM(ue.engaged_user_score)::NUMERIC AS post_unique_reach,
        MAX(ue.root_favorite_count)::INT  AS total_likes
    FROM unique_engagements_per_post ue
    GROUP BY ue.root_post_id, ue.root_user_id, ue.root_username
),

replies AS (
    SELECT
        root_post_id,
        COUNT(*) FILTER (WHERE is_engaged_reply) AS replies_on_post
    FROM engagements
    GROUP BY root_post_id
),

valid_posts AS (
    SELECT
        pm.root_post_id AS post_id,
        pm.root_user_id AS handle,
        pm.root_username AS username
    FROM post_metrics pm
    JOIN replies r
        ON r.root_post_id = pm.root_post_id
    JOIN mindshare_test.mindshare_post p
        ON p.post_id       = pm.root_post_id
       AND p.project_keyword = $3
),

post_count_cte AS (
    SELECT
        handle,
        username,
        COUNT(*) AS post_count
    FROM valid_posts
    GROUP BY handle, username
),

unique_contributions AS (
    SELECT DISTINCT ON (cs.original_post_id, cs.replier_x_id)
        vp.handle,
        cs.contribution_score
    FROM mindshare_score_test.contribution_scores cs
    JOIN valid_posts vp
        ON vp.post_id = cs.original_post_id
    WHERE cs.post_created_at BETWEEN to_timestamp($1) AND to_timestamp($2)
      AND cs.replier_x_id <> cs.original_author_x_id
    ORDER BY
        cs.original_post_id,
        cs.replier_x_id,
        cs.post_created_at ASC
),

smart_reach_cte AS (
    SELECT
        handle,
        SUM(contribution_score)::NUMERIC AS smart_reach
    FROM unique_contributions
    GROUP BY handle
)

SELECT
    k.root_user_id                                          AS handle,
    k.root_username                                         AS username,
    u.score,
    COALESCE(pc.post_count,  0)                             AS post_count,
    COALESCE(sr.smart_reach, 0)                             AS smart_reach,
    ROUND(
        COALESCE(sr.smart_reach, 0)
        + (COALESCE(pc.post_count, 0) * COALESCE(u.score, 0)),
        3
    )                                                       AS mindshare_score,
    COALESCE(k.keyword_unique_reach, 0)                     AS keyword_unique_reach,
    COALESCE(a.account_unique_reach,  0)                    AS account_unique_reach,
    CASE
        WHEN COALESCE(k.keyword_unique_reach, 0) = 0 THEN NULL
        ELSE ROUND(
            COALESCE(a.account_unique_reach, 0) / k.keyword_unique_reach,
            2
        )
    END                                                     AS account_keyword_unique_reach_ratio

FROM keyword_unique_reach_cte k
LEFT JOIN account_unique_reach_cte a
    ON  a.root_user_id   = k.root_user_id
LEFT JOIN post_count_cte pc
    ON  pc.handle        = k.root_user_id
LEFT JOIN smart_reach_cte sr
    ON  sr.handle        = k.root_user_id
LEFT JOIN mindshare_test.mindshare_user u
    ON  u.x_id           = k.root_user_id

ORDER BY mindshare_score DESC NULLS LAST

$q$, view_name);

RETURN QUERY EXECUTE sql_query USING startdate, enddate, projectname;

END;
$function$;
