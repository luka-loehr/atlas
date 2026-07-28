"""The ask store — our own agent→Luka question channel.

Paperclip has its own interaction/approval machinery, but it is built for
governance: half the fields are optional, questions arrive with no title and no
prompt, and the UI ends up asking Luka to rule on things he never wanted to see.

This replaces it with something deliberately small. An agent asks ONE clear
question, optionally proposing answers. Luka taps one, or writes his own. The
agent gets a string back. That is the whole contract.
"""

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path

DB_PATH = Path.home() / ".paperclip" / "asks.db"
_lock = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS asks (
    id           TEXT PRIMARY KEY,
    created_at   REAL NOT NULL,
    agent        TEXT NOT NULL,
    issue        TEXT,
    headline     TEXT NOT NULL,
    detail       TEXT,
    options      TEXT NOT NULL,   -- JSON array of {label, value, kind}
    urgency      TEXT NOT NULL DEFAULT 'normal',
    status       TEXT NOT NULL DEFAULT 'pending',
    answer       TEXT,
    answered_at  REAL
);
CREATE INDEX IF NOT EXISTS asks_status ON asks(status, created_at);

"""


def connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def create(agent: str, headline: str, detail: str | None, options: list,
           issue: str | None = None, urgency: str = "normal") -> dict:
    """Register a question. `options` are suggestions — Luka can always free-type."""
    ask_id = uuid.uuid4().hex[:12]
    now = time.time()
    normalized = []
    for opt in options or []:
        if isinstance(opt, str):
            normalized.append({"label": opt, "value": opt, "kind": "neutral"})
        else:
            normalized.append({
                "label": opt.get("label") or opt.get("value") or "OK",
                "value": opt.get("value") or opt.get("label") or "OK",
                "kind": opt.get("kind", "neutral"),  # affirm | reject | neutral
            })
    with _lock, connect() as conn:
        conn.execute(
            "INSERT INTO asks (id, created_at, agent, issue, headline, detail, options, urgency)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (ask_id, now, agent, issue, headline, detail,
             json.dumps(normalized), urgency),
        )
    return get(ask_id)


def get(ask_id: str) -> dict | None:
    with _lock, connect() as conn:
        row = conn.execute("SELECT * FROM asks WHERE id = ?", (ask_id,)).fetchone()
    return _row(row) if row else None


def pending() -> list:
    with _lock, connect() as conn:
        rows = conn.execute(
            "SELECT * FROM asks WHERE status = 'pending' ORDER BY created_at DESC"
        ).fetchall()
    return [_row(r) for r in rows]


def recent(limit: int = 30) -> list:
    with _lock, connect() as conn:
        rows = conn.execute(
            "SELECT * FROM asks ORDER BY created_at DESC LIMIT ?", (limit,)
        ).fetchall()
    return [_row(r) for r in rows]


def answer(ask_id: str, text: str) -> dict | None:
    with _lock, connect() as conn:
        cur = conn.execute(
            "UPDATE asks SET status='answered', answer=?, answered_at=?"
            " WHERE id=? AND status='pending'",
            (text, time.time(), ask_id),
        )
        if cur.rowcount == 0:
            row = conn.execute("SELECT * FROM asks WHERE id = ?", (ask_id,)).fetchone()
            return _row(row) if row else None
    return get(ask_id)


def cancel(ask_id: str) -> None:
    with _lock, connect() as conn:
        conn.execute(
            "UPDATE asks SET status='cancelled' WHERE id=? AND status='pending'",
            (ask_id,),
        )


def _row(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"],
        "createdAt": row["created_at"],
        "agent": row["agent"],
        "issue": row["issue"],
        "headline": row["headline"],
        "detail": row["detail"],
        "options": json.loads(row["options"]),
        "urgency": row["urgency"],
        "status": row["status"],
        "answer": row["answer"],
        "answeredAt": row["answered_at"],
    }
