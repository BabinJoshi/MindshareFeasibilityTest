#!/usr/bin/env python3
"""
load_csv.py — Bulk-import Mindshare CSVs into CockroachDB.

Usage:
    uv sync                  # install psycopg2-binary
    uv run load_csv.py

Edit CRDB_URL and CSV_DIR before running.
Get your connection string from:
    CockroachDB Cloud console → Cluster → Connect → Connection string
"""

import csv
import json
import logging
import sys
from decimal import Decimal
from pathlib import Path

import psycopg2
import psycopg2.extras

# ── CONFIG — edit these two lines ─────────────────────────────────────────────
# CRDB_URL = "postgresql://user:password@host.cockroachlabs.cloud:26257/defaultdb?sslmode=verify-full"
CRDB_URL='nucleus-prod-25259.j77.aws-us-east-2.cockroachlabs.cloud'
CSV_DIR  = Path(r"C:\path\to\your\csv\files")   # folder containing all CSV files
# ─────────────────────────────────────────────────────────────────────────────

BATCH_SIZE = 500   # rows per INSERT ... VALUES (...),(...),...

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


# ── TYPE HELPERS ──────────────────────────────────────────────────────────────

def _s(v):
    """String or None."""
    return None if (v is None or v == "") else v

def _bool(v):
    """Handles Postgres t/f and true/false/1/0."""
    if v is None or v == "":
        return None
    return v.lower() in ("t", "true", "1", "yes")

def _int(v):
    if v is None or v == "":
        return None
    return int(v)

def _dec(v):
    if v is None or v == "":
        return None
    return Decimal(v)

def _json(v):
    """Parse JSON string and wrap with psycopg2.extras.Json for correct JSONB binding."""
    if v is None or v == "":
        return None
    return psycopg2.extras.Json(json.loads(v))

def _arr(v):
    """
    Parse Postgres numeric array literal {0.5,0.9} → Python list of Decimal.
    psycopg2 sends Python lists as ARRAY[...] which CRDB accepts for DECIMAL[].
    """
    if v is None or v == "" or v == "{}":
        return []
    return [Decimal(x.strip()) for x in v.strip("{}").split(",") if x.strip()]


# ── ROW TRANSFORMERS ──────────────────────────────────────────────────────────
# Each function receives a raw csv.DictReader row and returns a tuple matching
# the column list defined in TABLES below.
# Generated columns (is_retweet, is_reply, is_quote, is_post) are intentionally
# excluded — CockroachDB computes them automatically.

def row_mindshare_user(r):
    return (
        _s(r["x_id"]),
        _s(r["x_username"]),
        _s(r["display_name"]),
        _dec(r["score"]),
        _s(r["avatar_url"]),
        _json(r["adjustment_config"]),
        _int(r["followers_count"]),
        _bool(r["verified"]),
        _s(r["created_at"]),
        _s(r.get("updated_at")),
        _s(r.get("last_score_fetched_at")),
    )

def row_nucleus_user(r):
    return (
        _s(r["x_id"]),
        _s(r["x_username"]),
        _s(r["display_name"]),
        _dec(r["score"]),
        _s(r["avatar_url"]),
        _json(r["adjustment_config"]),
        _int(r["followers_count"]),
        _bool(r["verified"]),
        _s(r["created_at"]),
        _s(r.get("updated_at")),
    )

def row_mindshare_post(r):
    return (
        _s(r["post_id"]),
        _s(r["project_keyword"]),
        _s(r["user_x_id"]),
        _s(r["full_text"]),
        _s(r.get("retweeted_post_id")),
        _s(r.get("replied_post_id")),
        _s(r.get("quoted_post_id")),
        _s(r.get("root_post_id")),
        _int(r["view_count"]),
        _int(r["reply_count"]),
        _int(r["retweet_count"]),
        _int(r["quote_count"]),
        _int(r["favorite_count"]),
        _s(r["post_created_at"]),
        _s(r["created_at"]),
        _s(r.get("updated_at")),
        _dec(r.get("sentiment_score")),
        _s(r.get("sentiment_label")),
        _json(r.get("entities")),
        _dec(r.get("content_score")),
        _s(r.get("latest_reply_at")),
    )

def row_nucleus_post(r):
    return (
        _s(r["post_id"]),
        _s(r["project_keyword"]),
        _s(r["user_x_id"]),
        _s(r["full_text"]),
        _s(r.get("retweeted_post_id")),
        _s(r.get("replied_post_id")),
        _s(r.get("quoted_post_id")),
        _s(r.get("root_post_id")),
        _int(r["view_count"]),
        _int(r["reply_count"]),
        _int(r["retweet_count"]),
        _int(r["quote_count"]),
        _int(r["favorite_count"]),
        _s(r["post_created_at"]),
        _dec(r.get("sentiment_score")),
        _s(r.get("sentiment_label")),
        _json(r.get("entities")),
        _dec(r.get("content_score")),
        _s(r["created_at"]),
        _s(r.get("updated_at")),
        _bool(r.get("is_reply_fetched", "false")),
    )

def row_user_post(r):
    return (
        _s(r["post_id"]),
        _s(r["user_x_id"]),
        _s(r["full_text"]),
        _s(r.get("retweeted_post_id")),
        _s(r.get("replied_post_id")),
        _s(r.get("quoted_post_id")),
        _s(r.get("root_post_id")),
        _int(r["view_count"]),
        _int(r["reply_count"]),
        _int(r["retweet_count"]),
        _int(r["quote_count"]),
        _int(r["favorite_count"]),
        _s(r["post_created_at"]),
        _s(r["created_at"]),
        _s(r.get("updated_at")),
        _json(r.get("entities")),
        _s(r.get("project_keyword")),
    )

def row_contribution_scores(r):
    return (
        _s(r["project_keyword"]),
        _s(r["reply_post_id"]),
        _s(r["replier_x_id"]),
        _s(r["original_post_id"]),
        _s(r["original_author_x_id"]),
        _s(r["post_created_at"]),
        _dec(r["replier_base_score"]),
        _dec(r["effective_score"]),
        _dec(r["contribution_score"]),
        _arr(r["active_multipliers"]),
        _int(r["reply_number"]),
        _int(r["local_reply_count"]),
        _s(r["decay_type"]),
    )

def row_global_contribution_scores(r):
    return (
        _s(r["reply_post_id"]),
        _s(r["replier_x_id"]),
        _s(r["original_post_id"]),
        _s(r["original_author_x_id"]),
        _s(r["post_created_at"]),
        _dec(r["replier_base_score"]),
        _dec(r["effective_score"]),
        _dec(r["contribution_score"]),
        _arr(r["active_multipliers"]),
        _int(r["reply_number"]),
        _int(r["local_reply_count"]),
        _s(r["decay_type"]),
    )


# ── TABLE MANIFEST ────────────────────────────────────────────────────────────
# (csv_filename, target_table, [columns_in_order], row_transformer)
# Run in this order: users before posts (no FK constraints, but logical)

TABLES = [
    (
        "mindshare_user.csv",
        "mindshare.mindshare_user",
        [
            "x_id", "x_username", "display_name", "score", "avatar_url",
            "adjustment_config", "followers_count", "verified",
            "created_at", "updated_at", "last_score_fetched_at",
        ],
        row_mindshare_user,
    ),
    (
        "nucleus_user.csv",
        "mindshare.nucleus_user",
        [
            "x_id", "x_username", "display_name", "score", "avatar_url",
            "adjustment_config", "followers_count", "verified",
            "created_at", "updated_at",
        ],
        row_nucleus_user,
    ),
    (
        "mindshare_post.csv",
        "mindshare.mindshare_post",
        [
            "post_id", "project_keyword", "user_x_id", "full_text",
            "retweeted_post_id", "replied_post_id", "quoted_post_id", "root_post_id",
            "view_count", "reply_count", "retweet_count", "quote_count", "favorite_count",
            "post_created_at", "created_at", "updated_at",
            "sentiment_score", "sentiment_label", "entities", "content_score", "latest_reply_at",
        ],
        row_mindshare_post,
    ),
    (
        "nucleus_post.csv",
        "mindshare.nucleus_post",
        [
            "post_id", "project_keyword", "user_x_id", "full_text",
            "retweeted_post_id", "replied_post_id", "quoted_post_id", "root_post_id",
            "view_count", "reply_count", "retweet_count", "quote_count", "favorite_count",
            "post_created_at", "sentiment_score", "sentiment_label", "entities", "content_score",
            "created_at", "updated_at", "is_reply_fetched",
        ],
        row_nucleus_post,
    ),
    (
        "user_post.csv",
        "mindshare.user_post",
        [
            "post_id", "user_x_id", "full_text",
            "retweeted_post_id", "replied_post_id", "quoted_post_id", "root_post_id",
            "view_count", "reply_count", "retweet_count", "quote_count", "favorite_count",
            "post_created_at", "created_at", "updated_at", "entities", "project_keyword",
        ],
        row_user_post,
    ),
    (
        "contribution_scores.csv",
        "mindshare_score.contribution_scores",
        [
            "project_keyword", "reply_post_id", "replier_x_id", "original_post_id",
            "original_author_x_id", "post_created_at", "replier_base_score",
            "effective_score", "contribution_score", "active_multipliers",
            "reply_number", "local_reply_count", "decay_type",
        ],
        row_contribution_scores,
    ),
    (
        "global_contribution_scores.csv",
        "mindshare_score.global_contribution_scores",
        [
            "reply_post_id", "replier_x_id", "original_post_id", "original_author_x_id",
            "post_created_at", "replier_base_score", "effective_score", "contribution_score",
            "active_multipliers", "reply_number", "local_reply_count", "decay_type",
        ],
        row_global_contribution_scores,
    ),
]


# ── IMPORT LOGIC ──────────────────────────────────────────────────────────────

def import_table(cur, csv_path: Path, table: str, columns: list, row_fn) -> int:
    if not csv_path.exists():
        log.warning(f"SKIP  {csv_path.name} — file not found in {CSV_DIR}")
        return 0

    col_sql = ", ".join(columns)
    sql     = f"INSERT INTO {table} ({col_sql}) VALUES %s ON CONFLICT DO NOTHING"

    batch, total, errors = [], 0, 0

    # utf-8-sig strips the BOM that Windows sometimes prepends to UTF-8 files
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for line_num, raw in enumerate(reader, start=2):  # start=2 (row 1 = header)
            try:
                row = row_fn(raw)
            except Exception as e:
                log.warning(f"  Line {line_num}: parse error — {e}")
                errors += 1
                continue

            batch.append(row)

            if len(batch) >= BATCH_SIZE:
                try:
                    psycopg2.extras.execute_values(cur, sql, batch)
                    total += len(batch)
                except Exception as e:
                    log.error(f"  Batch ending at line {line_num}: insert error — {e}")
                    errors += len(batch)
                finally:
                    batch = []

                if total % 10_000 == 0:
                    log.info(f"  {total:>10,} rows inserted  |  {errors} errors so far")

    # flush the final partial batch
    if batch:
        try:
            psycopg2.extras.execute_values(cur, sql, batch)
            total += len(batch)
        except Exception as e:
            log.error(f"  Final batch insert error — {e}")
            errors += len(batch)

    log.info(f"  DONE  {total:,} inserted  |  {errors} errors  →  {table}")
    return total


def main():
    log.info("Connecting to CockroachDB…")
    try:
        conn = psycopg2.connect(CRDB_URL)
    except Exception as e:
        log.error(f"Connection failed: {e}")
        sys.exit(1)

    # autocommit=True means each execute_values call commits immediately.
    # Progress is preserved even if the script is interrupted mid-table.
    conn.autocommit = True
    cur = conn.cursor()

    grand_total = 0
    for csv_file, table, columns, row_fn in TABLES:
        log.info(f"── {csv_file}  →  {table}")
        grand_total += import_table(cur, CSV_DIR / csv_file, table, columns, row_fn)

    cur.close()
    conn.close()
    log.info(f"Finished. {grand_total:,} rows inserted across all tables.")


if __name__ == "__main__":
    main()
