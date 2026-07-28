# ci-health — daily CI recorder for the self-hosted runners

atlas hosts the GitHub Actions runners for a separate project
(`~/actions-runner-dairo`, the workspace [disk-guard](../disk-guard/) sizes its
floor against). CI there once sat red for thirteen days with nobody watching.
This is the thing that writes it down every day.

| File | What it is |
|---|---|
| `dairo-ci-health.service` | oneshot: appends a timestamped report + exit code to `~/dairo-ci-health.log` |
| `dairo-ci-health.timer` | daily at 12:05 UTC, `Persistent=true` |
| `install.sh` | copies both units to `/etc/systemd/system`, enables the timer |

```bash
./install.sh
systemctl list-timers dairo-ci-health.timer
tail -40 ~/dairo-ci-health.log
```

**The checker is not in this repo.** `ExecStart` calls
`~/.local/bin/dairo-ci-health`, which belongs to the project being watched
(it drives `gh run list` against that repo and needs `gh` authenticated as
the runner owner). Only the schedule lives here, because the schedule is an
atlas concern: this box is off for hours at a time, so the two things that
make the recorder work are `Persistent=true` — catch up a check missed while
powered off, instead of silently skipping it — and the three-minute
`ExecStartPre` sleep, which stops a catch-up run at boot from logging runners
as offline while they are still registering.

Exit codes the log carries: `0` all green, `1` something is red or a runner is
offline, `2` the check could not run at all (auth, network) — also actionable.
