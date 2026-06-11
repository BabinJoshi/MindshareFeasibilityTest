-- mindshare_score_test.calculate_decay_scores
-- CockroachDB port:
--   mindshare.  → mindshare_test.
--   mindshare_score. → mindshare_score_test.
--
-- REWRITE: cursor loop → single INSERT … WITH … SELECT
--
-- WHY THE CURSOR WAS SLOW
--   The original PLpgSQL cursor did one INSERT per reply row. On CockroachDB every
--   INSERT is a distributed transaction (Raft consensus), so N rows = N round-trips.
--   Even a small project with a few thousand replies could take minutes.
--
-- WHY A SINGLE INSERT WORKS
--   decay_type for reply j depends only on counts of *raw* prior rows from the same
--   replier within the reset window — no recursive dependency on previously-computed
--   scores. That means the entire computation is two levels of lateral aggregates,
--   expressible as a single INSERT … SELECT with no looping.
--
--   active_product  = POWER(0.5, # prior LOCAL_DECAY in window)
--                   * POWER(0.9, # prior GLOBAL_DECAY in window)
--   (FIRST_REPLY rows contribute new_mult = 1.0 which is multiplicatively neutral)
--
-- PREVIOUS CRDB WORKAROUNDS (no longer needed — PLpgSQL body is now trivial)
--   • FOR rec IN query LOOP          → cursor was unimplemented
--   • RECORD variable                → was unimplemented (issue #114874)
--   • variable shadowing (i INT)     → was unimplemented (issue #117508)
--   • FOUND special variable         → was unimplemented

CREATE OR REPLACE FUNCTION mindshare_score_test.calculate_decay_scores(
    p_project_keyword TEXT,
    p_reset_interval  INTERVAL DEFAULT '30 days'::INTERVAL
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN

INSERT INTO mindshare_score_test.contribution_scores (
    project_keyword,
    reply_post_id,
    original_post_id,
    replier_x_id,
    original_author_x_id,
    post_created_at,
    replier_base_score,
    effective_score,
    contribution_score,
    active_multipliers,
    reply_number,
    local_reply_count,
    decay_type
)

WITH

-- ── Step 1 ──────────────────────────────────────────────────────────────────
-- Base join: reply posts + their original post + replier's base score.
-- Materialised so the join runs once and is reused by both lateral scans.
replies AS MATERIALIZED (
    SELECT
        p.project_keyword,
        p.post_id,
        op.post_id       AS original_post_id,
        p.user_x_id      AS replier_x_id,
        p.post_created_at,
        op.user_x_id     AS original_author_x_id,
        u.score::NUMERIC AS replier_base_score
    FROM mindshare_test.mindshare_post p
    INNER JOIN mindshare_test.mindshare_post op
        ON  p.replied_post_id = op.post_id
        AND p.project_keyword = op.project_keyword
    INNER JOIN mindshare_test.mindshare_user u
        ON p.user_x_id = u.x_id
    WHERE p.is_reply        = true
      AND p.replied_post_id IS NOT NULL
      AND p.project_keyword = p_project_keyword
),

-- ── Step 2 ──────────────────────────────────────────────────────────────────
-- For each reply, count prior active replies (total and to the same original
-- author). These raw counts fully determine decay_type — no scores needed yet.
prior_counts AS MATERIALIZED (
    SELECT
        r.project_keyword,
        r.post_id,
        r.original_post_id,
        r.replier_x_id,
        r.post_created_at,
        r.original_author_x_id,
        r.replier_base_score,
        ROUND(r.replier_base_score * 0.01, 2)                          AS min_floor,
        ROW_NUMBER() OVER (
            PARTITION BY r.replier_x_id
            ORDER BY     r.post_created_at, r.post_id
        )::INT                                                          AS reply_seq,
        agg.prior_n,
        agg.prior_local_count
    FROM replies r
    CROSS JOIN LATERAL (
        SELECT
            COUNT(*)                                                    AS prior_n,
            COUNT(*) FILTER (
                WHERE r2.original_author_x_id = r.original_author_x_id
            )                                                           AS prior_local_count
        FROM replies r2
        WHERE r2.replier_x_id    = r.replier_x_id
          AND r2.post_created_at  < r.post_created_at
          AND r2.post_created_at  > r.post_created_at - p_reset_interval
    ) agg
),

-- ── Step 3 ──────────────────────────────────────────────────────────────────
-- Derive decay_type and per-reply multiplier from the raw counts above.
-- Materialised because this result is scanned twice in Step 4.
with_dtype AS MATERIALIZED (
    SELECT
        *,
        CASE
            WHEN prior_n = 0            THEN 'FIRST_REPLY'::TEXT
            WHEN prior_local_count >= 1 THEN 'LOCAL_DECAY'::TEXT
            ELSE                             'GLOBAL_DECAY'::TEXT
        END                   AS dtype,
        CASE
            WHEN prior_n = 0            THEN 1.0::NUMERIC
            WHEN prior_local_count >= 1 THEN 0.50::NUMERIC
            ELSE                             0.90::NUMERIC
        END                   AS new_mult,
        prior_local_count + 1 AS local_seq
    FROM prior_counts
),

-- ── Step 4 ──────────────────────────────────────────────────────────────────
-- Single lateral scan computes both:
--   active_product    — product of PRIOR multipliers in window
--                       (FIRST_REPLY mults = 1.0, multiplicatively neutral)
--   active_multipliers — array snapshot stored in contribution_scores
--                        (prior + current reply, ordered by time)
with_product AS (
    SELECT
        r.project_keyword,
        r.post_id,
        r.original_post_id,
        r.replier_x_id,
        r.original_author_x_id,
        r.post_created_at,
        r.replier_base_score,
        r.min_floor,
        r.reply_seq,
        r.local_seq,
        r.dtype,
        pa.active_product,
        pa.active_multipliers
    FROM with_dtype r
    CROSS JOIN LATERAL (
        SELECT
            POWER(0.5::NUMERIC,
                COUNT(*) FILTER (
                    WHERE r2.post_created_at < r.post_created_at
                      AND r2.dtype = 'LOCAL_DECAY'
                )
            ) *
            POWER(0.9::NUMERIC,
                COUNT(*) FILTER (
                    WHERE r2.post_created_at < r.post_created_at
                      AND r2.dtype = 'GLOBAL_DECAY'
                )
            )                                                           AS active_product,
            ARRAY_AGG(r2.new_mult ORDER BY r2.post_created_at, r2.post_id)
                                                                        AS active_multipliers
        FROM with_dtype r2
        WHERE r2.replier_x_id    = r.replier_x_id
          AND r2.post_created_at  > r.post_created_at - p_reset_interval
          AND r2.post_created_at <= r.post_created_at
    ) pa
)

-- ── Final SELECT ─────────────────────────────────────────────────────────────
SELECT
    project_keyword,
    post_id                                                              AS reply_post_id,
    original_post_id,
    replier_x_id,
    original_author_x_id,
    post_created_at,
    replier_base_score,
    GREATEST(
        ROUND(replier_base_score * active_product, 2),
        min_floor
    )                                                                    AS effective_score,
    CASE dtype
        WHEN 'FIRST_REPLY' THEN
            GREATEST(ROUND(replier_base_score * active_product, 2), min_floor)
        WHEN 'LOCAL_DECAY' THEN
            GREATEST(ROUND(
                GREATEST(ROUND(replier_base_score * active_product, 2), min_floor) * 0.50,
            2), min_floor)
        ELSE
            GREATEST(ROUND(
                GREATEST(ROUND(replier_base_score * active_product, 2), min_floor) * 0.90,
            2), min_floor)
    END                                                                  AS contribution_score,
    active_multipliers,
    reply_seq                                                            AS reply_number,
    local_seq                                                            AS local_reply_count,
    dtype                                                                AS decay_type
FROM with_product;

END;
$function$;
