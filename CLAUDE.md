# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not an application repo** — it is a collection of PostgreSQL DDL/PLpgSQL
artifacts (`Schemas/`) for a Twitter/X "Mindshare" social-engagement scoring
system, kept here to assess their **feasibility on CockroachDB** (hence the repo
name). The `main.py` / `pyproject.toml` is a `uv`-managed Python stub with no real
logic; the substance of the repo is the SQL under `Schemas/`.

When working here, the primary task is reading, porting, or rewriting Postgres
SQL so it runs on CockroachDB. Assume any given `.sql` file is **Postgres source
of truth** unless told otherwise, and flag Postgres-only constructs (see below).

## Commands

The Python stub:

```bash
uv run main.py        # runs the placeholder entrypoint
uv sync               # install/resolve deps (currently none)
```

Python is pinned to 3.12 (`.python-version`). There is no test suite, linter, or
build step configured.

The SQL files are not wired into any migration runner — they are applied manually
against a database (`psql` / `cockroach sql`). There is no schema-migration tooling
in the repo.

## Schema layout (the real architecture)

Three Postgres schemas, each a top-level folder under `Schemas/`:

- **`mindshare`** (`Schemas/Mindshare/Tables/`) — base tables ingested from X/Twitter:
  - `nucleus_post` / `mindshare_post` — tracked-project posts, **LIST-partitioned by
    `project_keyword`**, PK `(project_keyword, post_created_at, post_id)`. Reply/quote/
    retweet/post booleans are `GENERATED ALWAYS ... STORED` from the `*_post_id` columns.
  - `user_post` — a user's full post history (not project-partitioned).
  - `nucleus_user` / `mindshare_user` — X accounts with a `score` and JSONB
    `adjustment_config`. (Note: `mindshare_user.sql` currently contains a copy of the
    `mindshare_post` DDL — likely a paste error; verify before relying on it.)

- **`mindshare_score`** (`Schemas/Mindshare_score/`) — the scoring engine:
  - `contribution_scores` (per-project) and `global_contribution_scores` (cross-project)
    store computed reply-contribution scores with `active_multipliers numeric[]`.
  - `Fuctions/` (note the misspelled folder name) holds the PLpgSQL functions and
    procedures: decay-score calculation, leaderboards, engagement-feature
    materialized-view builders, unique-reach / engagement-clustering metrics.

- **`analytics`** (`Schemas/Analytics/`) — read/reporting layer:
  - `materialized views/` holds per-project `mv_engagement__<keyword>` materialized
    views plus `mv_user_posts_engagement`.
  - `functions/` builds those views and exposes per-user / per-post analytics.

### How the pieces fit

`mindshare.*` base tables → `analytics` materialized views (`mv_engagement__*`,
`mv_user_posts_engagement`) → `mindshare_score` feature views
(`mv_user_posts_engagement_features`) and scoring functions →
`contribution_scores` tables and the leaderboard functions that read them.
Many functions are **per-project**: they build a view name dynamically from the
keyword, e.g. `'mv_engagement_' || lower(replace(projectname,' ','_'))`, and run it
via `EXECUTE format(...)`. When adding a project you generally materialize a new
`mv_engagement__<keyword>` view rather than changing function code.

### Recurring patterns to preserve

- **Per-project dynamic SQL**: leaderboard/analytics functions assemble query text
  with `format(... %L / %s ...)` and `EXECUTE`. Parameter maps are documented in
  header comments inside each function — keep them in sync when editing.
- **Stateful cursor loops**: `calculate_decay_scores` walks replies ordered by
  `(user_x_id, post_created_at)` in a `FOR rec IN ... LOOP`, maintaining rolling
  penalty arrays and resetting state per replier. It is order-dependent — preserve
  the `ORDER BY`.
- The `mindshare_post` boolean flags (`is_post`, `is_reply`, `is_quote`, `is_retweet`)
  are generated columns; never insert into them, and filter on them rather than
  re-deriving from `*_post_id` fields.

## CockroachDB porting watch-list

These Postgres constructs appear in the schemas and need attention when targeting
CockroachDB — check current CRDB support before assuming they work:

- `PARTITION BY LIST` table partitioning (CRDB partitioning is an enterprise/zone
  concept, syntactically different from Postgres declarative partitioning).
- `GENERATED ALWAYS AS (...) STORED` computed columns.
- `CREATE MATERIALIZED VIEW` + `REFRESH` (CRDB materialized views do not support
  `WITH DATA`/incremental refresh the same way; no `CONCURRENTLY`).
- `PERCENTILE_CONT(...) WITHIN GROUP`, window `RANGE BETWEEN ... interval FOLLOWING`,
  `DISTINCT ON`, and array types (`numeric[]`, `_numeric`).
- PLpgSQL `RECORD` cursor loops and `EXECUTE format(...)` dynamic SQL.

When porting a file, keep the original Postgres version intact and note divergences;
the point of this repo is to record what does and does not translate.
