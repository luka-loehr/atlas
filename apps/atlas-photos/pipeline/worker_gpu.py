#!/usr/bin/env python3
"""GPU worker — sequential stage drainer for the 8GB card.

Loop: reap zombies; for each stage in [embed, faces, caption]: if pending jobs
exist -> load model, drain ALL jobs of that kind in batches, unload + free
VRAM; then sleep 30s. NEVER two models resident at once (vLLM alone claims 80%
of the card). Crash-safety comes from the queue protocol: claimed jobs are
heartbeated every 60s from a background thread, and anything 'running' with a
stale heartbeat is reaped back to 'pending' — power loss mid-job self-heals at
next boot, and all handlers are idempotent so re-runs never duplicate.

Runs as pipeline-gpu container (entrypoint: download_models.py, then this).
"""
import gc
import os
import signal
import socket
import threading
import time

import psycopg

import db
import jobqueue as jobq
from gpu_stages import EmbedStage, FaceStage, CaptionStage, free_cuda

WORKER = f"gpu:{socket.gethostname()}:{os.getpid()}"
REAP_EVERY = 300  # s
IDLE_SLEEP = 30   # s


# ------------------------------------------------------------------ queue ---
# claim/done/fail/reap come from jobqueue.py (shared with the CPU worker);
# db.py provides the connection (PG_ENV_FILE/PGHOST-aware).

def has_pending(conn, kind):
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM ingest_jobs WHERE status='pending' AND kind=%s "
                "AND run_after <= now() LIMIT 1", (kind,))
    return cur.fetchone() is not None


def retry_later(conn, job_id, why):
    """Requeue WITHOUT an attempts penalty — the input isn't ready yet
    (e.g. thumb not generated). Re-checked every 30 minutes."""
    conn.cursor().execute(
        """UPDATE ingest_jobs
           SET status='pending', locked_by=NULL, heartbeat_at=NULL,
               error=%s, run_after = now() + interval '30 minutes',
               updated_at = now()
           WHERE id = %s""", (str(why)[:500], job_id))


class Heartbeat(threading.Thread):
    """Bumps heartbeat_at every 60s for whatever jobs are currently claimed.
    Own connection — psycopg conns are not thread-safe for concurrent use."""

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.ids = []
        self.stop_ev = threading.Event()

    def track(self, job_ids):
        with self.lock:
            self.ids = list(job_ids)

    def run(self):
        conn = None
        while not self.stop_ev.wait(60):
            with self.lock:
                ids = list(self.ids)
            if not ids:
                continue
            try:
                if conn is None or conn.closed:
                    conn = db.connect()
                conn.cursor().execute(
                    "UPDATE ingest_jobs SET heartbeat_at=now() "
                    "WHERE id = ANY(%s) AND status='running'", (ids,))
            except Exception as e:
                print(f"heartbeat error: {e}", flush=True)
                conn = None


# ------------------------------------------------------------------- main ---

def vram():
    try:
        import torch
        if torch.cuda.is_available():
            free, total = torch.cuda.mem_get_info()
            return f"{(total - free) / 2**30:.1f}G"
    except Exception:
        pass
    return "n/a"


# stage.KIND -> monotonic time before which we skip the stage (load failed)
LOAD_BACKOFF_S = 15 * 60
_backoff_until = {}


def drain(conn, stage, hb, stop):
    """Drain ALL pending jobs of stage.KIND, model loaded exactly once."""
    if time.monotonic() < _backoff_until.get(stage.KIND, 0):
        return
    try:
        stage.load()
    except Exception as e:
        print(f"[{stage.KIND}] load failed: {type(e).__name__}: {e} "
              f"— backing off {LOAD_BACKOFF_S // 60} min", flush=True)
        _backoff_until[stage.KIND] = time.monotonic() + LOAD_BACKOFF_S
        # a half-initialized model (e.g. vLLM OOM mid-load) can leave VRAM
        # poisoned for every later stage — always tear down + free
        try:
            stage.unload()
        except Exception:
            pass
        gc.collect()
        free_cuda()
        return
    _backoff_until.pop(stage.KIND, None)
    try:
        while not stop.is_set():
            jobs = jobq.claim(conn, WORKER, [stage.KIND], stage.BATCH)
            if not jobs:
                break
            hb.track([j[0] for j in jobs])
            t0 = time.monotonic()
            try:
                results = stage.process_batch(conn, [(j[0], j[2]) for j in jobs])
            except Exception as e:  # whole batch down -> retry via queue
                results = [(j[0], f"batch crashed: {type(e).__name__}: {e}")
                           for j in jobs]
            ok = nfail = nretry = 0
            for jid, err in results:
                if err is None:
                    jobq.done(conn, jid)
                    ok += 1
                elif str(err).startswith("RETRY:"):
                    retry_later(conn, jid, err)   # input not ready — no penalty
                    nretry += 1
                else:
                    jobq.fail(conn, jid, err)
                    nfail += 1
            hb.track([])
            print(f"[{stage.KIND}] n={len(jobs)} ok={ok} fail={nfail} "
                  f"retry={nretry} {int((time.monotonic() - t0) * 1000)}ms "
                  f"vram={vram()}", flush=True)
    finally:
        hb.track([])
        try:
            stage.unload()
        except Exception as e:
            print(f"[{stage.KIND}] unload error: {e}", flush=True)
        gc.collect()
        free_cuda()


def main():
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())

    # cold boot ("power button is all"): postgres may still be starting —
    # wait for it instead of crash-looping the container
    conn = None
    while conn is None and not stop.is_set():
        try:
            conn = db.connect()
        except psycopg.OperationalError as e:
            print(f"waiting for postgres ({e}) ...", flush=True)
            stop.wait(5)
    if conn is None:
        return 0
    hb = Heartbeat()
    hb.start()
    stages = [EmbedStage(), FaceStage(), CaptionStage()]
    print(f"{WORKER} up — stages: {[s.KIND for s in stages]}", flush=True)

    last_reap = 0.0
    while not stop.is_set():
        try:
            if conn.closed:
                conn = db.connect()
            if time.monotonic() - last_reap > REAP_EVERY:
                jobq.reap(conn)
                last_reap = time.monotonic()
            for stage in stages:
                if stop.is_set():
                    break
                if has_pending(conn, stage.KIND):
                    drain(conn, stage, hb, stop)
        except psycopg.OperationalError as e:
            print(f"db connection lost ({e}), reconnecting ...", flush=True)
            try:
                conn.close()
            except Exception:
                pass
            stop.wait(5)
            continue
        stop.wait(IDLE_SLEEP)

    hb.stop_ev.set()
    print(f"{WORKER} stopped", flush=True)


if __name__ == "__main__":
    main()
