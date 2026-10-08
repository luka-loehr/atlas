# alerts — mail Luka when a backup job fails or goes stale

Mail goes from `atlas@lukaloehr.com` to `luka@lukaloehr.com` through the Luka
Mail API (`POST https://mail.lukaloehr.com/v1/messages/send`). The API key is a
device key bound to the `atlas@lukaloehr.com` identity only, so it can send
from that address and read that (empty) mailbox, nothing of Luka's own.

| Path | What it is |
|---|---|
| `alert.sh` → `/usr/local/sbin/atlas-alert` | sends one mail, at most once per problem key every 24 h, retries 3×; `--resolve` sends "resolved" for a key that was alerted; `--unit` mails a failed unit with its last 40 log lines |
| `atlas-alert@.service` | `OnFailure=atlas-alert@%n.service` target for atlas-bulk-backup, atlas-github-sync, atlas-pg-backup and the monthly scrub |
| `check.sh` → `/usr/local/sbin/atlas-backup-check` | hourly (`atlas-backup-check.timer`, :30 and 20 min after boot): timers enabled, units not failed, bulk backup not held and ≤ 3 h old, github sync ≤ 3 h old with no failed repos, newest Postgres dump ≤ 36 h old (only counted once atlas has been up long enough), USB disk mounted, writable, < 85 % full, no btrfs device errors, a finished scrub in the last 45 days, SMART health of every disk, alert key not expiring within 30 days |
| `atlas-backup-report.{service,timer}` | Monday 09:00 (`Persistent`): the same check plus a summary mail, sent even when all is fine — if it stops arriving, alerting itself is broken |
| `smartd-alert.sh` → `/etc/smartmontools/run.d/20atlas-alert` | smartd warnings (atlas has no local mail, so `-m root` went nowhere) |
| `install.sh` | installs all of the above |

```bash
echo test | sudo atlas-alert test 'test alert'      # one test mail
sudo systemctl start atlas-backup-check.service     # check now
sudo systemctl start atlas-backup-report.service    # weekly report now
ls /var/lib/atlas-alerts/                           # problems alerted and not yet resolved
```

## The key

Root-only at `/etc/atlas/credentials/lmail-alerts`, expiry date in
`lmail-alerts.expires` (the check warns 30 days ahead). It expires 2027-10-08.
To renew, from the Mac:

```bash
lmail --profile admin --json --confirm-admin key device --identity atlas@lukaloehr.com --name atlas-backup-alerts \
  | jq -j .token | ssh atlas 'sudo sh -c "umask 077; cat > /etc/atlas/credentials/lmail-alerts"'
ssh atlas 'echo 2028-MM-DD | sudo tee /etc/atlas/credentials/lmail-alerts.expires'   # expiresAt from the output
lmail --profile admin --confirm-admin key revoke <old key id>
```
