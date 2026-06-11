#!/usr/bin/env python3
"""
Polars implementation of mindshare_score.calculate_decay_scores(text, interval)
against the CockroachDB *_test schemas.

PIPELINE (streaming, bounded memory)
  1. Server-side cursor SELECT, ORDERed BY (replier, time, post_id)
     (mindshare_test.mindshare_post ⋈ mindshare_test.mindshare_post
      ⋈ mindshare_test.mindshare_user, one project's replies)
  2. Rows stream in chunks of ~CHUNK_ROWS, split only at replier boundaries —
     the algorithm is independent per replier, so chunking is exact.
  3. Per chunk: Polars compute (see decay_core.py — O(n log n) asof joins,
     no pairwise self-join) → bulk INSERT via psycopg2 execute_values into
     mindshare_score_test.contribution_scores.

Peak memory is one chunk, not the whole project — a 2M+-reply project runs in
the same footprint as a small one. Two connections are used because the
server-side read cursor must keep its transaction open across write commits.

NOTE: unlike calculate_all_decay_scores.py, this does NOT truncate the target
table first — same as the original per-project function, which assumes the
caller cleared existing rows for the keyword.

USAGE
  Connection comes from the repo-root .env (see .env.example) via db_config.py.
  CHUNK_ROWS (env, default 200000) tunes the streaming chunk size.
  uv run Schemas/CockroachDB/mindshare_score_test/Scripts/calculate_decay_scores.py <keyword> [reset_interval_days]
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

_SELECT = """
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
      AND p.project_keyword = %s
    ORDER BY p.user_x_id, p.post_created_at, p.post_id
"""

_COLS = [
    "project_keyword", "post_id", "original_post_id", "replier_x_id",
    "post_created_at", "original_author_x_id", "replier_base_score",
]
_REPLIER_IDX = _COLS.index("replier_x_id")

_INSERT = """
    INSERT INTO mindshare_score_test.contribution_scores (
        project_keyword, reply_post_id, original_post_id,
        replier_x_id, original_author_x_id, post_created_at,
        replier_base_score, effective_score, contribution_score,
        active_multipliers, reply_number, local_reply_count, decay_type
    ) VALUES %s
"""


def _process_chunk(write_conn, rows: list[tuple], days: int) -> int:
    """One chunk: rows → Polars → compute → bulk insert. Returns rows written."""
    df = (
        pl.DataFrame(rows, schema=_COLS, orient="row")
        .with_columns(pl.col("post_created_at").cast(pl.Datetime("us", "UTC")))
    )
    scored = compute_decay_scores(df, days)
    with stage(f"  insert: {scored.height} rows"):
        records = to_insert_records(scored)
        with write_conn.cursor() as cur:
            execute_values(cur, _INSERT, records, page_size=1000)
        write_conn.commit()
    return len(records)


def calculate_decay_scores(
    read_conn,
    write_conn,
    p_project_keyword: str,
    p_reset_interval_days: int = 30,
    chunk_rows: int = 200_000,
) -> int:
    """Compute and insert contribution scores. Returns the number of rows inserted."""
    total = n_chunk = 0
    # Named cursor → server-side streaming; rows never fully materialise here.
    # score::float8 so psycopg2 returns float, not Decimal — no Polars cast needed.
    with read_conn.cursor(name="decay_read") as cur:
        cur.itersize = 50_000
        cur.execute(_SELECT, (p_project_keyword,))
        for rows in iter_boundary_chunks(cur, [_REPLIER_IDX], chunk_rows):
            n_chunk += 1
            with stage(f"chunk {n_chunk}: {len(rows)} rows"):
                total += _process_chunk(write_conn, rows, p_reset_interval_days)
    read_conn.rollback()    # end the read transaction

    if total == 0:
        logger.warning("no reply rows for '%s' — nothing to do", p_project_keyword)
    return total


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <project_keyword> [reset_interval_days]")
        sys.exit(1)

    keyword = sys.argv[1]
    days    = int(sys.argv[2]) if len(sys.argv) > 2 else 30
    chunk   = int(os.environ.get("CHUNK_ROWS", "200000"))

    setup_logging()
    dsn = get_dsn()
    with stage("connect: CockroachDB (read + write)"):
        read_conn  = psycopg2.connect(dsn)
        write_conn = psycopg2.connect(dsn)

    try:
        with stage(f"TOTAL: '{keyword}' (reset window {days}d, chunks of {chunk})"):
            count = calculate_decay_scores(read_conn, write_conn, keyword, days, chunk)
        logger.info("Inserted %d rows for project '%s'", count, keyword)
    finally:
        read_conn.close()
        write_conn.close()
