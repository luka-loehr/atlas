#!/usr/bin/env python3
"""psycopg3 connection helpers for the atlas-photos pipeline.

POSTGRES_PASSWORD comes from $PG_ENV_FILE (default /secrets/.env inside the
containers, fallback ~/atlas/backend/docker/.env for bare-metal runs on atlas).
All connections are autocommit=True; handlers that need multi-statement
atomicity open an explicit `with conn.transaction():` block.
"""
import os
import threading

import psycopg

DEFAULT_ENV_FILE = "/secrets/.env"
FALLBACK_ENV_FILE = os.path.expanduser("~/atlas/backend/docker/.env")


def _password():
    candidates = []
    explicit = os.environ.get("PG_ENV_FILE")
    if explicit:
        candidates.append(explicit)
    else:
        candidates.extend([DEFAULT_ENV_FILE, FALLBACK_ENV_FILE])
    for path in candidates:
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("POSTGRES_PASSWORD="):
                    return line.split("=", 1)[1].strip()
    raise RuntimeError(
        f"POSTGRES_PASSWORD not found in any of: {candidates} "
        "(set PG_ENV_FILE or mount /secrets/.env)")


def connect() -> psycopg.Connection:
    """Fresh autocommit connection to the atlas db."""
    return psycopg.connect(
        host=os.environ.get("PGHOST", "127.0.0.1"),
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "atlas"),
        user=os.environ.get("PGUSER", "atlas"),
        password=_password(),
        autocommit=True,
        connect_timeout=10,
    )


# ------------------------------------------------- per-thread connection ----
# Worker pool threads each keep one connection; psycopg connections are not
# safe for concurrent use across threads.

_local = threading.local()


def get_conn() -> psycopg.Connection:
    conn = getattr(_local, "conn", None)
    if conn is not None and not conn.closed:
        return conn
    conn = connect()
    _local.conn = conn
    return conn


def reset_conn():
    """Drop this thread's cached connection (after an OperationalError);
    the next get_conn() reconnects."""
    conn = getattr(_local, "conn", None)
    _local.conn = None
    if conn is not None:
        try:
            conn.close()
        except Exception:
            pass
