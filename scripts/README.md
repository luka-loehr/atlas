# scripts — operational tools

Small tools around the photo stack that don't belong to a service: a
one-shot transfer watcher for Google Takeout archives, a web UI for
triaging junk photos, and a pipeline that renders the whole photo library
as a 3D embedding map. `photo-triage/` and `vecmap/` talk to the running
[atlas-photos](../apps/atlas-photos/) stack; machine-level setup lives in
[docs/SETUP.md](../docs/SETUP.md).

| Path | What it is |
|---|---|
| [`healthcheck/`](healthcheck/) | One-shot box health check (cargo builds, agent :8787, docker stack, Postgres) — runs on boot/resume/on demand, results in `~/atlas-health/status.json` |
| [`firewall/`](firewall/) | Host firewall confining atlas-agent :8787 and atlas-photos :8788 to loopback and the tailnet — nftables rules plus the unit that reloads them at boot |
| [`pg-backup/`](pg-backup/) | Nightly `pg_dump` of the atlas database to `/srv/backups/atlas-postgres/`, plus a restore drill |
| [`cargo-reaper/`](cargo-reaper/) | Daily sweep that deletes cargo `target/` dirs from finished issue worktrees, skipping any tree an agent is still building in |
| [`photo-triage/`](photo-triage/) | Keyboard-driven web UI to review delete candidates (screenshots, blurry, black frames, documents) |
| [`vecmap/`](vecmap/) | UMAP layout + sprite-atlas pipeline and two WebGL viewers — the photo library as a 3D point cloud at `/map` |
| `takeout-transfer.sh` | Watches the client's `~/Downloads` and moves finished Takeout zip parts to the server |

## takeout-transfer.sh

Polling loop (every 30 s) for multi-part Google Takeout downloads: each
completed `takeout-*.zip` in `~/Downloads` is rsynced to
`<server>:~/takeout/photos/`, its remote size is verified, and only then is
the local copy deleted. Parts still downloading are skipped (`.crdownload`
marker plus a size-stability check), browser duplicate suffixes like
`" (1)".zip` are normalized, and a part already on the server with matching
size is treated as a duplicate. One log line per event, so it pairs well
with any notification wrapper.

```bash
./takeout-transfer.sh          # runs until interrupted
```

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_SSH_HOST` | `atlas` | ssh/rsync target (host alias from `~/.ssh/config`; prefer a direct LAN alias over a relayed route for 50 GB parts) |
| `REMOTE_DIR` | `takeout/photos` | destination directory on the server, relative to the remote `$HOME` |
| `TAKEOUT_GLOB` | `takeout-*.zip` | which files to pick up — narrow it to one export's timestamp (e.g. `takeout-20260101T000000Z-*.zip`) to leave other Takeout downloads alone |

Notes: the local size check uses BSD `stat -f%z` (macOS); the remote check
uses GNU `stat -c%s` (Linux). Verification is size-only, not a checksum.
