#!/usr/bin/env python3
"""atlas-photos CPU worker.

Loop: reap (startup + every 5 min) -> claim(['thumb','meta','geocode',
'event_scan'], 8) -> thumb/meta/geocode on a ThreadPool(4), event_scan inline
in the main thread -> settle done/fail -> idle sleep 15s. A Heartbeater
daemon beats claimed job ids every 60s so a crashed worker's jobs are reaped
after 10 min. Graceful SIGTERM/SIGINT: finish the current batch, exit 0.
One-line log per job: kind id ms status.
"""
import logging
import os
import signal
import socket
import sys
import threading
import time

import psycopg

import db
import handlers_cpu
import jobqueue as jobq

from concurrent.futures import ThreadPoolExecutor, wait  # after jobq import

KINDS = ["thumb", "meta", "geocode", "event_scan"]
THREAD_HANDLERS = {
    "thumb": handlers_cpu.thumb,
    "meta": handlers_cpu.meta,
    "geocode": handlers_cpu.geocode,
}
CLAIM_BATCH = 8
POOL_SIZE = 4
REAP_EVERY_S = 300
IDLE_SLEEP_S = 15

WORKER = f"cpu:{socket.gethostname()}:{os.getpid()}"
STOP = threading.Event()
HB = jobq.Heartbeater()

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(message)s",
                    datefmt="%Y-%m-%dT%H:%M:%S")
log = logging.getLogger("worker_cpu")


def _on_signal(signum, _frame):
    log.info("signal %s — finishing current batch, then exiting", signum)
    STOP.set()


def _settle_fail(job, exc):
    try:
        jobq.fail(db.get_conn(), job.id, f"{type(exc).__name__}: {exc}")
    except Exception:
        db.reset_conn()  # job stays 'running'; reap() requeues it in <=10 min


def _run_job(job):
    """Pool thread: run a thumb/meta/geocode handler on this thread's own
    connection, then settle the job."""
    t0 = time.monotonic()
    status = "done"
    try:
        conn = db.get_conn()
        THREAD_HANDLERS[job.kind](conn, job.owner_id)
        jobq.done(conn, job.id)
    except Exception as e:
        status = "failed"
        if isinstance(e, (psycopg.OperationalError, psycopg.InterfaceError)):
            db.reset_conn()
        _settle_fail(job, e)
    finally:
        HB.discard([job.id])
    log.info("%s %s %dms %s",
             job.kind, job.owner_id, (time.monotonic() - t0) * 1000, status)


def _run_event_scan(job):
    """Main thread: event_scan reschedules its own job row (run_after=+6h)
    inside the handler's transaction instead of done()."""
    t0 = time.monotonic()
    status = "requeued"
    try:
        handlers_cpu.event_scan(db.get_conn(), job.id)
    except Exception as e:
        status = "failed"
        if isinstance(e, (psycopg.OperationalError, psycopg.InterfaceError)):
            db.reset_conn()
        _settle_fail(job, e)
    finally:
        HB.discard([job.id])
    log.info("%s %s %dms %s",
             job.kind, job.owner_id, (time.monotonic() - t0) * 1000, status)


def _connect_with_retry():
    while not STOP.is_set():
        try:
            return db.connect()
        except Exception as e:
            log.info("db not reachable (%s) — retrying in 5s", e)
            STOP.wait(5)
    return None


def main():
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)
    log.info("worker %s starting", WORKER)

    conn = _connect_with_retry()
    if conn is None:
        return 0
    jobq.enqueue(conn, "event_scan", "singleton")  # ON CONFLICT => free
    # the singleton must NEVER die permanently: a 'failed' row would block the
    # ON CONFLICT enqueue forever — revive it on every worker start
    conn.execute(
        """UPDATE ingest_jobs
              SET status='pending', attempts=0, error=NULL,
                  run_after=now(), updated_at=now()
            WHERE kind='event_scan' AND owner_type='system'
              AND owner_id='singleton' AND status='failed'""")
    jobq.reap(conn)
    last_reap = time.monotonic()

    HB.start()
    pool = ThreadPoolExecutor(max_workers=POOL_SIZE)

    while not STOP.is_set():
        try:
            if time.monotonic() - last_reap >= REAP_EVERY_S:
                jobq.reap(conn)
                last_reap = time.monotonic()
            jobs = jobq.claim(conn, WORKER, KINDS, CLAIM_BATCH)
        except psycopg.Error as e:
            log.info("db error in claim/reap (%s) — reconnecting", e)
            try:
                conn.close()
            except Exception:
                pass
            conn = _connect_with_retry()
            if conn is None:
                break
            continue

        if not jobs:
            STOP.wait(IDLE_SLEEP_S)
            continue

        HB.add(j.id for j in jobs)
        futures = [pool.submit(_run_job, j) for j in jobs if j.kind != "event_scan"]
        for j in jobs:
            if j.kind == "event_scan":
                _run_event_scan(j)
        wait(futures)  # finish the batch before claiming more (and before exit)

    pool.shutdown(wait=True)
    HB.stop()
    try:
        conn.close()
    except Exception:
        pass
    log.info("worker %s stopped cleanly", WORKER)
    return 0


if __name__ == "__main__":
    sys.exit(main())
