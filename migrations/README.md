# CSV to CockroachDB Migration

This directory contains tools for efficiently loading CSV data (from PostgreSQL dumps) into CockroachDB.

## Overview

The `load_csv.py` script provides:

- **Batch processing** — loads data in configurable chunks (default 1000 rows/batch) for efficiency
- **Type conversion** — automatically converts timestamps, JSON, booleans, and numeric types
- **Error handling** — detailed logging and transaction rollback on failure
- **Dry-run mode** — validate data without inserting
- **Flexible schema definitions** — easily add support for new tables

## Setup

1. Ensure dependencies are installed:
   ```bash
   uv sync
   ```

   The script requires `psycopg2-binary` (already in `pyproject.toml`).

2. (Optional) Create a local config file:
   ```bash
   cp config_example.py config.py
   # Edit config.py with your database credentials
   ```

## Usage

### Basic Usage

Load CSV data into the `mindshare_user` table:

```bash
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user
```

### With Custom Connection Settings

```bash
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --db-host crdb.example.com \
  --db-port 26257 \
  --db-user myuser \
  --db-password mypassword \
  --db-name mydatabase
```

### Dry-Run (Validate Without Inserting)

```bash
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --dry-run
```

### Custom Batch Size

```bash
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --batch-size 5000
```

## Supported Tables

Currently supported:
- `mindshare_user` — Twitter/X user data with scores and metadata

To add new tables, update the `SCHEMAS` dictionary in `load_csv.py`:

```python
SCHEMAS = {
    "your_table": {
        "columns": ["col1", "col2", ...],
        "converters": {
            "col1": str,
            "col2": int,
            "col3": lambda x: parse_special_format(x),
        },
    },
}
```

## Type Conversion

The script automatically converts common data types:

| CSV Value | Type | Example |
|-----------|------|---------|
| `"true"` / `"false"` | Boolean | `verified` |
| `"123.45"` | Float | `score` |
| `"123"` | Integer | `followers_count` |
| `{"key": "value"}` | JSON | `adjustment_config` |
| `"2026-03-10 06:50:39.284 +0545"` | Timestamp | `created_at` |
| Empty / `"NULL"` | NULL | Any column |

## Features

### Efficient Batch Insertion

Uses `psycopg2.extras.execute_batch()` for optimal performance with large datasets.

### Transaction Safety

- Each batch is wrapped in a transaction
- Errors roll back the batch and log details
- Progress is logged every batch

### Error Handling

- Invalid data types logged with row and column info
- Missing files caught before connection
- Database errors logged with detailed psycopg2 error info

### Logging

All operations logged to stdout with timestamps:
```
2026-06-08 10:30:45,123 - INFO - Starting migration for table: mindshare_user
2026-06-08 10:30:45,456 - INFO - CSV file: test_mindshare_user.csv
2026-06-08 10:30:45,789 - INFO - Inserted 1000 rows (total: 1000)
2026-06-08 10:30:45,999 - INFO - Migration complete! Total rows: 15
```

## Example: Full Migration Flow

```bash
# 1. Validate data first (dry-run)
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --dry-run

# 2. If dry-run succeeds, run actual migration
python migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --batch-size 2000

# 3. Verify in database
cockroach sql --database=defaultdb -e "SELECT COUNT(*) FROM mindshare.mindshare_user;"
```

## Troubleshooting

### Connection refused
- Verify CockroachDB is running on the specified host/port
- Default: `localhost:26257`
- Test with: `cockroach sql` CLI

### Authentication failed
- Check `--db-user` and `--db-password`
- Verify user exists and has INSERT permissions on the target table

### Type conversion errors
- Check CSV data format matches expectations (dates, JSON structure, etc.)
- Use `--dry-run` to identify problematic rows before inserting

### Out of memory
- Reduce `--batch-size` to process fewer rows per transaction
- Default 1000 is conservative; safe for most systems

## Performance Notes

- Batch insertion is ~10-100x faster than row-by-row inserts
- Default batch size (1000) balances speed and memory usage
- For 1M+ rows, consider increasing batch size to 5000-10000
- Timestamps with timezone offsets are parsed and converted to UTC

## Future Enhancements

Potential improvements:
- Support for partitioned table inserts (per-project keywords)
- Incremental migrations (skip already-loaded rows)
- Generated column handling (for computed booleans in `mindshare_post`)
- Multi-table migrations (load full schema at once)
