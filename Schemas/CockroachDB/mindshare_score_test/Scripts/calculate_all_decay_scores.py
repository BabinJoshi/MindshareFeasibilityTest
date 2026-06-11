#!/usr/bin/env python3
"""
Polars implementation of mindshare_score.calculate_all_decay_scores(interval)
against the CockroachDB *_test schemas.

Equivalent of the PLpgSQL wrapper + per-project function, with the data
round-trips collapsed and the whole pipeline streaming in bounded memory:

  SQL version                                Python version
  ─────────────────────────────────────      ──────────────────────────────────
  TRUNCATE contribution_scores               TRUNCATE (own committed txn)
  FOR proj IN SELECT DISTINCT keyword        ONE server-side cursor over ALL
      PERFORM calculate_decay_scores(...)      projects' replies, ORDERed BY
      (row-at-a-time cursor + INSERTs)         (project, replier, time);
                                               chunks split at replier
                                               boundaries → Polars compute
                                               per project partition → bulk
                                               INSERT per chunk
  RAISE NOTICE per project                   per-chunk timing + per-project totals
  CREATE INDEX IF NOT EXISTS × 5             same, run after the load
  ─────────────────────────────────────      ──────────────────────────────────

The decay algorithm itself lives in decay_core.compute_decay_scores() — see
that module's docstring for the full trace of the original cursor loop, the
O(n log n) asof-join formulation (no pairwise self-join), and fidelity notes.

A chunk may span several projects; it is partitioned by project_keyword before
computing, so a replier's rolling window never mixes activity across projects
— same as the SQL loop calling calculate_decay_scores(keyword) per project.
Peak memory is one chunk, never the full result set. Two connections are used
because the server-side read cursor must keep its transaction open across
write commits.

USAGE
  Connection comes from the repo-root .env (see .env.example) via db_config.py.
  CHUNK_ROWS (env, default 200000) tunes the streaming chunk size.
  uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_all_decay_scores.py [reset_interval_days]
"""

from __future__ import annotations

import os
import sys

import polars as pl
import psycopg2
from psycopg2.extras import execute_values

from db_config import get_dsn
from decay_core import (
    compute_decay_scores,
    iter_boundary_chunks,
    logger,
    setup_logging,
    stage,
    to_insert_records,
)

_SELECT_ALL = """
    SELECT
        p.project_keyword,
        p.post_id,
        op.post_id           AS original_post_id,
        p.user_x_id          AS replier_x_id,
        p.post_created_at,
        op.user_x_id         AS original_author_x_id,
        u.score::float8      AS replier_base_score
    FROM mindshare_test.mindshare_post p
    INNER JOIN mindshare_test.mindshare_post op
        ON  p.replied_post_id = op.post_id
        AND p.project_keyword = op.project_keyword
    INNER JOIN mindshare_test.mindshare_user u
        ON p.user_x_id = u.x_id
    WHERE p.is_reply        = true
      AND p.replied_post_id IS NOT NULL
    ORDER BY p.project_keyword, p.user_x_id, p.post_created_at, p.post_id
"""

_COLS = [
    "project_keyword", "post_id", "original_post_id", "replier_x_id",
    "post_created_at", "original_author_x_id", "replier_base_score",
]
_PROJECT_IDX = _COLS.index("project_keyword")
_REPLIER_IDX = _COLS.index("replier_x_id")

_INSERT = """
    INSERT INTO mindshare_score_test.contribution_scores (
        project_keyword, reply_post_id, original_post_id,
        replier_x_id, original_author_x_id, post_created_at,
        replier_base_score, effective_score, contribution_score,
        active_multipliers, reply_number, local_reply_count, decay_type
    ) VALUES %s
"""

# Mirror of the index block at the end of calculate_all_decay_scores().
# Schema changes are not transactional in CockroachDB — run each on its own.
_INDEXES = [
    """CREATE INDEX IF NOT EXISTS idx_cs_keyword_author
           ON mindshare_score_test.contribution_scores (project_keyword, original_author_x_id)""",
    """CREATE INDEX IF NOT EXISTS idx_cs_keyword_replier
           ON mindshare_score_test.contribution_scores (project_keyword, replier_x_id)""",
    """CREATE INDEX IF NOT EXISTS idx_cs_post_created
           ON mindshare_score_test.contribution_scores (post_created_at)""",
    """CREATE INDEX IF NOT EXISTS idx_cs_reply_post_id
           ON mindshare_score_test.contribution_scores (reply_post_id)""",
    """CREATE INDEX IF NOT EXISTS idx_cs_original_post_id
           ON mindshare_score_test.contribution_scores (original_post_id)""",
]


def _process_chunk(
    write_conn, rows: list[tuple], days: int, per_project: dict[str, int]
) -> int:
    """One chunk: rows → Polars → compute per project partition → bulk insert."""
    df = (
        pl.DataFrame(rows, schema=_COLS, orient="row")
        .with_columns(pl.col("post_created_at").cast(pl.Datetime("us", "UTC")))
    )
    records: list[tuple] = []
    for part in df.partition_by("project_keyword", maintain_order=True):
        keyword = part["project_keyword"][0]
        scored = compute_decay_scores(part, days)
        records.extend(to_insert_records(scored))
        per_project[keyword] = per_project.get(keyword, 0) + scored.height

    with stage(f"  insert: {len(records)} rows"):
        with write_conn.cursor() as cur:
            execute_values(cur, _INSERT, records, page_size=1000)
        write_conn.commit()
    return len(records)


def calculate_all_decay_scores(
    read_conn,
    write_conn,
    p_reset_interval_days: int = 30,
    chunk_rows: int = 200_000,
) -> int:
    """Recompute contribution scores for EVERY project. Returns total rows inserted."""

    # ── 1. TRUNCATE ───────────────────────────────────────────────────────────
    # Committed on its own: TRUNCATE is a schema change in CockroachDB and must
    # not share a transaction with the bulk inserts.
    with stage("truncate: contribution_scores"):
        with write_conn.cursor() as cur:
            cur.execute("TRUNCATE mindshare_score_test.contribution_scores")
        write_conn.commit()

    # ── 2+3. Stream all projects' replies in chunks, compute + insert ─────────
    # Named cursor → server-side streaming; chunks split only where the
    # (project, replier) pair changes, so groups are never torn.
    # score::float8 so psycopg2 returns float, not Decimal — no Polars cast needed.
    per_project: dict[str, int] = {}
    total = n_chunk = 0
    with read_conn.cursor(name="decay_read_all") as cur:
        cur.itersize = 50_000
        cur.execute(_SELECT_ALL)
        for rows in iter_boundary_chunks(cur, [_PROJECT_IDX, _REPLIER_IDX], chunk_rows):
            n_chunk += 1
            first, last = rows[0][_PROJECT_IDX], rows[-1][_PROJECT_IDX]
            span = first if first == last else f"{first} … {last}"
            with stage(f"chunk {n_chunk}: {len(rows)} rows ({span})"):
                total += _process_chunk(write_conn, rows, p_reset_interval_days,
                                        per_project)
    read_conn.rollback()    # end the read transaction

    if total == 0:
        logger.warning("no reply rows found — nothing to do")
        return 0

    for keyword, cnt in per_project.items():
        logger.info("  %-40s %d rows", keyword, cnt)

    # ── 4. Indexes ────────────────────────────────────────────────────────────
    with stage("indexes: CREATE INDEX IF NOT EXISTS × 5"):
        for ddl in _INDEXES:
            with write_conn.cursor() as cur:
                cur.execute(ddl)
            write_conn.commit()

    logger.info("All projects processed — %d total rows", total)
    return total


if __name__ == "__main__":
    days  = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    chunk = int(os.environ.get("CHUNK_ROWS", "200000"))

    setup_logging()
    dsn = get_dsn()
    with stage("connect: CockroachDB (read + write)"):
        read_conn  = psycopg2.connect(dsn)
        write_conn = psycopg2.connect(dsn)

    try:
        with stage(f"TOTAL: all projects (reset window {days}d, chunks of {chunk})"):
            count = calculate_all_decay_scores(read_conn, write_conn, days, chunk)
        logger.info("Inserted %d total rows", count)
    finally:
        read_conn.close()
        write_conn.close()
