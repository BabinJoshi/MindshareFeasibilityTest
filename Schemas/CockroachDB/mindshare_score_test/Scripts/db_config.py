#!/usr/bin/env python3
"""
Connection configuration for the decay-score scripts.

Loads environment variables from the repo-root .env via python-dotenv
(find_dotenv walks up from this file's directory, so the scripts work from
any cwd). Real environment variables take precedence over .env values.

Resolution order for the DSN:
  1. DATABASE_URL                                  (full connection string)
  2. DB_USER / DB_PASSWORD / DB_HOST / DB_PORT /
     DB_NAME / DB_SSLMODE                           (assembled into a DSN)
  3. local-insecure default  postgresql://root@localhost:26257/defaultdb?sslmode=disable
"""

from __future__ import annotations

import os
from urllib.parse import quote

from dotenv import find_dotenv, load_dotenv

load_dotenv(find_dotenv(usecwd=False))


def _normalize_scheme(url: str) -> str:
    """Rewrite SQLAlchemy-style schemes (cockroachdb://, cockroachdb+asyncpg://,
    postgresql+psycopg2://, postgres://, ...) to the plain postgresql:// that
    psycopg2/libpq understands. Everything after :// is kept as-is."""
    scheme, sep, rest = url.partition("://")
    if not sep:
        return url
    base = scheme.split("+", 1)[0].lower()
    if base in ("cockroachdb", "crdb", "postgres", "postgresql"):
        return f"postgresql://{rest}"
    return url


def get_dsn() -> str:
    """CockroachDB connection string from the environment / .env."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return _normalize_scheme(url)

    user     = os.environ.get("DB_USER", "root")
    password = os.environ.get("DB_PASSWORD", "")
    host     = os.environ.get("DB_HOST", "localhost")
    port     = os.environ.get("DB_PORT", "26257")
    name     = os.environ.get("DB_NAME", "defaultdb")
    sslmode  = os.environ.get("DB_SSLMODE", "disable")

    auth = quote(user, safe="")
    if password:
        auth += f":{quote(password, safe='')}"
    return f"postgresql://{auth}@{host}:{port}/{name}?sslmode={sslmode}"
