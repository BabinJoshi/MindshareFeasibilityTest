#!/usr/bin/env python3
"""
CSV to CockroachDB migration loader.

Efficiently loads CSV data from PostgreSQL dumps into CockroachDB tables.
Supports batch processing, type conversion, and error handling.

Usage:
    python load_csv.py --csv-file path/to/file.csv --table table_name [--batch-size 1000]
"""

import argparse
import csv
import json
import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

import psycopg2
from psycopg2.extras import execute_batch, execute_values, Json

# Try to load config.py if it exists
try:
    from config import DB_CONFIG, MIGRATION_CONFIG
    HAS_CONFIG = True
except ImportError:
    HAS_CONFIG = False
    DB_CONFIG = {}
    MIGRATION_CONFIG = {}


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


# Table schemas: defines column order and type converters
SCHEMAS = {
    "mindshare_user": {
        "columns": [
            "x_id",
            "x_username",
            "display_name",
            "score",
            "avatar_url",
            "adjustment_config",
            "followers_count",
            "verified",
            "created_at",
            "updated_at",
            "last_score_fetched_at",
        ],
        "converters": {
            "x_id": str,
            "x_username": str,
            "display_name": str,
            "score": float,
            "avatar_url": str,
            "adjustment_config": lambda x: json.loads(x) if x else {},
            "followers_count": int,
            "verified": lambda x: x.lower() in ("true", "1", "t", "yes") if isinstance(x, str) else bool(x),
            "created_at": lambda x: parse_timestamp(x),
            "updated_at": lambda x: parse_timestamp(x),
            "last_score_fetched_at": lambda x: parse_timestamp(x),
        },
        "json_columns": ["adjustment_config"],
    },
    "mindshare_post": {
        # Include all columns from CSV to maintain alignment
        "columns": [
            "post_id",
            "project_keyword",
            "user_x_id",
            "full_text",
            "retweeted_post_id",
            "replied_post_id",
            "quoted_post_id",
            "root_post_id",
            "is_retweet",      # GENERATED column - read but don't insert
            "is_reply",        # GENERATED column - read but don't insert
            "is_quote",        # GENERATED column - read but don't insert
            "is_post",         # GENERATED column - read but don't insert
            "view_count",
            "reply_count",
            "retweet_count",
            "quote_count",
            "favorite_count",
            "post_created_at",
            "created_at",
            "updated_at",
            "sentiment_score",
            "sentiment_label",
            "entities",
            "content_score",
            "latest_reply_at",
        ],
        "converters": {
            "post_id": str,
            "project_keyword": str,
            "user_x_id": str,
            "full_text": str,
            "retweeted_post_id": str,
            "replied_post_id": str,
            "quoted_post_id": str,
            "root_post_id": str,
            "is_retweet": bool,  # Skip in insert
            "is_reply": bool,    # Skip in insert
            "is_quote": bool,    # Skip in insert
            "is_post": bool,     # Skip in insert
            "view_count": int,
            "reply_count": int,
            "retweet_count": int,
            "quote_count": int,
            "favorite_count": int,
            "post_created_at": lambda x: parse_timestamp(x),
            "created_at": lambda x: parse_timestamp(x),
            "updated_at": lambda x: parse_timestamp(x),
            "sentiment_score": float,
            "sentiment_label": str,
            "entities": lambda x: json.loads(x) if x and x.strip() != '""' else None,
            "content_score": float,
            "latest_reply_at": lambda x: parse_timestamp(x),
        },
        "json_columns": ["entities"],
        "skip_insert_columns": ["is_retweet", "is_reply", "is_quote", "is_post"],  # Don't insert GENERATED columns
    },
}


def parse_timestamp(value: str) -> datetime:
    """Parse timestamp from CSV (handles +HHMM timezone format)."""
    if not value or value == "NULL":
        return None
    try:
        # Handle format: "2026-03-10 06:50:39.284 +0545"
        # Replace space before timezone with nothing to get ISO format
        iso_value = value.replace(" +", "+").replace(" -", "-")
        # fromisoformat handles ±HH:MM but not ±HHMM, so we need to insert colon
        if "+" in iso_value or "-" in iso_value:
            # Find the timezone part (last + or -)
            for i, char in enumerate(iso_value):
                if char in ("+", "-") and i > 10:  # Skip date separators
                    tz_part = iso_value[i:]
                    if len(tz_part) == 5 and tz_part[0] in "+-":  # +HHMM or -HHMM
                        iso_value = iso_value[:i] + tz_part[0] + tz_part[1:3] + ":" + tz_part[3:5]
                    break
        return datetime.fromisoformat(iso_value)
    except (ValueError, AttributeError) as e:
        logger.warning(f"Could not parse timestamp: {value} ({e})")
        return None


def read_csv(csv_file: Path, schema: dict, skip_null_columns: list = None) -> Iterator[dict]:
    """
    Read CSV file and yield rows as dictionaries with converted values.

    Args:
        csv_file: Path to CSV file
        schema: Schema definition with column names and converters
        skip_null_columns: List of columns that if NULL, skip the entire row (e.g., ["x_username"])

    Yields:
        Dictionary with converted column values
    """
    columns = schema["columns"]
    converters = schema["converters"]
    skip_null_columns = skip_null_columns or []

    skipped_count = 0
    with open(csv_file, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f, fieldnames=columns, skipinitialspace=True)
        for row_num, row in enumerate(reader, 1):
            # Skip header row if it matches column names
            if row_num == 1 and row.get(columns[0]) == columns[0]:
                continue

            try:
                converted_row = {}
                skip_row = False

                for col in columns:
                    value = row.get(col, "").strip()
                    converter = converters.get(col, str)

                    # Handle empty values as NULL
                    if not value or value.upper() == "NULL":
                        converted_row[col] = None
                        # Check if this column should cause row skip
                        if col in skip_null_columns:
                            skip_row = True
                    else:
                        try:
                            converted_row[col] = converter(value)
                        except Exception as e:
                            logger.error(f"Row {row_num}, column {col}: {e}")
                            raise

                if skip_row:
                    skipped_count += 1
                    if skipped_count <= 5:  # Log first 5 skipped rows
                        logger.warning(f"Row {row_num}: Skipping (null in required column)")
                    continue

                yield converted_row
            except Exception as e:
                logger.error(f"Error processing row {row_num}: {e}")
                raise

        if skipped_count > 5:
            logger.warning(f"... and {skipped_count - 5} more rows skipped")


def insert_batch(
    conn,
    table: str,
    columns: list,
    rows: list,
    json_columns: list = None,
    skip_insert_columns: list = None,
) -> int:
    """
    Insert a batch of rows using execute_values for efficiency.

    Args:
        conn: psycopg2 connection
        table: Target table name (schema.table)
        columns: Column names
        rows: List of tuples with values in column order
        json_columns: List of column names that are JSONB type
        skip_insert_columns: List of column names to skip (e.g., GENERATED columns)

    Returns:
        Number of rows inserted
    """
    if not rows:
        return 0

    json_columns = json_columns or []
    skip_insert_columns = skip_insert_columns or []

    # Determine which columns to actually insert (exclude skip_insert_columns)
    insert_col_indices = [i for i, col in enumerate(columns) if col not in skip_insert_columns]
    insert_columns = [columns[i] for i in insert_col_indices]

    # Wrap JSON columns with psycopg2's Json adapter and filter skip columns
    processed_rows = []
    for row in rows:
        processed_row = []
        for col_idx in insert_col_indices:
            value = row[col_idx]
            col_name = columns[col_idx]
            if col_name in json_columns and value is not None:
                processed_row.append(Json(value))
            else:
                processed_row.append(value)
        processed_rows.append(tuple(processed_row))

    col_names = ", ".join(insert_columns)
    placeholders = ", ".join(["%s"] * len(insert_columns))
    sql = f"INSERT INTO {table} ({col_names}) VALUES ({placeholders})"

    try:
        with conn.cursor() as cur:
            # Using execute_batch for better performance with large datasets
            execute_batch(cur, sql, processed_rows, page_size=500)
        conn.commit()
        return len(rows)
    except psycopg2.Error as e:
        conn.rollback()
        logger.error(f"Database error during insert: {e}")
        raise


def migrate_table(
    csv_file: Path,
    table: str,
    db_host: str,
    db_port: int,
    db_name: str,
    db_user: str,
    db_password: str,
    batch_size: int = 1000,
    dry_run: bool = False,
    skip_null_columns: list = None,
) -> int:
    """
    Migrate CSV file to CockroachDB table.

    Args:
        csv_file: Path to CSV file
        table: Target table name (schema.table or just table)
        db_host: Database host
        db_port: Database port
        db_name: Database name
        db_user: Database user
        db_password: Database password
        batch_size: Number of rows to insert per batch
        dry_run: If True, validate data but don't insert
        skip_null_columns: List of columns that if NULL, skip the entire row

    Returns:
        Total number of rows inserted
    """
    if not csv_file.exists():
        raise FileNotFoundError(f"CSV file not found: {csv_file}")

    # Extract table name from "schema.table" or use as-is if just table name
    table_key = table.split(".")[-1] if "." in table else table

    if table_key not in SCHEMAS:
        raise ValueError(f"Unknown table: {table_key}. Supported tables: {list(SCHEMAS.keys())}")

    schema = SCHEMAS[table_key]
    logger.info(f"Starting migration for table: {table}")
    logger.info(f"CSV file: {csv_file}")

    # If schema not specified in table parameter, use schema from config or default
    if "." not in table:
        config_schema = DB_CONFIG.get("schema", "public")
        table = f"{config_schema}.{table}"
        logger.info(f"Using schema from config: {table}")

    conn = psycopg2.connect(
        host=db_host,
        port=db_port,
        database=db_name,
        user=db_user,
        password=db_password,
    )

    try:
        total_rows = 0
        batch = []
        json_columns = schema.get("json_columns", [])
        skip_insert_columns = schema.get("skip_insert_columns", [])
        skip_null_columns = skip_null_columns or []

        for row_dict in read_csv(csv_file, schema, skip_null_columns):
            # Convert dict to tuple in column order
            row_tuple = tuple(row_dict[col] for col in schema["columns"])
            batch.append(row_tuple)

            if len(batch) >= batch_size:
                if dry_run:
                    logger.info(f"[DRY RUN] Would insert {len(batch)} rows")
                else:
                    inserted = insert_batch(conn, table, schema["columns"], batch, json_columns, skip_insert_columns)
                    total_rows += inserted
                    logger.info(f"Inserted {inserted} rows (total: {total_rows})")
                batch = []

        # Insert remaining rows
        if batch:
            if dry_run:
                logger.info(f"[DRY RUN] Would insert {len(batch)} rows")
            else:
                inserted = insert_batch(conn, table, schema["columns"], batch, json_columns, skip_insert_columns)
                total_rows += inserted
                logger.info(f"Inserted {inserted} rows (total: {total_rows})")

        logger.info(f"Migration complete! Total rows: {total_rows}")
        return total_rows

    finally:
        conn.close()


def main():
    # Use config defaults if available
    db_defaults = DB_CONFIG if HAS_CONFIG else {}
    migration_defaults = MIGRATION_CONFIG if HAS_CONFIG else {}

    parser = argparse.ArgumentParser(
        description="Load CSV data into CockroachDB",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Examples:
  python load_csv.py --csv-file test_mindshare_user.csv --table mindshare_user
  python load_csv.py --csv-file data.csv --table mindshare_user --db-host localhost --batch-size 500
  python load_csv.py --csv-file data.csv --table mindshare_user --dry-run

Config: {"Using config.py for defaults" if HAS_CONFIG else "No config.py found (using CLI defaults or copy config_example.py → config.py)"}
        """,
    )

    parser.add_argument(
        "--csv-file",
        type=Path,
        required=True,
        help="Path to CSV file to load",
    )
    parser.add_argument(
        "--table",
        required=True,
        help=f"Target table (schema.table or just table name). Supported: {', '.join(SCHEMAS.keys())}",
    )
    parser.add_argument(
        "--db-host",
        default=db_defaults.get("host", "localhost"),
        help="CockroachDB host (default: localhost)",
    )
    parser.add_argument(
        "--db-port",
        type=int,
        default=db_defaults.get("port", 26257),
        help="CockroachDB port (default: 26257)",
    )
    parser.add_argument(
        "--db-name",
        default=db_defaults.get("database", "defaultdb"),
        help="Database name (default: defaultdb)",
    )
    parser.add_argument(
        "--db-user",
        default=db_defaults.get("user", "root"),
        help="Database user (default: root)",
    )
    parser.add_argument(
        "--db-password",
        default=db_defaults.get("password", ""),
        help="Database password (default: empty)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=migration_defaults.get("batch_size", 1000),
        help="Batch size for inserts (default: 1000)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=migration_defaults.get("dry_run", False),
        help="Validate data without inserting",
    )
    # Get default skip_null_columns from config if available
    config_skip_cols = migration_defaults.get("skip_null_columns", [])
    default_skip_str = ",".join(config_skip_cols) if isinstance(config_skip_cols, list) else ""

    parser.add_argument(
        "--skip-null-columns",
        type=str,
        default=default_skip_str,
        help='Comma-separated list of columns: if NULL, skip the entire row (e.g., "x_username,display_name")',
    )

    args = parser.parse_args()

    try:
        skip_null_columns = [c.strip() for c in args.skip_null_columns.split(",") if c.strip()]
        total = migrate_table(
            csv_file=args.csv_file,
            table=args.table,
            db_host=args.db_host,
            db_port=args.db_port,
            db_name=args.db_name,
            db_user=args.db_user,
            db_password=args.db_password,
            batch_size=args.batch_size,
            dry_run=args.dry_run,
            skip_null_columns=skip_null_columns,
        )
        logger.info(f"Success! Migrated {total} rows")
        return 0
    except Exception as e:
        logger.error(f"Migration failed: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
