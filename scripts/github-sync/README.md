# github-sync — every GitHub repo, hourly, on both disks, versioned

A working clone of every repo of Luka's account and his orgs (private,
archived and forks included), at `/srv/bulk/github/<owner>/<repo>`, checked
out on the default branch.

| Path | What it is |
|---|---|
| `sync.sh` | lists the repos through the GitHub App, clones new ones, fetches every branch and tag (forced, pruned), resets the checkout to `origin/<default>` and cleans it when it differs, status in `/var/lib/atlas-github-sync/status.json` |
| `atlas-github-sync.service` | oneshot as the system user `atlas-github` (tight sandbox: no /home, writes only `/srv/bulk/github`, no capabilities), idle IO, `OnFailure=` mail |
| `install.sh` | creates the user and `/srv/bulk/github`, copies the script to `/usr/local/bin/atlas-github-sync`, installs the unit and hooks it into the bulk backup |

## Access: a read-only GitHub App

The sync authenticates as the GitHub App **atlas-backup-luka-loehr**
(permissions: Contents read, Metadata read; nothing else), installed with "All
repositories" on `luka-loehr`, `dairo-app`, `school-ui`, `lgka-app` and
`kiste-run`. A JWT signed with the app's private key gets a one-hour
installation token per account; the token reaches git only through a credential
helper and the environment, never argv or a remote URL. Nothing on atlas that
the sync uses can push, delete a repo or change an org.

- private key: `/etc/atlas/credentials/github-sync-app.pem` (root, 0600),
  passed to the unit with `LoadCredential=`
- `/etc/atlas/github-sync.env`: `GITHUB_APP_ID=…` and
  `GITHUB_SYNC_OWNERS="luka-loehr dairo-app school-ui lgka-app kiste-run"`

The app is public only so it can be installed on the orgs. The sync looks up
the installation of each account in `GITHUB_SYNC_OWNERS` by name, so an
installation by anyone else is never listed or synced. A new org: install the app there ("All repositories") and add it to
`GITHUB_SYNC_OWNERS`; an allowed account without the app fails the run.

The key does not expire. To rotate it: app settings → Private keys → Generate,
replace the `.pem`, delete the old key on GitHub.

## Schedule and versions

There is no timer of its own. The unit is `WantedBy=` and `Before=`
`atlas-bulk-backup.service` ([`../bulk-backup`](../bulk-backup/README.md)), so
the hourly bulk backup first runs the sync, waits for it, then mirrors
`/srv/bulk` (and with it `github/`) onto the USB disk and snapshots it:

```
/srv/bulk/github/<owner>/<repo>                                     IronWolf, latest
/srv/bulk-backup/current/bulk/github/<owner>/<repo>                 USB disk, latest
/srv/bulk-backup/snapshots/<stamp>Z/bulk/github/<owner>/<repo>      USB disk, read-only versions
```

The clones follow GitHub exactly, rewrites included: if `main` is
force-pushed or wiped, the next run takes that over. The snapshots from before
do not change: one per hour for the last 24 hours and one for every day before
that, with no limit, so any earlier day can be restored. A failed sync does not
stop the backup. Both jobs share `/run/lock/atlas-backup.lock`, so a sync
started by hand never lands half-done in a snapshot.

A repo that disappears from GitHub (deleted, renamed, transferred) is never
deleted here; its last clone stays and is listed as `orphans` in the status
file and the weekly report.

## Reliability

- every git command has a 20 min cap and is cut after a minute below 1 kB/s,
  so one stalled repo cannot eat the hour;
- stale `.git/*.lock` files from a killed run are removed at the start (safe:
  the shared lock means no other git runs there);
- an idle repo is not touched at all (no `FETCH_HEAD`, checkout only when
  something differs), so an hour without pushes adds no snapshot;
- a failed repo is retried next hour; the run fails and mails, and the hourly
  check keeps mailing while `failed` is not empty.

## Use

```bash
sudo systemctl start --no-block atlas-github-sync.service   # run now
journalctl -u atlas-github-sync.service -n 50
sudo cat /var/lib/atlas-github-sync/status.json              # repos, failures, orphans

# a repo as it was before an incident:
sudo ls /srv/bulk-backup/snapshots/
sudo git clone /srv/bulk-backup/snapshots/<stamp>Z/bulk/github/luka-loehr/atlas /tmp/atlas-before
```

## Install

```bash
./install.sh     # re-run after changing sync.sh
```

## Limits

Code, branches and tags only — no issues, PRs, releases, wikis or LFS objects.
Collaborator-only repos of other people are not included. Both disks are in
the same box, as for the bulk backup.
