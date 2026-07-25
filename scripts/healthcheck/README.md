# atlas-healthcheck

One-shot health check for the atlas box: proves the Rust components still
compile and the core services are actually up. No timer, no polling — it runs
once on boot, once after resume from suspend, and on demand, so it never keeps
the sleep-when-idle box awake.

## What it checks

| Check | How |
|---|---|
| `build-agent` | `cargo check --locked` in `~/atlas/agent` |
| `build-cli` | `cargo check --locked` in `~/atlas/cli` |
| `agent-http` | `GET 127.0.0.1:8787/api/metrics` → 200 (or 401 when `ATLAS_AGENT_TOKEN` auth is on — server up either way) |
| `photos-http` | `GET 127.0.0.1:8788/api/albums` → 200/401 |
| `docker-stack` | `atlas-postgres` running+healthy, `atlas-pipeline-{pipeline-gpu,pipeline-cpu,embed-api}-1` running |
| `postgres` | `pg_isready` + `SELECT 1` as user `atlas`, db `atlas`, inside the container |

Service checks retry (default 12 × 10 s under systemd, 3 × 10 s interactive —
override with `ATLAS_HEALTH_RETRIES` / `ATLAS_HEALTH_RETRY_SLEEP`) because
containers need a moment after boot/resume. Build checks run once.

## Where to see results

- `~/atlas-health/status.json` — machine-readable result of the last run
  (overall `ok`, per-check `ok`/`seconds`/`detail` incl. compiler errors)
- `~/atlas-health/last-run.log` — full log of the last run
- `~/atlas-health/history.log` — one line per run, e.g. `2026-07-25T16:00:00Z OK`
  or `… FAIL: build-cli`
- `systemctl status atlas-healthcheck` — the boot/on-demand unit shows
  failed when the last check was red

## Install / run

```sh
~/atlas/scripts/healthcheck/install.sh        # install + enable both units
sudo systemctl start atlas-healthcheck        # run now via systemd
~/atlas/scripts/healthcheck/atlas-healthcheck.sh   # or run directly
```

Exit code 0 = all green, 1 = at least one check failed.

## Files

- `atlas-healthcheck.sh` — the check itself
- `atlas-healthcheck.service` — runs on boot (`WantedBy=multi-user.target`)
- `atlas-healthcheck-resume.service` — runs after resume (standard systemd
  resume hook: `WantedBy` + `After` the sleep targets)
- `install.sh` — copies units to `/etc/systemd/system`, enables them
