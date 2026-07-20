#!/usr/bin/env python3
"""Crash-safe, no-duplicate job queue on top of ingest_jobs (migration 003
adds priority, run_after, locked_by, heartbeat_at, created_at).

Protocol (see pipeline contract):
  enqueue   ON CONFLICT (kind, owner_type, owner_id) DO NOTHING
  claim     single UPDATE ... FOR UPDATE SKIP LOCKED  (no double-claim ever)
  heartbeat every 60s from a Heartbeater thread while working
  done/fail terminal transitions; fail retries up to 5x with linear backoff
  reap      running jobs whose heartbeat is >10 min stale go back to pending
            => power loss mid-job self-heals at the next worker start

All connections are autocommit; every call here is one small transaction.

NOTE ON THE MODULE NAME: this file shadows the stdlib `queue` module whenever
the pipeline directory is first on sys.path (i.e. `python worker_cpu.py`).
Library code — concurrent.futures, multiprocessing — does `import queue` and
would land here, so we load the real stdlib module below and re-export its
public names, making this module a strict superset of stdlib queue.
"""
import importlib.util
import os
import sys
import sysconfig
import threading
from collections import namedtuple

# ------------------------------------------------ stdlib-queue re-export ----


def _load_stdlib_queue():
    path = os.path.join(sysconfig.get_paths()["stdlib"], "queue.py")
    spec = importlib.util.spec_from_file_location("_pipeline_stdlib_queue", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["_pipeline_stdlib_queue"] = mod
    spec.loader.exec_module(mod)
    return mod


try:
    _stdlib_queue = _load_stdlib_queue()
    for _name in getattr(_stdlib_queue, "__all__", ()):
        globals()[_name] = getattr(_stdlib_queue, _name)
except Exception:  # pragma: no cover — pipeline code itself never needs it
    pass

import db

MAX_ATTEMPTS = 5

Job = namedtuple("Job", "id kind owner_id")


# ------------------------------------------------------------- protocol -----

def enqueue(conn, kind, owner_id, priority=100):
    """Idempotent insert. owner_type is always 'asset' except the event_scan
    singleton which is ('event_scan', 'system', 'singleton')."""
    owner_type = "asset"
    if kind == "event_scan":
        owner_type, owner_id = "system", "singleton"
    conn.execute(
        """INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
           VALUES (%s, %s, %s, %s)
           ON CONFLICT (kind, owner_type, owner_id) DO NOTHING""",
        (kind, owner_type, owner_id, priority))


def claim(conn, worker, kinds, limit):
    """Atomically claim up to `limit` due jobs. Single statement; SKIP LOCKED
    makes concurrent workers never grab the same row."""
    rows = conn.execute(
        """UPDATE ingest_jobs
              SET status = 'running', locked_by = %s,
                  heartbeat_at = now(), updated_at = now()
            WHERE id IN (SELECT id FROM ingest_jobs
                          WHERE status = 'pending'
                            AND kind = ANY(%s)
                            AND run_after <= now()
                          ORDER BY priority, id
                          LIMIT %s
                          FOR UPDATE SKIP LOCKED)
        RETURNING id, kind, owner_id""",
        (worker, list(kinds), limit)).fetchall()
    return [Job(*r) for r in rows]


def heartbeat(conn, job_ids):
    if not job_ids:
        return
    conn.execute(
        """UPDATE ingest_jobs
              SET heartbeat_at = now(), updated_at = now()
            WHERE id = ANY(%s) AND status = 'running'""",
        (list(job_ids),))


def done(conn, job_id):
    conn.execute(
        """UPDATE ingest_jobs
              SET status = 'done', error = NULL, updated_at = now()
            WHERE id = %s""",
        (job_id,))


def fail(conn, job_id, err):
    """attempts+1; >=5 attempts => failed, else back to pending with
    run_after = now() + attempts * 5 min (linear backoff)."""
    conn.execute(
        """UPDATE ingest_jobs
              SET attempts = attempts + 1,
                  error = %s,
                  status = CASE WHEN attempts + 1 >= %s
                                THEN 'failed' ELSE 'pending' END,
                  run_after = now() + (attempts + 1) * interval '5 min',
                  locked_by = NULL, heartbeat_at = NULL, updated_at = now()
            WHERE id = %s""",
        (str(err)[:2000], MAX_ATTEMPTS, job_id))


def reap(conn):
    """Requeue running jobs with a stale (>10 min) heartbeat — crashed or
    power-cycled workers. Called at worker startup and every 5 min.
    (heartbeat_at IS NULL covers legacy 'running' rows from before 003.)"""
    conn.execute(
        """UPDATE ingest_jobs
              SET status = 'pending', locked_by = NULL, updated_at = now()
            WHERE status = 'running'
              AND (heartbeat_at IS NULL
                   OR heartbeat_at < now() - interval '10 minutes')""")


# ----------------------------------------------------------- heartbeater ----

class Heartbeater(threading.Thread):
    """Daemon thread that beats every registered job id each `interval`
    seconds on its own dedicated connection until stop()."""

    def __init__(self, interval=60.0):
        super().__init__(name="heartbeater", daemon=True)
        self._interval = interval
        self._stopev = threading.Event()
        self._lock = threading.Lock()
        self._ids = set()
        self._conn = None

    def add(self, job_ids):
        with self._lock:
            self._ids.update(job_ids)

    def discard(self, job_ids):
        with self._lock:
            self._ids.difference_update(job_ids)

    def stop(self):
        self._stopev.set()

    def run(self):
        while not self._stopev.wait(self._interval):
            with self._lock:
                ids = sorted(self._ids)
            if not ids:
                continue
            try:
                if self._conn is None or self._conn.closed:
                    self._conn = db.connect()
                heartbeat(self._conn, ids)
            except Exception:
                try:
                    if self._conn is not None:
                        self._conn.close()
                except Exception:
                    pass
                self._conn = None  # reconnect on the next beat
