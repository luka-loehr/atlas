# pg-backup — nightly dump + restore drill for atlas Postgres

Logical backups of the `atlas-postgres` container (media library, knowledge
graph, embeddings, ingest queue). Everything runs through `docker exec`; no
Postgres tools needed on the host.

| Path | What it is |
|---|---|
| `backup.sh` | pg_dump (custom format, zstd) + globals dump to `/srv/backups/atlas-postgres`, archive verified with `pg_restore -l`, then retention |
| `restore-drill.sh` | restores the newest dump into scratch DB `atlas_restore_drill`, compares exact per-table row counts against live, checks embedding dims, drops the scratch DB (`--keep` to inspect) |

## Schedule

systemd **user** timer (linger is enabled for `luka`, so it runs without a
login session): `~/.config/systemd/user/atlas-pg-backup.{service,timer}`,
nightly at 03:30 with `Persistent=true` — a missed run (box powered off)
fires on next boot.

```bash
systemctl --user list-timers atlas-pg-backup.timer   # next run
journalctl --user -u atlas-pg-backup.service         # history
```

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
