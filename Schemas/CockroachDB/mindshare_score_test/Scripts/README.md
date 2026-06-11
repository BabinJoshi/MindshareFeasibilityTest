# Decay-Score Scripts (CockroachDB + Polars)

Python/Polars port of the PLpgSQL decay-score engine
(`mindshare_score.calculate_decay_scores` / `calculate_all_decay_scores`),
reading from and writing to the CockroachDB `*_test` schemas:

| Reads                                                        | Writes                                       |
|--------------------------------------------------------------|----------------------------------------------|
| `mindshare_test.mindshare_post`, `mindshare_test.mindshare_user` | `mindshare_score_test.contribution_scores` |

Files:

- `decay_core.py` — shared vectorised algorithm (not run directly; see its
  docstring for the full algorithm trace and fidelity notes).
- `db_config.py` — loads the repo-root `.env` (python-dotenv) and builds the DSN.
- `calculate_decay_scores.py` — score **one project** by keyword.
- `calculate_all_decay_scores.py` — truncate + score **all projects** + create indexes.

## Prerequisites

1. **Python deps** — installed once from the repo root (`polars`, `psycopg2-binary`
   are already in `pyproject.toml`):

   ```bash
   cd /home/babin411/Nucleus/MindshareCockroachFeasibility
   uv sync
   ```

2. **Schema objects exist** in CockroachDB — the `*_test` schemas and tables from:
   - `Schemas/CockroachDB/00_create_schemas.sql`
   - `Schemas/CockroachDB/mindshare_test/Tables/mindshare_post.sql`, `mindshare_user.sql`
   - `Schemas/CockroachDB/mindshare_score_test/Tables/contribution_scores.sql`

3. **Credentials in `.env`** — the scripts load the repo-root `.env` via
   python-dotenv (`db_config.py`), so no manual `export` is needed:

   ```bash
   cp .env.example .env    # then edit .env with real credentials
   ```

   `.env` is git-ignored. Either set the full connection string:

   ```dotenv
   # local insecure cluster
   DATABASE_URL=postgresql://root@localhost:26257/defaultdb?sslmode=disable
   # CockroachDB Cloud (example shape)
   # DATABASE_URL=postgresql://<user>:<password>@<host>:26257/defaultdb?sslmode=verify-full
   ```

   or, if `DATABASE_URL` is unset, the discrete parts:

   ```dotenv
   DB_USER=root
   DB_PASSWORD=
   DB_HOST=localhost
   DB_PORT=26257
   DB_NAME=defaultdb
   DB_SSLMODE=disable
   ```

   Real environment variables take precedence over `.env` values, so a one-off
   `DATABASE_URL=... uv run ...` still overrides the file. With nothing set
   anywhere, the local-insecure default above is used.

## Run for a single project — `quip_network`

From the repo root:

```bash
uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_decay_scores.py quip_network
```

With a non-default reset interval (the rolling penalty window, default **30 days**):

```bash
uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_decay_scores.py quip_network 14
```

Arguments: `<project_keyword> [reset_interval_days]`. The keyword must match
`mindshare_post.project_keyword` exactly (e.g. `quip_network`).

Every stage is logged with its elapsed time, so slow steps are easy to spot:

```
10:42:01 INFO  ▶ connect: CockroachDB ...
10:42:02 INFO  ✔ connect: CockroachDB — 0.85 sec
10:42:02 INFO  ▶ TOTAL: 'quip_network' (reset window 30d) ...
10:42:02 INFO  ▶ fetch: replies for 'quip_network' ...
10:42:05 INFO    fetched 12345 reply rows
10:42:05 INFO  ✔ fetch: replies for 'quip_network' — 3.20 sec
10:42:05 INFO  ▶ load: rows → Polars DataFrame ...
10:42:05 INFO  ✔ load: rows → Polars DataFrame — 0.11 sec
10:42:05 INFO  ▶ compute: decay scores (12345 rows) ...
10:42:05 INFO  ▶ compute: pass 1 — prior counts → decay_type ...
10:42:06 INFO  ✔ compute: pass 1 — prior counts → decay_type — 0.42 sec
10:42:06 INFO  ▶ compute: pass 2 — log multipliers → active_product ...
10:42:06 INFO  ✔ compute: pass 2 — log multipliers → active_product — 0.55 sec
10:42:06 INFO  ▶ compute: final — effective/contribution scores ...
10:42:06 INFO  ✔ compute: final — effective/contribution scores — 0.02 sec
10:42:06 INFO  ✔ compute: decay scores (12345 rows) — 1.05 sec
10:42:06 INFO  ▶ insert: bulk write to contribution_scores ...
10:42:09 INFO  ✔ insert: bulk write to contribution_scores — 2.96 sec
10:42:09 INFO  ✔ TOTAL: 'quip_network' (reset window 30d) — 7.32 sec
10:42:09 INFO  Inserted 12345 rows for project 'quip_network'
```

(The all-projects script additionally logs `truncate:`, one
`project i/N: '<keyword>'` block per project, and a final `indexes:` stage.)

> **Note — no truncate.** Like the original per-project SQL function, this
> script only INSERTs. Re-running it for the same keyword duplicates rows, so
> clear previous results first:
>
> ```sql
> DELETE FROM mindshare_score_test.contribution_scores
> WHERE project_keyword = 'quip_network';
> ```

### Verify the results

```sql
SELECT decay_type, count(*), round(avg(contribution_score), 2) AS avg_score
FROM mindshare_score_test.contribution_scores
WHERE project_keyword = 'quip_network'
GROUP BY decay_type;
```

## Run for all projects

```bash
uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_all_decay_scores.py        # 30-day window
uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_all_decay_scores.py 14     # 14-day window
```

This **TRUNCATEs `contribution_scores` first** (all projects, not just one),
then processes every keyword with per-project timing logs, and finally creates
the five indexes (`CREATE INDEX IF NOT EXISTS`, safe to re-run).

## Troubleshooting

- `relation "mindshare_test.mindshare_post" does not exist` — apply the table
  DDL from `Schemas/CockroachDB/` (prerequisite 2).
- `Inserted 0 rows` — no rows matched: check the keyword spelling and that the
  project's posts have `is_reply = true` with non-null `replied_post_id`, and
  that repliers exist in `mindshare_test.mindshare_user`.
- Duplicate rows after re-runs — see the no-truncate note above.
