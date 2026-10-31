# agentbrain-backup — sync your agentbrain memories to your server

If your agents keep their memory in **agentbrain**, Atlas can keep a copy of
all of it on your own server: every project, memory, relation and the full
version history, refreshed every hour, checked on arrival, and versioned. If
the agentbrain server ever loses data, the copy on your box restores it.

- **Hourly and hands-off** — one small systemd job, no cron to babysit; a box
  that sleeps at night catches up when it wakes
- **Everything, versioned** — the newest archive plus one per day, and with
  [`../bulk-backup`](../bulk-backup/README.md) installed every hour of the
  last day and one state per day forever on the backup disk
- **Verified** — each download is checked against the checksum the server
  sends, gzip integrity and its counts before it replaces anything
- **Guarded** — an archive that suddenly lost a quarter of its memories is set
  aside instead of overwriting the last good one, and you get a mail
- **Least privilege** — a download-only backup key, its own system user, a
  tight sandbox, files readable by that user only

## Setup

**1. Create a backup key** in agentbrain under **Settings → Backups → Create
backup key**. A backup key can download the archive and nothing else: no
MCP, no reading or changing single memories. It is shown once.

**2. Store the key and your server's address** on the box:

```bash
sudo install -d -m 0700 /etc/atlas/credentials
sudo sh -c 'umask 077; cat > /etc/atlas/credentials/agentbrain-backup.key'   # paste the key, then Ctrl-D
echo 'AGENTBRAIN_URL=https://your-agentbrain.example.com' | sudo tee /etc/atlas/agentbrain-backup.env
# optional, default /srv/bulk/agentbrain:
# echo 'AGENTBRAIN_BACKUP_DEST=/srv/backups/agentbrain' | sudo tee -a /etc/atlas/agentbrain-backup.env
```

**3. Install** from the checkout and run it once:

```bash
~/atlas/scripts/agentbrain-backup/install.sh
sudo systemctl start atlas-agentbrain-backup.service
sudo cat /var/lib/atlas-agentbrain-backup/status.json      # memories, versions, size, checksum
```

That's it. With [`../bulk-backup`](../bulk-backup/README.md) installed, the
sync runs right before every bulk backup; without it, on its own hourly timer.
With [`../alerts`](../alerts/README.md) installed, a failed or stale sync
mails you.

## What you get

```
<dest>/latest.json.gz              the newest archive
<dest>/daily/<YYYY-MM-DD>.json.gz  the last archive of each day (UTC), kept forever (a few MB each)
<dest>/held/                       archives stopped by the shrink brake
```

Each archive is one gzipped JSON document (format `agentbrain-backup/1`) with
every project, memory, relation, memory version, task, task event and activity
row, plus the account's sign-in rows (passkeys, the encrypted authenticator
secret, token hashes), so a restore brings back the account and every agent's
token too. Treat the files like the brain itself: they are `0640` to the
`atlas-agentbrain` user, in a `0750` directory.

With the bulk backup, the snapshots on the backup disk add the versions in
between:

```
/srv/bulk-backup/snapshots/<stamp>Z/bulk/agentbrain/latest.json.gz
```

Both jobs share `/run/lock/atlas-backup.lock`, and a download in progress is a
`*.part` file the bulk backup skips, so a snapshot never holds half an archive.

## Restore

Pick an archive (`latest.json.gz`, a day from `daily/`, or one from a
snapshot) and load it with `scripts/restore.mjs` from the agentbrain
repository:

```bash
node scripts/restore.mjs latest.json.gz --remote
```

## Shrink brake

If an archive holds fewer than 75 % of the memories of the last one (once
there are at least 50), it is kept under `held/`, `latest` and the day's file
stay as they were, and the run fails. If the drop was intended (a big
clean-up), accept it once:

```bash
sudo touch /var/lib/atlas-agentbrain-backup/accept-shrink
sudo systemctl start atlas-agentbrain-backup.service
```

## Files

| Path | What it is |
|---|---|
| `pull.sh` | downloads `GET /archive` with the backup key, verifies it, applies the shrink brake, writes `latest` and the day's file, status in `/var/lib/atlas-agentbrain-backup/status.json` |
| `atlas-agentbrain-backup.service` | oneshot as the system user `atlas-agentbrain`: no /home, writes only the destination, no capabilities; the key comes in via `LoadCredential=` and reaches curl through a process substitution, never argv or the environment |
| `atlas-agentbrain-backup.timer` | hourly, `Persistent`; used only when the bulk backup is not installed |
| `install.sh` | creates the user and the destination, installs the script and the unit, then hooks it into the bulk backup or enables the timer |

Re-run `install.sh` after changing any of them or the destination.

## Rotate or revoke the key

Create a new backup key, replace the key file, run the service once, then
revoke the old key in agentbrain under Settings → Access.
