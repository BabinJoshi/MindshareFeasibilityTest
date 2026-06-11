#!/usr/bin/env python3
"""
Vectorised Polars port of mindshare_score.calculate_decay_scores() —
shared core used by calculate_decay_scores.py and calculate_all_decay_scores.py.

──────────────────────────────────────────────────────────────────────────────
THE ORIGINAL ALGORITHM (PLpgSQL cursor loop, see
Schemas/Mindshare_score/Fuctions/calculate_decay_scores.sql)

Replies are walked ORDER BY (user_x_id, post_created_at). Per replier the loop
keeps a rolling "penalty log" of (multiplier, time, original_author) triples.
For each reply r at time T:

  1. PRUNE     drop log entries with time <= T - reset_interval
  2. local_seq = (# remaining entries with author = r's original author) + 1
  3. effective = GREATEST(ROUND(base * Π(log multipliers), 2), floor)
                 where floor = ROUND(base * 0.01, 2)
  4. DECAY     log empty          → FIRST_REPLY,  new_mult 1.0, contrib = effective
               local_seq > 1     → LOCAL_DECAY,  new_mult 0.5, contrib = GREATEST(ROUND(effective*0.5,2), floor)
               else              → GLOBAL_DECAY, new_mult 0.9, contrib = GREATEST(ROUND(effective*0.9,2), floor)
  5. APPEND    (new_mult, T, author) to the log; the stored active_multipliers
               array is the log snapshot AFTER this append.

WHY IT VECTORISES — the key observation

A reply's decay_type depends only on COUNTS of raw prior rows in its window
(steps 1-2), never on previously computed *scores*. And each log entry's
multiplier was fixed when that prior reply was processed (by ITS OWN window).
So for reply r:

  prior rows        = same-replier replies processed before r with
                      time > T - reset_interval               (the pruned log)
  prior_n           = COUNT(prior rows)
  prior_local_count = COUNT(prior rows targeting the same original author)
  decay_type        = FIRST_REPLY | LOCAL_DECAY | GLOBAL_DECAY  (from the two counts)
  Π(log mults)      = 0.5^(# prior LOCAL_DECAY) * 0.9^(# prior GLOBAL_DECAY)
                      (FIRST_REPLY entries are 1.0 — multiplicatively neutral)

HOW IT'S COMPUTED — O(n log n), no pairwise self-join

A naive inequality self-join ("each reply × its prior rows in window")
materialises Σ window-size pairs — billions of rows on a 2.2M-reply project,
which OOMs the process. Instead, with rows sorted by (replier, time, post_id),
every window is a CONTIGUOUS index range [lo, i) inside the replier group, so:

  lo                 = first same-replier row with time > T - reset
                       (one asof join, strategy='forward')
  prior_n            = idx_in_replier(i) - idx_in_replier(lo)
  prior_local_count  = idx_in_author_group(i) - idx_in_author_group(lo_author)
                       (second asof join keyed by replier+author)
  # prior LOCAL/GLOBAL = exclusive-prefix-sum(i) - exclusive-prefix-sum(lo)
                       (third asof join, after decay_type is known)
  active_multipliers = new_mult slice [lo .. i] of the replier group

Every step is a sorted merge or a prefix sum — linear memory, no row pairs.

FIDELITY NOTES (divergences from naive set-based rewrites, handled here)

* Tie semantics. The cursor counts ANY previously-processed reply still in the
  window — including one with the SAME timestamp. We sort by
  (replier, time, post_id) and define "prior" by position, exactly the
  cursor's log, with post_id as deterministic tiebreak (the original's tie
  order is unspecified — its ORDER BY has no tiebreak column).
* Window bound is strictly `time > cutoff` (the prune keeps
  `penalty_times[i] > cutoff_time`). Timestamps are µs precision, so the
  forward asof search uses `time >= cutoff + 1µs` ⇔ `time > cutoff`.
* Rounding. Postgres NUMERIC ROUND() is half-away-from-zero; Polars round()
  defaults to half-to-even. We pass mode="half_away_from_zero". (Residual
  float64-vs-NUMERIC representation differences at exact .005 boundaries are
  possible but not observed in verification.)
──────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager

import polars as pl

logger = logging.getLogger("decay_scores")


@contextmanager
def stage(name: str):
    """Log a named stage and how long it took."""
    t0 = time.perf_counter()
    logger.info("▶ %s ...", name)
    try:
        yield
    finally:
        logger.info("✔ %s — %.2f sec", name, time.perf_counter() - t0)


def setup_logging(level: int = logging.INFO) -> None:
    """Console logging with timestamps for the runner scripts."""
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)-5s %(message)s",
        datefmt="%H:%M:%S",
    )


# Column order of mindshare_score_test.contribution_scores INSERTs.
OUT_COLS = [
    "project_keyword", "post_id", "original_post_id",
    "replier_x_id", "original_author_x_id", "post_created_at",
    "replier_base_score", "effective_score", "contribution_score",
    "active_multipliers", "reply_seq", "local_seq", "decay_type",
]


def _round2(expr: pl.Expr) -> pl.Expr:
    """ROUND(x, 2) with Postgres NUMERIC semantics (half away from zero)."""
    return expr.round(2, mode="half_away_from_zero")


def compute_decay_scores(df: pl.DataFrame, reset_interval_days: int = 30) -> pl.DataFrame:
    """Vectorised decay-score computation for ONE project's reply DataFrame.

    Expects columns: project_keyword, post_id, original_post_id, replier_x_id,
    post_created_at (Datetime, µs), original_author_x_id, replier_base_score (f64).
    Returns a DataFrame containing OUT_COLS, one row per input reply.
    """
    # ── Processing order ──────────────────────────────────────────────────────
    # Mirrors the cursor's ORDER BY (user_x_id, post_created_at), with post_id
    # as deterministic tiebreak. idx_r / a_idx are 0-based positions within the
    # replier group and the (replier, author) subgroup; cutoff_adj makes the
    # forward asof search equivalent to the strict `time > cutoff` prune.
    df = df.sort(["replier_x_id", "post_created_at", "post_id"]).with_columns(
        (pl.col("post_id").cum_count().over("replier_x_id") - 1)
            .cast(pl.Int64).alias("idx_r"),
        (pl.col("post_id").cum_count()
            .over(["replier_x_id", "original_author_x_id"]) - 1)
            .cast(pl.Int64).alias("a_idx"),
        (pl.col("post_created_at")
            - pl.duration(days=reset_interval_days)
            + pl.duration(microseconds=1)).alias("cutoff_adj"),
        _round2(pl.col("replier_base_score") * 0.01).alias("min_floor"),
    )

    with stage("compute: pass 1 — window starts → prior counts → decay_type"):
        # lo = first same-replier row inside the window. Always matches (each
        # row qualifies for its own window), so no null handling is needed.
        # Frames are sorted by the on-key within every `by` group (global
        # sortedness, which polars would check, does not hold — hence
        # check_sortedness=False).
        df = df.join_asof(
            df.select(
                pl.col("replier_x_id"),
                pl.col("post_created_at").alias("t_lo"),
                pl.col("idx_r").alias("lo_idx_r"),
            ),
            left_on="cutoff_adj", right_on="t_lo",
            by="replier_x_id", strategy="forward",
            check_sortedness=False,
        )

        # Same search inside the (replier, author) subgroup for local counts.
        df = df.join_asof(
            df.select(
                pl.col("replier_x_id"),
                pl.col("original_author_x_id"),
                pl.col("post_created_at").alias("t_lo_a"),
                pl.col("a_idx").alias("lo_a_idx"),
            ),
            left_on="cutoff_adj", right_on="t_lo_a",
            by=["replier_x_id", "original_author_x_id"], strategy="forward",
            check_sortedness=False,
        )

        df = df.with_columns(
            (pl.col("idx_r") - pl.col("lo_idx_r")).alias("prior_n"),
            (pl.col("a_idx") - pl.col("lo_a_idx")).alias("prior_local_count"),
        ).with_columns(
            pl.when(pl.col("prior_n") == 0)
                .then(pl.lit("FIRST_REPLY"))
                .when(pl.col("prior_local_count") >= 1)
                .then(pl.lit("LOCAL_DECAY"))
                .otherwise(pl.lit("GLOBAL_DECAY"))
                .alias("decay_type"),
            pl.when(pl.col("prior_n") == 0)
                .then(pl.lit(1.0))
                .when(pl.col("prior_local_count") >= 1)
                .then(pl.lit(0.50))
                .otherwise(pl.lit(0.90))
                .alias("new_mult"),
            (pl.col("prior_local_count") + 1).alias("local_seq"),
            (pl.col("idx_r") + 1).alias("reply_seq"),
        )

    with stage("compute: pass 2 — decay-type prefix sums → active_product"):
        # prior LOCAL/GLOBAL counts in [lo, i) via exclusive prefix sums:
        # excl[i] - excl[lo]. The third asof join fetches excl[lo].
        df = df.with_columns(
            ((pl.col("decay_type") == "LOCAL_DECAY").cast(pl.Int64))
                .alias("is_local"),
            ((pl.col("decay_type") == "GLOBAL_DECAY").cast(pl.Int64))
                .alias("is_global"),
        ).with_columns(
            (pl.col("is_local").cum_sum().over("replier_x_id") - pl.col("is_local"))
                .alias("excl_local"),
            (pl.col("is_global").cum_sum().over("replier_x_id") - pl.col("is_global"))
                .alias("excl_global"),
        )

        df = df.join_asof(
            df.select(
                pl.col("replier_x_id"),
                pl.col("post_created_at").alias("t_lo_d"),
                pl.col("excl_local").alias("lo_excl_local"),
                pl.col("excl_global").alias("lo_excl_global"),
            ),
            left_on="cutoff_adj", right_on="t_lo_d",
            by="replier_x_id", strategy="forward",
            check_sortedness=False,
        )

        # Integer exponentiation of exact constants — no log/exp float error.
        df = df.with_columns(
            (
                pl.lit(0.5).pow(pl.col("excl_local") - pl.col("lo_excl_local")) *
                pl.lit(0.9).pow(pl.col("excl_global") - pl.col("lo_excl_global"))
            ).alias("active_product")
        )

    with stage("compute: final — scores + active_multipliers slices"):
        df = (
            df.with_columns(
                pl.max_horizontal(
                    _round2(pl.col("replier_base_score") * pl.col("active_product")),
                    pl.col("min_floor"),
                ).alias("effective_score")
            )
            .with_columns(
                pl.when(pl.col("decay_type") == "FIRST_REPLY")
                    .then(pl.col("effective_score"))
                    .when(pl.col("decay_type") == "LOCAL_DECAY")
                    .then(
                        pl.max_horizontal(
                            _round2(pl.col("effective_score") * 0.50),
                            pl.col("min_floor"),
                        )
                    )
                    .otherwise(
                        pl.max_horizontal(
                            _round2(pl.col("effective_score") * 0.90),
                            pl.col("min_floor"),
                        )
                    )
                    .alias("contribution_score")
            )
        )

        # active_multipliers = new_mult slice [lo .. i] of the replier group
        # (the log snapshot AFTER appending the current reply). Windows are
        # contiguous index ranges, so plain list slices — linear in output size.
        mults = df["new_mult"].to_list()
        idx_r = df["idx_r"].to_list()
        lo_r  = df["lo_idx_r"].to_list()
        arrays, row = [], 0
        for i, (ix, lo) in enumerate(zip(idx_r, lo_r)):
            row = i - ix          # global row index where this replier group starts
            arrays.append(mults[row + lo : i + 1])
        df = df.with_columns(
            pl.Series("active_multipliers", arrays, dtype=pl.List(pl.Float64))
        )

    return df.select(OUT_COLS)


def to_insert_records(scored: pl.DataFrame) -> list[tuple]:
    """contribution_scores rows as tuples for psycopg2 execute_values."""
    return [
        (
            r["project_keyword"],
            r["post_id"],
            r["original_post_id"],
            r["replier_x_id"],
            r["original_author_x_id"],
            r["post_created_at"],
            r["replier_base_score"],
            r["effective_score"],
            r["contribution_score"],
            r["active_multipliers"],   # list[float] → NUMERIC[] via psycopg2
            r["reply_seq"],
            r["local_seq"],
            r["decay_type"],
        )
        for r in scored.select(OUT_COLS).to_dicts()
    ]


def iter_boundary_chunks(
    cur,
    key_indices: Sequence[int],
    chunk_rows: int = 200_000,
    fetch_size: int = 50_000,
) -> Iterator[list[tuple]]:
    """Stream rows from a (server-side) cursor in chunks of ~chunk_rows,
    splitting ONLY where the key columns change so a group (e.g. one replier)
    is never torn across two chunks. The query must be ORDERed BY those keys.

    Keeps memory bounded: only the current chunk is resident, never the full
    result set."""
    buffer: list[tuple] = []
    while True:
        batch = cur.fetchmany(fetch_size)
        if not batch:
            break
        buffer.extend(batch)
        if len(buffer) < chunk_rows:
            continue
        # split before the last (possibly incomplete) key group
        last_key = tuple(buffer[-1][i] for i in key_indices)
        split = len(buffer) - 1
        while split > 0 and tuple(buffer[split - 1][i] for i in key_indices) == last_key:
            split -= 1
        if split > 0:                       # single huge group: keep buffering
            yield buffer[:split]
            buffer = buffer[split:]
    if buffer:
        yield buffer
