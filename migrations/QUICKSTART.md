# Migration Quickstart

## What You Have

A production-ready Python migration suite in the `migrations/` folder for loading PostgreSQL CSV dumps into CockroachDB.

## Files

| File | Purpose |
|------|---------|
| **load_csv.py** | Main migration script (the real implementation) |
| **test_migration.py** | Test CSV parsing without database connection |
| **run_migration.sh** | Bash wrapper for easier command-line usage |
| **config_example.py** | Configuration template |
| **README.md** | Comprehensive documentation |
| **QUICKSTART.md** | This file |

## Quick Start (3 steps)

### 1. Setup Config (optional but recommended)

Copy the config template and edit with your actual credentials:

```bash
cp migrations/config_example.py migrations/config.py
# Edit config.py with your CockroachDB host, port, user, password
```

Then the script will automatically use these defaults—no need to pass them every time.

### 2. Test CSV Parsing

Verify your CSV file parses correctly without connecting to a database:

```bash
python3 migrations/test_migration.py
```

This validates:
- CSV can be read
- All values convert to correct types
- No parsing errors

### 3. Run Migration

**Option A: With config.py (simplest)**
```bash
# After setting up config.py with your credentials
python3 migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user
```

**Option B: Command-line args (one-off, overrides config.py)**
```bash
python3 migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --db-host crdb.example.com \
  --db-user myuser \
  --db-password mypassword
```

**Option C: Bash Wrapper (env-based, no config file)**
```bash
# Set environment variables
export CRDB_HOST=localhost
export CRDB_USER=root
export CRDB_DB=defaultdb

# Run migration
bash migrations/run_migration.sh mindshare_user test_mindshare_user.csv
```

**Option D: Dry-Run First (validate without inserting)**
```bash
python3 migrations/load_csv.py \
  --csv-file test_mindshare_user.csv \
  --table mindshare_user \
  --dry-run
```

## What Gets Migrated

**mindshare_user table** ← test_mindshare_user.csv

| Column | Type | Conversion |
|--------|------|-----------|
| x_id | VARCHAR(50) | Quoted strings |
| x_username | VARCHAR(255) | Unquoted text |
| display_name | VARCHAR(255) | Unquoted text (handles emoji) |
| score | NUMERIC(10,2) | String → Float |
| avatar_url | VARCHAR(1000) | URLs preserved |
| adjustment_config | JSONB | String → JSON dict |
| followers_count | INT4 | String → Int |
| verified | BOOL | "true"/"false" → Boolean |
| created_at | TIMESTAMPTZ | "2026-03-10 06:50:39.284 +0545" → timestamp with tz |
| updated_at | TIMESTAMPTZ | (same as above) |
| last_score_fetched_at | TIMESTAMPTZ | (same as above) |

## Tested

✅ CSV parsing with:
- Unicode characters (emoji, non-ASCII)
- Quoted fields with commas
- Nested JSON in JSONB fields
- Timezone-aware timestamps in +HHMM format
- Quoted x_id values
- NULL handling

✅ Type conversion with:
- Boolean string values
- Float/Int parsing
- JSON deserialization
- Timestamp parsing with Nepal timezone (+05:45)

## Adding More Tables

To support additional tables (e.g., `mindshare_post`, `user_post`), add them to `SCHEMAS` in `load_csv.py`:

```python
SCHEMAS = {
    # ... existing tables ...
    "new_table": {
        "columns": ["col1", "col2", "col3"],
        "converters": {
            "col1": str,
            "col2": int,
            "col3": lambda x: special_parser(x),
        },
    },
}
```

Then run:
```bash
python3 migrations/load_csv.py --table new_table --csv-file data.csv
```

## Common Issues

| Problem | Solution |
|---------|----------|
| "Connection refused" | Verify CockroachDB running on host/port |
| "permission denied" | Check database user has INSERT permissions |
| "column mismatch" | Ensure CSV columns match table schema |
| "type conversion error" | Check CSV data format (see test output) |
| "Out of memory" | Reduce `--batch-size` (default 1000) |

## Next Steps

1. Run `test_migration.py` to validate your CSV
2. Check the `README.md` for detailed options
3. For other tables, add schema definitions and re-run
4. Monitor performance with large datasets
