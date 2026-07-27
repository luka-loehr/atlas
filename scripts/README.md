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
| [`disk-guard/`](disk-guard/) | Five-minute check that root is not filling up — 85/90/95% thresholds, a burn-rate trend trigger, an 80 G floor below which builds refuse to start, alerts via `report-to-hermes` |
| [`photo-triage/`](photo-triage/) | Keyboard-driven web UI to review delete candidates (screenshots, blurry, black frames, documents) |
| [`vecmap/`](vecmap/) | UMAP layout + sprite-atlas pipeline and two WebGL viewers — the photo library as a 3D point cloud at `/map` |
| `takeout-transfer.sh` | Watches the client's `~/Downloads` and moves finished Takeout zip parts to the server |
| `cargo-dev-profile.sh` | One-shot: sets `debug = "line-tables-only"` for dev/test builds machine-wide, refusing to land while any build or agent run is live |

## cargo-dev-profile.sh

Writes `[profile.dev]`/`[profile.test]` `debug = "line-tables-only"` into
`~/.cargo/config.toml`, so every Rust tree on the box — including per-issue
worktrees checked out later — drops the type and variable DWARF while keeping
file/line backtraces. It goes in the cargo config rather than a manifest
because dairo has several per-issue worktrees live at once and a manifest
change would surface as an unrelated diff in all of them.

Measured on this box (serde/serde\_json probe, 2026-07-27): DWARF 5.74 MB →
4.39 MB, linked binary 6.34 MB → 4.98 MB, **~21 % smaller**, and a panic still
reports `at ./src/main.rs:9:13`. Expect more on a first-party-heavy crate like
`dairo-api` and less on a thin one — but not the "more than half" figure that
gets quoted for this setting.

Two things make the timing matter, which is why this is a guarded script and
not a one-line edit:

- Profile settings are part of cargo's fingerprint, so the first build in
  **every** tree afterwards is a full cold rebuild. Landing it while agents are
  mid-run hands each of them a surprise cold build.
- Cargo has no garbage collector. It builds the new artifacts *alongside* the
  old ones under new hashes rather than replacing them — `dairo-backend`'s
  `target/` already carries four distinct `libserde` builds for this reason. So
  `target/` grows before it shrinks. Clear the dead trees first.

```bash
./cargo-dev-profile.sh                  # status / dry run — safe any time
./cargo-dev-profile.sh --apply --reap   # reap dead target/ trees, then land
```

It exits non-zero with `HOLD` if any `cargo`/`rustc` process or any other
`/tmp/atlas-run-*` scratch dir exists (its own run is excluded), so it
is safe to retry from a timer or a heartbeat until a window opens. `--force`
overrides the guard; `--reap` shells out to [`cargo-reaper/`](cargo-reaper/)
first. Re-running after a successful apply is a no-op.

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
