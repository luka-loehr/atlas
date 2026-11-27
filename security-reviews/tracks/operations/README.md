# Track: Operations (`luka-loehr/atlas`)

Audits operational scripts, backup/restore drills, firewalling, alerting, disk-guard, power controls, and deployment automation under `scripts/`, `crates/cli/`, and `.github/workflows/`.

## Key questions

1. Does `scripts/firewall/firewall.nft` enforce a default-deny inbound policy and restrict management/database ports?
2. Do `scripts/pg-backup/`, `scripts/bulk-backup/`, and `scripts/disk-guard/` handle errors (`set -euo pipefail`), locking, restrictive file permissions, and safe cleanup?
3. Do `scripts/atlas/install.sh` and unit installers protect `/etc/atlas/atlas.env` (mode 0600) and avoid unsafe downloads or unquoted expansions?
4. Is the public repository free of private IPv4 addresses, real emails, tailnet hostnames, and raw credentials?
