# scripts — operational tools

Everything that keeps the box itself alive and honest, plus a few tools around
the photo stack that don't belong to any one service. Machine-level setup lives
in [docs/SETUP.md](../docs/SETUP.md).

Two shapes in here, and the difference is the naming convention:

- **A directory per component that systemd runs.** It contains the executable,
  its `atlas-*.service`/`.timer` units, an `install.sh` that copies them to
  `/etc/systemd/system` and enables them, and a `README.md`. Unit names carry
  the `atlas-` prefix because systemd is a global namespace; files inside the
  directory don't, because the directory already names them.
- **A loose `*.sh` at the top level** for one-shots you run by hand — no unit,
  no install step.

Two deliberate exceptions to the first shape: [`power-button/`](power-button/)
ships no `install.sh` (its README documents the two-line `cp` + `enable` by
hand), and [`proxy/`](proxy/)'s `caddy.service`/`cloudflared.service` carry no
`atlas-` prefix — they intentionally shadow the distro packages' units of the
same names (see the comment in `proxy/install.sh`).

Units run the scripts straight out of `~/atlas`, so re-run the relevant
`install.sh` after a pull that moves or renames one.

| Path | What it is |
|---|---|
| [`healthcheck/`](healthcheck/) | One-shot box health check (`api`/`cli` cargo builds, atlas-api :8787, atlas-photos :8788, docker stack, Postgres) — on boot, on resume, on demand; result in `~/atlas-health/status.json` |
| [`firewall/`](firewall/) | nftables table confining atlas-api :8787 and atlas-photos :8788 to loopback + tailnet, and the unit that loads it before the network comes up |
| [`disk-guard/`](disk-guard/) | Five-minute check that root is not filling up — 85/90/95 % thresholds, a burn-rate trend trigger, an 80 G floor below which builds refuse to start, alerts to the journal |
| [`pg-backup/`](pg-backup/) | Nightly `pg_dump` of the atlas database to `/srv/backups/atlas-postgres` with retention, plus a restore drill that verifies row counts |
| [`tailnet-dns/`](tailnet-dns/) | Publishes AdGuard as the tailnet's DNS while atlas is up and withdraws it at shutdown, so a sleeping box never blackholes the tailnet's DNS |
| [`power/`](power/) | Two host oneshots: keep Wake-on-LAN armed on the NIC, and make the Intel RAPL energy counters readable so atlas-api can report CPU power |
| [`power-button/`](power-button/) | Clean shutdown on three fast presses of the physical power button — logind is told to ignore the key and a small root daemon owns the gesture, because the firmware wins any long-press race |
| [`proxy/`](proxy/) | Host side of `atlas dev --public`: persistent Caddy + named Cloudflare Tunnel units behind the stable `*.lukaloehr.com` dev subdomains, with the one-time Cloudflare bootstrap (`setup.sh`) |
| [`ci-health/`](ci-health/) | Daily recorder for the self-hosted GitHub Actions runners on this box (units only — the checker lives outside this repo) |
| [`photo-triage/`](photo-triage/) | Keyboard-driven local web UI to review delete candidates (screenshots, blurry, black frames, documents), plus the two scoring scripts that find them |
| [`vecmap/`](vecmap/) | UMAP layout + sprite-atlas pipeline and two WebGL viewers — the photo library as a 3D point cloud, served at `/map` by atlas-photos |
| `takeout-transfer.sh` | Mac-side: watches `~/Downloads` and moves finished Google Takeout zip parts to the server |
| `cargo-dev-profile.sh` | Mac/server one-shot: sets `debug = "line-tables-only"` for dev/test builds machine-wide, refusing to land while any build is live |

`photo-triage/` and `vecmap/` are the only entries that need the
[atlas-photos](../apps/atlas-photos/) stack running; everything else is about
the machine.

## Units at a glance

| Unit | Schedule | Installed by |
|---|---|---|
| `atlas-healthcheck.service` | boot | [`healthcheck/install.sh`](healthcheck/install.sh) |
| `atlas-healthcheck-resume.service` | resume from suspend | ″ |
| `atlas-firewall.service` | boot, before the network | [`firewall/install.sh`](firewall/install.sh) |
| `atlas-disk-guard.timer` | every 5 min | [`disk-guard/install.sh`](disk-guard/install.sh) |
| `atlas-pg-backup.timer` | nightly 03:30 ± 10 min, `Persistent` | [`pg-backup/install.sh`](pg-backup/install.sh) |
| `atlas-tailnet-dns.service` | boot + shutdown (`ExecStop` is the point) | [`tailnet-dns/install.sh`](tailnet-dns/install.sh) |
| `atlas-wol.service`, `atlas-rapl-readable.service` | boot | [`power/install.sh`](power/install.sh) |
| `dairo-ci-health.timer` | daily 12:05 UTC, `Persistent` | [`ci-health/install.sh`](ci-health/install.sh) |
| `atlas-power-button.service` | boot | by hand — see [`power-button/`](power-button/) |
| `caddy.service`, `cloudflared.service` | boot (steady-state dev-proxy infra) | [`proxy/install.sh`](proxy/install.sh) |

Both calendar timers set `Persistent=true` for the same reason: atlas is
powered off whenever it is not needed, and a plain calendar schedule silently
drops every run that falls into a powered-off window. `atlas-disk-guard.timer`
is the exception on purpose — it is a monotonic every-5-minutes timer, and a
catch-up run of a "how full is the disk right now" check is worthless.

The API server's own unit is not here — it ships with the service, in
[`api/`](../api/), and is installed by `atlas api`.

## cargo-dev-profile.sh

Writes `[profile.dev]`/`[profile.test]` `debug = "line-tables-only"` into
`~/.cargo/config.toml`, so every Rust tree on the box — including ones
checked out later — drops the type and variable DWARF while keeping
file/line backtraces. It goes in the cargo config rather than a manifest
because a manifest change would surface as an unrelated diff in every
checkout of the repo.

Measured on this box (serde/serde\_json probe, 2026-07-27): DWARF 5.74 MB →
4.39 MB, linked binary 6.34 MB → 4.98 MB, **~21 % smaller**, and a panic still
reports `at ./src/main.rs:9:13`. Expect more on a first-party-heavy crate and
less on a thin one — but not the "more than half" figure that gets quoted for
this setting.

Two things make the timing matter, which is why this is a guarded script and
not a one-line edit:

- Profile settings are part of cargo's fingerprint, so the first build in
  **every** tree afterwards is a full cold rebuild. Landing it while a build
  is mid-run hands it a surprise cold rebuild.
- Cargo has no garbage collector. It builds the new artifacts *alongside* the
  old ones under new hashes rather than replacing them — a single `target/` on
  this box already carries four distinct `libserde` builds for this reason. So
  `target/` grows before it shrinks. Clear the dead trees first.

```bash
./cargo-dev-profile.sh          # status / dry run — safe any time
./cargo-dev-profile.sh --apply  # land it
```

It exits non-zero with `HOLD` if any `cargo`/`rustc` process is running, so it
is safe to retry from a timer or a heartbeat until a window opens. `--force`
overrides the guard. Re-running after a successful apply is a no-op.

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
