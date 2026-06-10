#!/bin/bash
# Migration runner script with sensible defaults
#
# Usage:
#   ./run_migration.sh mindshare_user test_mindshare_user.csv
#   CRDB_HOST=crdb.example.com ./run_migration.sh mindshare_user data.csv
#   ./run_migration.sh mindshare_user data.csv --dry-run

set -e

# Default configuration
CRDB_HOST="${CRDB_HOST:-localhost}"
CRDB_PORT="${CRDB_PORT:-26257}"
CRDB_DB="${CRDB_DB:-defaultdb}"
CRDB_USER="${CRDB_USER:-root}"
CRDB_PASSWORD="${CRDB_PASSWORD:-}"
BATCH_SIZE="${BATCH_SIZE:-1000}"

# Parse arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <table> <csv_file> [OPTIONS]"
    echo ""
    echo "Examples:"
    echo "  $0 mindshare_user test_mindshare_user.csv"
    echo "  $0 mindshare_user data.csv --dry-run"
    echo ""
    echo "Environment variables:"
    echo "  CRDB_HOST=localhost          CockroachDB host"
    echo "  CRDB_PORT=26257              CockroachDB port"
    echo "  CRDB_DB=defaultdb            Database name"
    echo "  CRDB_USER=root               Database user"
    echo "  CRDB_PASSWORD=               Database password"
    echo "  BATCH_SIZE=1000              Batch size for inserts"
    echo ""
    exit 1
fi

TABLE=$1
CSV_FILE=$2
shift 2

# Build command
CMD="python migrations/load_csv.py"
CMD="$CMD --table $TABLE"
CMD="$CMD --csv-file $CSV_FILE"
CMD="$CMD --db-host $CRDB_HOST"
CMD="$CMD --db-port $CRDB_PORT"
CMD="$CMD --db-name $CRDB_DB"
CMD="$CMD --db-user $CRDB_USER"
CMD="$CMD --batch-size $BATCH_SIZE"

# Add optional password if provided
if [ -n "$CRDB_PASSWORD" ]; then
    CMD="$CMD --db-password $CRDB_PASSWORD"
fi

# Add remaining arguments (e.g., --dry-run)
CMD="$CMD $@"

echo "Running: $CMD"
echo ""
eval "$CMD"
