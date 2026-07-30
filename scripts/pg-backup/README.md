# pg-backup — nightly dump + restore drill for atlas Postgres

Logical backups of the `atlas-postgres` container (media library, knowledge
graph, embeddings, ingest queue). Everything runs through `docker exec`; no
Postgres tools needed on the host.

| Path | What it is |
|---|---|
| `backup.sh` | pg_dump (custom format, zstd) + globals dump to `/srv/backups/atlas-postgres`, archive verified with `pg_restore -l`, then retention |
| `restore-drill.sh` | restores the newest dump into scratch DB `atlas_restore_drill`, compares exact per-table row counts against live, checks embedding dims, drops the scratch DB (`--keep` to inspect) |
| `atlas-pg-backup.service` | oneshot wrapper around `backup.sh` (`User=luka`, idle IO, 30 min timeout) |
| `atlas-pg-backup.timer` | nightly at 03:30 ± 10 min, `Persistent=true` |
| `install.sh` | copies both units to `/etc/systemd/system`, enables the timer |

## Schedule

```bash
./install.sh                                  # install + enable
systemctl list-timers atlas-pg-backup.timer   # next run
journalctl -u atlas-pg-backup.service -n 50   # history
```

Nightly at 03:30 with a 10 min randomised delay. `Persistent=true` matters
here: atlas is powered off whenever it is not needed, so the fixed nightly
time is missed regularly and the dump is caught up shortly after the next
boot instead of being skipped.

The unit runs `backup.sh` straight out of the checkout, so re-run `install.sh`
after a pull that moves it.

`install.sh` also disables and removes any systemd **user** copy of the same
pair in `~/.config/systemd/user/` — with both a system and a user pair
installed, the dump runs twice a night against the same directory.

## Retention

- daily dumps: 14 days
- first-of-month dumps: 183 days
- a ~200 MB dump/day ⇒ worst case ≈ 4 GB on disk

## Restore (for real)

```bash
# into a fresh DB (drop/rename the broken one first):
docker exec atlas-postgres psql -U atlas -d postgres -c 'CREATE DATABASE atlas TEMPLATE template0'
docker exec -i atlas-postgres pg_restore -U atlas -d atlas --no-owner --exit-on-error \
  < /srv/backups/atlas-postgres/atlas_YYYY-MM-DD.dump
```

Run `restore-drill.sh` after any Postgres major upgrade and every few months.

## Known limitation

atlas has a **single physical disk** (one NVMe, one LVM volume). Backups in
`/srv/backups` survive `docker volume rm pgdata`, a botched migration, or an
accidental `DROP TABLE` — they do **not** survive the disk dying. Off-machine
replication (e.g. to the Mac via Tailscale) is a separate task.
