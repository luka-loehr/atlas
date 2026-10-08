#!/usr/bin/env bash
# Install/refresh the backup alerting: atlas-alert (mail through the Luka Mail
# API), OnFailure target atlas-alert@.service, the hourly check, the weekly
# report and the smartd hook. Safe to re-run.
#
# Expects the API key in /etc/atlas/credentials/lmail-alerts (root, 0600) and
# its expiry date in lmail-alerts.expires (README).
set -euo pipefail
cd "$(dirname "$0")"

sudo test -s /etc/atlas/credentials/lmail-alerts \
  || { echo "/etc/atlas/credentials/lmail-alerts is missing — issue the key first (README)" >&2; exit 1; }
for t in jq curl smartctl; do command -v "$t" >/dev/null || { echo "$t is missing" >&2; exit 1; }; done

sudo install -o root -g root -m 0755 alert.sh /usr/local/sbin/atlas-alert
sudo install -o root -g root -m 0755 check.sh /usr/local/sbin/atlas-backup-check
sudo install -o root -g root -m 0755 smartd-alert.sh /etc/smartmontools/run.d/20atlas-alert

. ../lib/install-unit.sh
install_unit atlas-alert@.service atlas-backup-check.service atlas-backup-check.timer \
             atlas-backup-report.service atlas-backup-report.timer
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-backup-check.timer atlas-backup-report.timer
echo "Installed."
echo "  test mail:  echo test | sudo atlas-alert test 'test alert'"
echo "  check now:  sudo systemctl start atlas-backup-check.service"
echo "  report now: sudo systemctl start atlas-backup-report.service"
