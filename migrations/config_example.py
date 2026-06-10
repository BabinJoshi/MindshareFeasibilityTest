"""
Configuration for database migrations.

SETUP:
  1. Copy this file: cp config_example.py config.py
  2. Edit config.py with your actual credentials
  3. Run migrations - they will auto-load from config.py

The script checks for config.py on startup and uses these values as defaults.
Command-line arguments override config.py settings.
"""

# CockroachDB connection settings
DB_CONFIG = {
    "host": "localhost",      # CockroachDB hostname
    "port": 26257,            # CockroachDB port (default: 26257)
    "database": "defaultdb",  # Database name
    "user": "root",           # Database user
    "password": "",           # Database password (empty = no auth)
    "schema": "public",       # Database schema (default: public)
}

# Migration settings
MIGRATION_CONFIG = {
    "batch_size": 1000,       # Rows per insert batch (higher = faster but uses more memory)
    "dry_run": False,         # If True, validate without inserting
    "log_level": "INFO",      # Log level: DEBUG, INFO, WARNING, ERROR
}
