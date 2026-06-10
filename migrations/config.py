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
    "host": "nucleus-prod-25259.j77.aws-us-east-2.cockroachlabs.cloud",      # CockroachDB hostname
    "port": 26257,            # CockroachDB port (default: 26257)
    "database": "nucleus-prod",  # Database name
    "user": "srj",           # Database user
    "password": "mqxwvIIOybx_n6LKvi-XSQ",           # Database password (empty = no auth)
    "schema": "mindshare"
}

# Migration settings
MIGRATION_CONFIG = {
    "batch_size": 10000,       # Rows per insert batch (higher = faster but uses more memory)
    "dry_run": False,         # IZf True, validate without inserting
    "log_level": "INFO",      # Log level: DEBUG, INFO, WARNING, ERROR
    "skip_null_columns": ["x_username", "display_name"],  # Add thi
}
