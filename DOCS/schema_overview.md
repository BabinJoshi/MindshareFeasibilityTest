# Mindshare System — Schema Reference

## Overview

The Mindshare system scores Twitter/X social engagement for tracked projects.
It is split across three PostgreSQL schemas that form a three-layer pipeline:

```
mindshare (base ingestion)
    │
    ├── analytics (engagement materialized views)
    │       │
    │       └── mindshare_score (scoring engine)
    │               │
    │               └── leaderboard / analytics API functions
```

---

## Execution Sequence (fresh database)

```
 1. Create schemas: mindshare, analytics, mindshare_score
 2. Create mindshare tables (admin → mindshare_project → mindshare_post / user_post / etc.)
 3. Ingest data into mindshare tables (done by the application)
 4. Create mindshare_score tables: contribution_scores, global_contribution_scores
 5. Register analytics procedures and functions
 6. CALL analytics.create_user_posts_engagement_view()
    → creates analytics.mv_user_posts_engagement
 7. CALL analytics.run_create_engagement_views()
    → creates analytics.mv_engagement_<keyword> per project
    (or apply Schemas/Analytics/materialized views/materialzed_views.sql directly)
 8. Register all mindshare_score functions
 9. CALL mindshare_score.calculate_all_decay_scores()
    → populates contribution_scores from mindshare_post data
10. CALL mindshare_score.calculate_all_global_decay_scores()
    → populates global_contribution_scores from user_post data
11. CALL mindshare_score.create_user_posts_engagement_features_view()
    → creates mindshare_score.mv_user_posts_engagement_features
12. CALL mindshare_score.create_all_engagement_clustering_views()
    → creates mindshare_score.mv_engagement_features_<keyword> per project
13. Query leaderboard / analytics functions
```

---

## Schema 1: `mindshare`

Base ingestion layer. Contains all raw data from X/Twitter.

### Tables

#### `mindshare.admin`
Admin user accounts for the platform.

| Column | Type | Notes |
|--------|------|-------|
| username | varchar(255) | PK |
| hashed_password | varchar(255) | |
| is_active | bool | default true |
| created_at / updated_at | timestamptz | |

---

#### `mindshare.api_key`
API keys issued by admin users.

| Column | Type | Notes |
|--------|------|-------|
| id | uuid | PK |
| key | varchar(255) | UNIQUE |
| name | varchar(255) | |
| created_by_admin | varchar(255) | FK → admin.username |
| expires_at | timestamptz | nullable |
| is_active | bool | default true |
| roles | varchar[] | default `{}` |
| created_at / updated_at | timestamptz | |

Indexes: `expires_at`, `is_active`, unique `key`.

---

#### `mindshare.mindshare_project`
Project definitions (e.g. "quipnetwork", "Pact_Swap").

| Column | Type | Notes |
|--------|------|-------|
| project_name | varchar(100) | PK |
| description | text | |
| start_ts / end_ts | int8 | epoch seconds, nullable |
| valid_keywords | jsonb | |
| status | bool | default true |
| track_tweets | bool | default true |
| thumbnail_url | varchar(500) | nullable |
| created_at / updated_at | timestamptz | |

---

#### `mindshare.mindshare_post`
All posts tracked for specific projects. **LIST-partitioned by `project_keyword`** in Postgres (partition clause removed in CRDB version).

| Column | Type | Notes |
|--------|------|-------|
| post_id | text | PK component |
| project_keyword | text | PK component, partition key |
| user_x_id | text | |
| full_text | text | |
| retweeted_post_id / replied_post_id / quoted_post_id / root_post_id | text | nullable |
| is_retweet | bool | GENERATED: `retweeted_post_id IS NOT NULL` |
| is_reply | bool | GENERATED: `replied_post_id IS NOT NULL` |
| is_quote | bool | GENERATED: `quoted_post_id IS NOT NULL` |
| is_post | bool | GENERATED: all three NULL |
| view_count / reply_count / retweet_count / quote_count / favorite_count | int4 | |
| post_created_at | timestamptz | PK component |
| sentiment_score | numeric(3,2) | nullable |
| sentiment_label | varchar(20) | nullable |
| entities | jsonb | nullable |
| content_score | numeric(5,2) | nullable |
| created_at / updated_at | timestamptz | |

PK: `(project_keyword, post_created_at, post_id)`.
Indexes: `post_created_at`, `post_id`, `(user_x_id, post_created_at)`.

> **Never insert into generated columns** (`is_post`, `is_reply`, `is_quote`, `is_retweet`). Filter on them rather than re-deriving.

---

#### `mindshare.nucleus_post`
Same shape as `mindshare_post` plus `is_reply_fetched bool`. Tracks posts for the Nucleus product. Also LIST-partitioned in Postgres.

---

#### `mindshare.mindshare_user`
X/Twitter account profiles with aggregate score.

| Column | Type | Notes |
|--------|------|-------|
| x_id | varchar(50) | PK |
| x_username | varchar(255) | |
| display_name | varchar(255) | |
| score | numeric(10,2) | global influence score |
| avatar_url | varchar(1000) | |
| adjustment_config | jsonb | |
| followers_count | int4 | |
| verified | bool | default false |
| last_score_fetched_at | timestamptz | nullable |
| created_at / updated_at | timestamptz | |

Index: `x_username`.

---

#### `mindshare.nucleus_user`
Same shape as `mindshare_user` minus `last_score_fetched_at`.

---

#### `mindshare.user`
Another user table (same columns as `nucleus_user`).

---

#### `mindshare.user_post`
Full post history for users (not project-scoped, no partitioning).

Same columns as `mindshare_post` minus `sentiment_*` / `content_score` / `latest_reply_at`. PK: `(post_created_at, post_id)`. Has `project_keyword varchar(255)` nullable.

Indexes: `(replied_post_id, post_created_at)`, `root_post_id`, `(user_x_id, post_created_at)`, `post_created_at`, `post_id`, `quoted_post_id`, `replied_post_id`.

---

#### `mindshare.project_post_cap`
Controls the post cap (max posts per user per period) for each project's leaderboard.

| Column | Type | Notes |
|--------|------|-------|
| id | serial4 | PK |
| project_keyword | text | |
| leaderboard_type | text | CHECK: `'global'` or `'private'` |
| post_cap | int4 | default 5 |
| cap_period | text | CHECK: `'day'`, `'week'`, `'month'`, `'none'` |
| cap_start_date | timestamptz | nullable |
| project_start_date | timestamptz | nullable |

UNIQUE: `(project_keyword, leaderboard_type)`.

---

#### `mindshare.project_private_kol`
Allowlist of KOLs (Key Opinion Leaders) for private leaderboards.

| Column | Type | Notes |
|--------|------|-------|
| id | serial4 | PK |
| project_name | varchar(100) | FK → mindshare_project.project_name |
| twitter_user_id | varchar(100) | |
| created_at / updated_at | timestamptz | |

UNIQUE: `(project_name, twitter_user_id)`.

---

#### `mindshare.post_content_signal`
AI-generated content quality signals per post. LIST-partitioned in Postgres.

| Column | Type | Notes |
|--------|------|-------|
| post_id | text | PK component |
| project_keyword | text | PK component |
| post_created_at | timestamptz | PK component |
| relevance / context_depth / meme_communication_value / visual_information_density / human_signal / project_focus / mention_farming_risk / ai_generated_probability | numeric(5,2) | all nullable |
| sentiment | numeric(4,2) | nullable |
| reason | text | nullable |
| created_at / updated_at | timestamptz | |

---

#### `mindshare.contamination_cleanup_20260526`
Temporary cleanup table (no constraints, all nullable).

---

## Schema 2: `analytics`

Engagement materialized views and user-facing analytics functions.

### Materialized Views

#### `analytics.mv_user_posts_engagement`
Created by `analytics.create_user_posts_engagement_view()`. Tracks engagement
(replies, quotes, retweets) against root posts from `user_post`.

Columns: `root_post_id`, `root_user_id`, `root_username`, `root_tweet_created_at`, `is_root_post`, `is_root_quote`, `is_root_reply`, `root_favorite_count`, `root_reply_count`, `engaged_tweet_id`, `engaged_user_id`, `is_engaged_reply`, `is_engaged_quote`, `is_engaged_repost`, `engaged_tweet_created_at`, `engaged_user_score`.

Indexes: `root_post_id`, `root_user_id`.

---

#### `analytics.mv_engagement_<keyword>`
One per project, created by `analytics.create_engagement_view(project_name)` (called via `run_create_engagement_views`) or by applying the static DDL. Same columns as `mv_user_posts_engagement` but sourced from `mindshare.mindshare_post` filtered by `project_keyword`.

Named examples: `mv_engagement__technotainment`, `mv_engagement_quipnetwork`, `mv_engagement_pact_swap`.

Indexes: `root_post_id`, unique `engaged_tweet_id`, `engaged_user_id`.

---

### Functions / Procedures

#### `analytics.create_user_posts_engagement_view()` — PROCEDURE
Drops and recreates `analytics.mv_user_posts_engagement` from `mindshare.user_post`.

**Depends on:** `mindshare.user_post`, `mindshare.mindshare_user`

---

#### `analytics.create_engagement_view(project_name text)` — PROCEDURE
Drops and recreates `analytics.mv_engagement_<keyword>` for a given project.
(Defined separately; called by `run_create_engagement_views`.)

**Depends on:** `mindshare.mindshare_post`, `mindshare.mindshare_user`

---

#### `analytics.run_create_engagement_views()` — PROCEDURE
Loops through all projects in `mindshare.mindshare_project` and calls `create_engagement_view`.

**Depends on:** `mindshare.mindshare_project`, `analytics.create_engagement_view`

---

#### `analytics.refresh_engagement_views_all()` — PROCEDURE
Refreshes all `mv_engagement_*` materialized views by iterating `mindshare.mindshare_project`.

**Depends on:** `mindshare.mindshare_project`, all `analytics.mv_engagement_*` views

---

#### `analytics.get_user_analytics(target_user_id text, limit_cnt integer)` — FUNCTION
Returns aggregated analytics for a single user: post counts, view counts, likes, replies, retweets, reach, unique reach, P90 duration, and self-replies. Optional `limit_cnt` caps per-user post history.

**Returns:** single row of aggregated metrics.  
**Depends on:** `mindshare.user_post`, `mindshare.mindshare_user`, `mindshare_score.mv_user_posts_engagement_features`

---

#### `analytics.get_all_users_analytics(limit_per_user integer)` — FUNCTION
Same as `get_user_analytics` but across all users. Uses `global_contribution_scores` for smart reach.

**Returns:** one row per user.  
**Depends on:** `mindshare.user_post`, `mindshare.mindshare_user`, `mindshare_score.global_contribution_scores`, `mindshare_score.mv_user_posts_engagement_features`

---

#### `analytics.get_user_posts_analytics(p_user_id, startdate, enddate)` — FUNCTION (SQL)
Per-post analytics for a user within a time window. Uses `user_post` + `global_contribution_scores` + `mv_user_posts_engagement_features`. Returns farming/botting flags per post.

**Returns:** one row per post.  
**Depends on:** `mindshare.user_post`, `mindshare.mindshare_user`, `mindshare_score.global_contribution_scores`, `mindshare_score.mv_user_posts_engagement_features`

---

#### `analytics.get_v2_user_posts_analytics(user_id, projectname, startdate, enddate)` — FUNCTION
Project-scoped per-post analytics. Uses dynamic `analytics.mv_engagement_<keyword>` and `mindshare_score.mv_engagement_features_<keyword>`. Returns content scores + engagement clustering.

**Returns:** one row per post.  
**Depends on:** `mindshare.mindshare_post`, `mindshare.mindshare_user`, `analytics.mv_engagement_<keyword>`, `mindshare_score.contribution_scores`, `mindshare_score.mv_engagement_features_<keyword>`

---

## Schema 3: `mindshare_score`

Scoring engine. Computes decay-adjusted contribution scores and leaderboard rankings.

### Tables

#### `mindshare_score.contribution_scores`
Per-project reply contribution scores with rolling decay applied.

| Column | Type | Notes |
|--------|------|-------|
| project_keyword | text | |
| reply_post_id | text | |
| replier_x_id | text | |
| original_post_id | text | |
| original_author_x_id | text | |
| post_created_at | timestamptz | |
| replier_base_score | numeric | user's score at calculation time |
| effective_score | numeric | base × active penalties BEFORE this reply |
| contribution_score | numeric | final score for this reply |
| active_multipliers | numeric[] | rolling window penalty snapshot |
| reply_number | int4 | global reply sequence for this replier |
| local_reply_count | int4 | replies to this specific author in window |
| decay_type | text | `FIRST_REPLY`, `LOCAL_DECAY`, or `GLOBAL_DECAY` |

Indexes: `(project_keyword, original_author_x_id)`, `(project_keyword, replier_x_id)`, `original_post_id`, `post_created_at`, `reply_post_id`.

---

#### `mindshare_score.global_contribution_scores`
Same as `contribution_scores` but without `project_keyword`. Computed from `user_post` (cross-project).

---

### Materialized Views

#### `mindshare_score.mv_engagement_features_<keyword>`
Per-project engagement clustering features. Created by `create_engagement_clustering_features_view(keyword)`.

Columns: `root_post_id`, `root_user_id`, `root_username`, `root_tweet_created_at`, `total_engagements`, `burst_concentration`, `duration_days_p90`, `cross_post_overlap`, `prev_post_overlap`, `coordinated_burst`, `farming_score`.

Unique index on `root_post_id`.

---

#### `mindshare_score.mv_user_posts_engagement_features`
Global (cross-project) version of the above. Created by `create_user_posts_engagement_features_view()`.

---

### Functions / Procedures

#### Decay Score Calculation

##### `mindshare_score.calculate_decay_scores(p_project_keyword, p_reset_interval)` — FUNCTION
Core decay algorithm. Walks all replies for a project ordered by `(user_x_id, post_created_at)`, maintaining a rolling 30-day penalty window per replier. Inserts one row per reply into `contribution_scores`.

**Decay rules:**
- First reply to any author in window → `FIRST_REPLY`, multiplier = 1.0
- 2nd+ reply to the same author in window → `LOCAL_DECAY`, multiplier = 0.50
- Reply to a different author, but replier has prior replies → `GLOBAL_DECAY`, multiplier = 0.90

**Depends on:** `mindshare.mindshare_post`, `mindshare.mindshare_user`  
**Writes to:** `mindshare_score.contribution_scores`

---

##### `mindshare_score.calculate_all_decay_scores(p_reset_interval)` — FUNCTION
TRUNCATES `contribution_scores`, loops through all projects with replies, calls `calculate_decay_scores` for each, then creates indexes.

---

##### `mindshare_score.calculate_global_decay_scores(p_project_keyword, p_reset_interval)` — FUNCTION
Same algorithm as `calculate_decay_scores` but sources from `user_post` and writes to `global_contribution_scores`. (`p_project_keyword` parameter is unused in the function body — it iterates all users.)

---

##### `mindshare_score.calculate_all_global_decay_scores(p_reset_interval)` — FUNCTION
TRUNCATES `global_contribution_scores` and calls `calculate_global_decay_scores`.

---

#### Engagement Clustering Views

##### `mindshare_score.create_engagement_clustering_features_view(project_keyword)` — PROCEDURE
Creates `mindshare_score.mv_engagement_features_<keyword>` via dynamic `EXECUTE format(...)`. Computes:
- **burst_concentration**: fraction of total engagements falling in the peak 60-min window
- **duration_days_p90**: P90 engagement timestamp minus first engagement (days)
- **cross_post_overlap**: % of engagers who also engaged with recent prior posts
- **coordinated_burst**: burst_concentration × capped recurrence ratio
- **farming_score**: weighted composite (0–100)

**CRDB note:** Uses `PERCENTILE_CONT WITHIN GROUP` (requires CRDB ≥ 23.1) and `RANGE BETWEEN CURRENT ROW AND 3600 FOLLOWING` with numeric ORDER BY (requires CRDB ≥ 22.2).

**Depends on:** `analytics.mv_engagement_<keyword>`

---

##### `mindshare_score.test_create_engagement_clustering_features_view(project_keyword)` — PROCEDURE
Alternative, optimized version of the above using explicit cross-post overlap joins instead of window functions. Same output schema.

---

##### `mindshare_score.create_user_posts_engagement_features_view()` — PROCEDURE
Global (cross-project) version. Creates `mv_user_posts_engagement_features` from `analytics.mv_user_posts_engagement`. Uses interval-based RANGE window (`'59 minutes 59 seconds'::interval FOLLOWING`).

**CRDB note:** Uses interval-based RANGE frame; requires CRDB ≥ 22.2.

---

##### `mindshare_score.calculate_all_engagement_clustering_views()` — PROCEDURE
Loops through all project keywords in `mindshare.mindshare_post` and calls `create_engagement_clustering_features_view`.

---

##### `mindshare_score.refresh_engagement_features_views_all()` — PROCEDURE
Refreshes all `mv_engagement_features_*` views. If a view doesn't exist, recreates it. Uses `CONCURRENTLY` in Postgres (removed in CRDB version). Queries `pg_matviews` to check existence.

**CRDB note:** `REFRESH MATERIALIZED VIEW CONCURRENTLY` not supported — removed.

---

#### Analytics Functions (project-scoped)

##### `mindshare_score.get_post_level_metrics(startdate, enddate, projectname)` — FUNCTION
Per-post engagement metrics using `analytics.mv_engagement_<keyword>`. Returns unique reach, smart reach, impressions, likes, replies, farming/botting flags.

**Depends on:** `analytics.mv_engagement_<keyword>`, `mindshare.mindshare_post`, `mindshare.mindshare_user`, `mindshare_score.contribution_scores`

---

##### `mindshare_score.get_account_level_metrics(startdate, enddate, projectname)` — FUNCTION
Account-level aggregation: keyword unique reach, account unique reach, smart reach, mindshare score, ratio.

**Depends on:** `analytics.mv_engagement_<keyword>`, `mindshare.user_post`, `mindshare.mindshare_user`, `mindshare_score.contribution_scores`

---

##### `mindshare_score.get_post_engagement_ratios(startdate, enddate, projectname)` — FUNCTION
Post-level reach-to-impression, like-to-reply, and unique-engager-score ratios.

---

##### `mindshare_score.get_account_and_keyword_unique_reach_ratio(startdate, enddate, projectname)` — FUNCTION
Compares keyword-scoped unique reach (from MV) against account-wide unique reach (from `user_post`).

---

##### `mindshare_score.get_unique_reach_increase(startdate, enddate, projectname)` — FUNCTION
Per-post audience expansion analysis: new vs. repeat engagers, cumulative expansion unique reach.

**Depends on:** `mindshare.mindshare_post`, `mindshare.mindshare_user`, `analytics.mv_engagement_<keyword>`

---

##### `mindshare_score.get_user_level_unique_reach_increase_flag(startdate, enddate, projectname)` — FUNCTION
User-level farming flag computed from `get_unique_reach_increase`: early spike ratio, growth slope, growth variability, max spike ratio. Returns `farming_flag` = `'potential_engagement_farming'` or `'organic'`.

**Depends on:** `mindshare_score.get_unique_reach_increase`

---

##### `mindshare_score.get_engagement_clustering(start_ts, end_ts, project_keyword)` — FUNCTION
Returns engagement clustering metrics from `mindshare_score.mv_engagement_features_<keyword>`.

---

##### `mindshare_score.get_single_post_smart_reach(target_post_id, projectname, startdate, enddate)` — FUNCTION
Engagement metrics for a single post with optional date filters.

---

##### `mindshare_score.get_v2_analytics(projectname, startdate, enddate, sort_key, private_user_ids)` — FUNCTION
Comprehensive project analytics. Returns project-level totals + per-user JSON array (up to 1100 users). Sort keys: `MOST_POSTS`, `MOST_VIEWS`, `UNIQUE_ENGAGERS`, `UNIQUE_REACH`, `REACH`, `ENGAGEMENTS`, `MINDSHARE_SCORE`, `SMART_REACH`.

**Depends on:** `mindshare.mindshare_post`, `analytics.mv_engagement_<keyword>`, `mindshare_score.mv_engagement_features_<keyword>`, `mindshare_score.contribution_scores`, `mindshare.mindshare_user`

---

##### `mindshare_score.get_mindshare_leaderboard(startdate, enddate, projectname)` — FUNCTION
Global leaderboard. Reads `project_post_cap` for cap configuration (default: 5 posts/week with anchor-based bucketing). Scores = smart_reach × content_score + post_count × user_score + reply_count × user_score/100.

**Depends on:** `analytics.mv_engagement_<keyword>`, `mindshare_score.contribution_scores`, `mindshare.mindshare_post`, `mindshare.mindshare_user`, `mindshare.project_post_cap`

---

##### `mindshare_score.get_private_mindshare_leaderboard(startdate, enddate, projectname, p_exclude_list, p_private_user_list)` — FUNCTION
Private leaderboard variant with allowlist and exclusion-list filtering. Reads `leaderboard_type = 'private'` row from `project_post_cap`.

---

#### Analytics Functions (global / cross-project)

##### `mindshare_score.get_global_post_level_metrics(startdate, enddate)` — FUNCTION
Post-level metrics from `user_post` (no MV dependency).

---

##### `mindshare_score.get_global_account_level_metrics(startdate, enddate)` — FUNCTION
Account-level metrics from `user_post`.

---

##### `mindshare_score.get_global_post_engagement_ratios(startdate, enddate)` — FUNCTION
Post engagement ratios from `user_post`.

---

##### `mindshare_score.get_global_unique_reach_increase(startdate, enddate)` — FUNCTION
Audience expansion analysis from `user_post`.

---

##### `mindshare_score.get_global_user_level_unique_reach_increase_flag(startdate, enddate)` — FUNCTION
Calls `get_global_unique_reach_increase` to compute user-level farming flags.

---

##### `mindshare_score.get_user_post_engagement_clustering(p_user_id, start_ts, end_ts)` — FUNCTION
Queries `mindshare_score.mv_user_posts_engagement_features` for a user.

---

##### `mindshare_score.get_user_engagement_quality(p_user_ids text[])` — FUNCTION
Analyses last 50 posts per user from `nucleus_post`. Returns unique reach, farming flag count, botting flag count.

---

##### `mindshare_score.get_post_from_user_id(p_user_x_id, project_name, table_name)` — FUNCTION
Queries posts from `mindshare_post`, `user_post`, or `nucleus_post` depending on `table_name` parameter.

---

##### `mindshare_score.refresh_user_post_engagement_views()` — PROCEDURE
Refreshes both `analytics.mv_user_posts_engagement` and `mindshare_score.mv_user_posts_engagement_features`.

---

## CockroachDB Porting Notes

| Feature | Postgres | CockroachDB Status |
|---------|----------|--------------------|
| `PARTITION BY LIST` | mindshare_post, nucleus_post, post_content_signal | **Not supported** (declarative partitioning syntax differs). Removed in CRDB DDL. |
| `CREATE INDEX ON ONLY` | Parent-only index on partitioned table | **Not supported**. Changed to `CREATE INDEX ON table`. |
| `_numeric` / `_varchar` type | DDL array shorthand | **Must use** `numeric[]` / `varchar[]`. |
| `GENERATED ALWAYS AS … STORED` | is_post, is_reply, etc. | **Supported** since CRDB v22.1. |
| `CREATE MATERIALIZED VIEW` | analytics, mindshare_score | **Supported**. No `CONCURRENTLY` on REFRESH. |
| `REFRESH MATERIALIZED VIEW CONCURRENTLY` | refresh procedures | **Not supported**. `CONCURRENTLY` removed. |
| `PERCENTILE_CONT … WITHIN GROUP` | clustering views, analytics | **Supported** since CRDB v23.1. Requires v23.1+. |
| `RANGE BETWEEN n FOLLOWING` (numeric) | burst window in clustering | **Supported** since CRDB v22.2. Requires v22.2+. |
| `RANGE BETWEEN interval FOLLOWING` | user posts clustering | **Supported** since CRDB v22.2. |
| `DISTINCT ON` | Throughout | **Supported**. |
| `FILTER (WHERE …)` in aggregates | Throughout | **Supported**. |
| `FORMAT('%I', …)` / `EXECUTE format(…)` | Dynamic SQL | **Supported**. |
| `TRUNCATE` inside PL/pgSQL | calculate_all_* | **Supported**. |
| `CREATE INDEX IF NOT EXISTS` in function | calculate_all_decay_scores | **Supported** (transactional DDL). |
| `clock_timestamp()` | calculate_all_* | **Supported**. Returns real current time. |
| `RAISE NOTICE / WARNING` | Throughout | **Supported** since CRDB v23+. |
| `jsonb_agg`, `jsonb_build_object` | get_v2_analytics | **Supported**. |
| `CROSS JOIN LATERAL` | get_v2_analytics | **Supported**. |
| `REGR_SLOPE` | get_*_unique_reach_increase_flag | **Supported** since CRDB v23+. |
| `pg_matviews` system catalog | refresh_features_views_all | **Supported** via `pg_catalog.pg_matviews`. |
| `SET LOCAL statement_timeout` | refresh_features_views_all | **Not supported** as `SET LOCAL` in procedures. Removed. |
| `TABLESPACE pg_default` | materialized views | **Not supported**. Removed. |
| Column alias list `FROM cte r (c1, c2…)` | static MVs pg_dump format | **Not supported**. Rewritten to use simple `FROM cte r`. |
