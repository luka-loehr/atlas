#!/usr/bin/env bash
# Install/refresh the atlas-healthcheck systemd units (boot + resume hooks).
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/install-unit.sh
install_unit atlas-healthcheck.service atlas-healthcheck-resume.service
sudo systemctl daemon-reload
sudo systemctl enable atlas-healthcheck.service atlas-healthcheck-resume.service
echo "Installed. Run now:    sudo systemctl start atlas-healthcheck"
echo "Last result:           cat ~/atlas-health/status.json"
