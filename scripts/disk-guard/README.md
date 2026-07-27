# disk-guard — notice root filling up, and tell someone

atlas has **one** physical device. `lsblk` shows `nvme0n1` carrying a single
950 G LVM volume, and everything is on it: the 536 G photo library, Postgres,
every service, `~/backups/`, and `/srv/backups/`. Filling root does not just
stop builds — it stops Postgres and destroys the room needed to restore, at the
same moment, with no off-volume copy. The blast radius is the whole box.

On 2026-07-27 the volume went **75% → 84% in about twenty minutes** (~1.8 G/min)
while several agents ran parallel `cargo test --workspace` builds. Nothing
noticed a nine-point climb. This is the thing that notices.

```bash
atlas-disk-guard --status        # where we are now, no alerts
atlas-disk-guard --require-free  # exit 1 if below the floor — the pre-build gate
atlas-disk-guard --json          # machine-readable, also written to ~/atlas-health/disk.json
sudo systemctl start atlas-disk-guard.service   # a full check, alerts included
```

Runs every five minutes via `atlas-disk-guard.timer`.

```bash
systemctl list-timers atlas-disk-guard.timer
journalctl -u atlas-disk-guard.service -n 50
journalctl -p err -b | grep disk-guard          # just the alerts
```

## The floor: 80 G

**Builds refuse to start below 80 GiB free.** That is the decision; here is the
arithmetic behind it, so anyone changing it redoes the arithmetic rather than
picking a rounder number.

- A cold full `cargo test --workspace` on the dairo workspace costs roughly
  20–35 G of `target/`. The largest tree observed was 35 G (`luk41`, and that
  one was inflated by a double-profile build); typical trees sit at 6–16 G.
- Six-plus build trees are live on this box at once, and the self-hosted GitHub
  Actions runner at `~/actions-runner-dairo` added a further one.
- 80 G therefore covers **two concurrent cold workspace builds** with room left,
  rather than one.
- At the measured peak burn of 1.8 G/min, 80 G is ~44 minutes of pure runaway —
  eight or nine timer intervals, enough for an alert to land and for
  `cargo-reaper` to run.
- It is 8.5% of the volume, so the floor and the 90% critical threshold
  (≈94 G free) sit close together on purpose: by the time percent-used says
  critical, the floor is the next thing you hit.
- Postgres, the pipeline containers and a ~200 MB nightly dump all need to keep
  writing while this is true.

## What fires an alert

| Level | Condition | report-to-hermes status |
|---|---|---|
| `warn` | ≥ 85% used | `in_review` |
| `critical` | ≥ 90% used, **or** free below the 80 G floor | `failed` |
| `emergency` | ≥ 95% used | `failed` |
| `warn` (trend) | green now, but the burn rate reaches the floor within 60 min for **two consecutive** intervals | `in_review` |
| recovery | back to ok after any alert | `done` |

The **trend trigger** is the part that would have caught 2026-07-27. Each run
stores `(timestamp, bytes used)` and the next one derives G/min from the delta,
so a build storm is visible while the box still looks fine on percentage. A
window shorter than 30 s or longer than an hour is discarded rather than
believed — that filters double-fires and reboot-sized gaps.

It needs **two consecutive hot intervals**, and that requirement was earned:
the first live run of this guard reported "1.91 G/min, 49 min from the floor"
and one minute later free space had gone *up* by 7 G. A build releasing its
intermediates makes a single interval read hot and the next read negative — free
space here oscillated 179 → 173 → 180 G inside three minutes. Two samples means
roughly ten minutes of sustained burn before anyone is told, costing ~18 G of
the 80 G headroom at the worst rate ever measured. Cheap, next to an alert
nobody trusts.

Percent is read as df's `Use%`, i.e. `used/(used+avail)`. That excludes the ~39 G
of root-reserved blocks from the denominator, so it is the number a non-root
writer actually runs out against. Root-owned writers (the docker daemon, hence
Postgres) get that reserve as a last cushion after everything else has failed —
which is the right way round, but do not plan on it.

Alerts go to Hermes through `report-to-hermes`, and to the journal at `err`
priority. **A failed send is not recorded as sent**, so the next run retries
rather than silently swallowing the only alert. Repeat alerts at an unchanged
level are suppressed for 6 h; an *escalation* is always sent immediately.

## The emergency hand-off

At `emergency` the guard runs `cargo-reaper.service` (`sudo -n systemctl start`,
synchronously) and reports how much it reclaimed alongside the alert. The reaper
has its own safety floor and only removes `target/` trees belonging to closed
issues that no process is using — see [`../cargo-reaper/`](../cargo-reaper/).

That is the **only** thing this guard ever deletes. It does not touch
`~/photos`, `~/drive/blobs`, Postgres, or `/srv/backups`. Set
`DISK_GUARD_EMERGENCY_REAP=0` to make the guard purely advisory.

## The pre-build gate

Any agent about to start a Rust build should gate on the floor:

```bash
atlas-disk-guard --require-free || exit 1
cargo test --workspace --locked
```

It prints the reclaim commands on refusal and exits 1. This is deliberately a
gate you call, not a wrapper that intercepts `cargo` — an interceptor that
misfires blocks every build on the box, and the cost of a missed gate is one
alert five minutes later.

## Verified

2026-07-27: `fallocate -l 50G /var/tmp/disk-guard-selftest.fill` took root from
81% to 86%. The guard reported `warn` and the payload arrived at the webhook;
escalation to `critical` and `emergency`, the 6 h suppression of an unchanged
level, the trend trigger at a synthesised 2 G/min, and the refusal from
`--require-free` were each exercised; one alert was sent through the live Hermes
webhook rather than a local capture. The fill was removed and the recovery
notice sent. `/var/tmp` was used because `/tmp` on this box is a 16 G tmpfs and
filling it would have consumed RAM, not disk.

## Tuning

| Variable | Default | Purpose |
|---|---|---|
| `DISK_GUARD_FLOOR_GIB` | `80` | the floor — read the arithmetic above before changing |
| `DISK_GUARD_WARN_PCT` | `85` | warn threshold |
| `DISK_GUARD_CRIT_PCT` | `90` | critical threshold |
| `DISK_GUARD_EMERG_PCT` | `95` | emergency threshold, and the reap hand-off |
| `DISK_GUARD_PROJECT_MIN` | `60` | trend trigger: minutes-to-floor that count as imminent |
| `DISK_GUARD_RENOTIFY_SEC` | `21600` | how long an unchanged level stays quiet |
| `DISK_GUARD_EMERGENCY_REAP` | `1` | `0` makes the guard advisory only |
| `DISK_GUARD_MOUNT` | `/` | filesystem to watch |
| `DISK_GUARD_STATE_DIR` | `~/atlas-health` | burn-rate state and `disk.json` |
| `DISK_GUARD_NOTE` | — | text prepended to every report; used by the self-test so a provoked alert is distinguishable from a real one |

## What this issue does not cover

Reducing the *consumption* is [`cargo-reaper/`](../cargo-reaper/) and ISSUE-76
(shared build settings, `line-tables-only`, teardown on issue close). Getting
the backups onto a **second physical disk** is ISSUE-9 and is still the real fix —
this guard buys warning time, it does not remove the single-disk risk.
