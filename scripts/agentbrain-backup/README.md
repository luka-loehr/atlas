# agentbrain-backup — the agentbrain archive, hourly, on both disks, versioned

agentbrain is the shared memory every agent
uses. Its server keeps no backup of its own: this job pulls the full archive
every hour and keeps it on atlas.

| Path | What it is |
|---|---|
| `pull.sh` | downloads the archive with a backup key, checks it (SHA-256 from the server, gzip, format, counts), applies the shrink brake, writes `latest` and the day's file, status in `/var/lib/atlas-agentbrain-backup/status.json` |
| `atlas-agentbrain-backup.service` | oneshot as the system user `atlas-agentbrain` (tight sandbox: no /home, writes only `/srv/bulk/agentbrain`, no capabilities), idle IO, `OnFailure=` mail |
| `install.sh` | creates the user and `/srv/bulk/agentbrain`, copies the script to `/usr/local/bin/atlas-agentbrain-backup`, installs the unit and hooks it into the bulk backup |

## What is in the archive

One gzipped JSON document (format `agentbrain-backup/1`) with every project,
memory, relation, memory version, task, task event and activity row, plus the
account's sign-in rows (passkeys, the encrypted authenticator secret, token
hashes), so a restore brings back the account and every agent's token too.
The server sends the archive's SHA-256 and its counts as headers; a download
that does not match them is thrown away.

## Access: a backup key

The job authenticates with a **backup key**: a personal token of the
agentbrain account whose only scope is `backup:read`. It can download the
archive and nothing else. It cannot read or change single memories, and the
agent interface refuses it. Create one in agentbrain under Settings → Backups,
revoke it under Access.

- key: `/etc/atlas/credentials/agentbrain-backup.key` (root, 0600), passed to
  the unit with `LoadCredential=`; it reaches curl through a process
  substitution, never argv or the environment
- `/etc/atlas/agentbrain-backup.env`: `AGENTBRAIN_URL=https://…` (the server,
  without a path)

The archive itself is as sensitive as the brain: the files are `0640`
`atlas-agentbrain`, in a `0750` directory.

## Schedule and versions

There is no timer of its own. Like [`../github-sync`](../github-sync/README.md),
the unit is `WantedBy=` and `Before=` `atlas-bulk-backup.service`
([`../bulk-backup`](../bulk-backup/README.md)), so the hourly bulk backup first
pulls the archive, waits for it, then mirrors `/srv/bulk` onto the USB disk and
snapshots it:

```
/srv/bulk/agentbrain/latest.json.gz                                   IronWolf, the newest archive
/srv/bulk/agentbrain/daily/<YYYY-MM-DD>.json.gz                       IronWolf, the last archive of each day (UTC)
/srv/bulk/agentbrain/imported/                                        IronWolf, copies from before this job
/srv/bulk-backup/snapshots/<stamp>Z/bulk/agentbrain/…                 USB disk, read-only versions
```

The daily files are never deleted (a few MB each). The snapshots add every
hour of the last 24 hours and one state per day before that, with no limit.
Both jobs share `/run/lock/atlas-backup.lock`, and a download in progress is a
`*.part` file the bulk backup skips, so a snapshot never holds half an archive.

A job that wants a fresh restore point before bulk changes to the brain can
order itself after the unit (`Wants=` + `After=atlas-agentbrain-backup.service`).

## Shrink brake

If an archive holds fewer than 75 % of the memories of the last one (once
there are at least 50), it is kept as `held/<stamp>.json.gz`, `latest` and the
day's file stay as they were, and the run fails and mails. If the drop was
intended (a large clean-up), accept it once:

```bash
sudo touch /var/lib/atlas-agentbrain-backup/accept-shrink
sudo systemctl start atlas-agentbrain-backup.service
```

## Use

```bash
sudo systemctl start atlas-agentbrain-backup.service      # run now
journalctl -u atlas-agentbrain-backup.service -n 50
sudo cat /var/lib/atlas-agentbrain-backup/status.json      # last pull, counts, sha256

# the brain as it was before an incident:
sudo ls /srv/bulk/agentbrain/daily/ /srv/bulk-backup/snapshots/
sudo cp /srv/bulk-backup/snapshots/<stamp>Z/bulk/agentbrain/latest.json.gz /tmp/brain-before.json.gz
```

Restore with `scripts/restore.mjs` in the agentbrain repository.

## Install

```bash
./install.sh     # re-run after changing pull.sh
```
