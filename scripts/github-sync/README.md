# github-sync — every GitHub repo, hourly, on both disks, versioned

A working clone of every repo Luka owns or sees through his orgs (`gh api
user/repos?affiliation=owner,organization_member`: private, archived and forks
included; other people's repos he only collaborates on are not), at
`/srv/bulk/github/<owner>/<repo>`, checked out on the default branch.

| Path | What it is |
|---|---|
| `sync.sh` | lists the repos through `gh`, clones new ones, fetches every branch and tag (forced, pruned), resets the checkout to `origin/<default>` and cleans it, status in `/var/lib/atlas-github-sync/status.json` |
| `atlas-github-sync.service` | oneshot as the installing user (the one `gh` is logged in as), idle IO, 1 h timeout for the first clone |
| `install.sh` | creates `/srv/bulk/github`, copies the script to `/usr/local/bin/atlas-github-sync`, renders the unit and hooks it into the bulk backup |

## Schedule and versions

There is no timer of its own. The unit is `WantedBy=` and `Before=`
`atlas-bulk-backup.service` ([`../bulk-backup`](../bulk-backup/README.md)), so
the hourly bulk backup first runs the sync, waits for it, then mirrors
`/srv/bulk` (and with it `github/`) onto the USB disk and snapshots it:

```
/srv/bulk/github/<owner>/<repo>                                    IronWolf, latest
/srv/bulk-backup/current/bulk/github/<owner>/<repo>                USB disk, latest
/srv/bulk-backup/snapshots/<stamp>/bulk/github/<owner>/<repo>      USB disk, read-only versions
```

The clones follow GitHub exactly, rewrites included: if `main` is
force-pushed or wiped, the next run takes that over. The snapshots from before
do not change: one per hour for the last 24 hours and one for every day before
that, with no limit (until the USB disk drops below 10 % free), so any earlier
day can be restored. A failed sync does
not stop the backup.

A repo that disappears from GitHub (deleted, renamed, transferred) is never
deleted here; its last clone stays and is listed as `orphans` in the status
file and the journal.

## Use

```bash
sudo systemctl start --no-block atlas-github-sync.service   # run now
journalctl -u atlas-github-sync.service -n 50
cat /var/lib/atlas-github-sync/status.json                  # repos, failures, orphans

# a repo as it was before an incident:
ls /srv/bulk-backup/snapshots/
git clone /srv/bulk-backup/snapshots/<stamp>/bulk/github/luka-loehr/atlas /tmp/atlas-before
```

## Install

```bash
./install.sh     # as the user gh is logged in as; re-run after changing sync.sh
```

## Limits

Code, branches and tags only — no issues, PRs, releases, wikis or LFS objects.
Both disks are in the same box, as for the bulk backup.
