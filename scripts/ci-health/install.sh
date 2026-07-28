#!/usr/bin/env bash
# Install/refresh the daily CI health recorder.
#
# The checker itself is NOT part of this repo — it belongs to the project being
# watched and lives at ~/.local/bin/dairo-ci-health on this box. The units are
# here so the schedule is version-controlled with the rest of atlas' timers.
set -euo pipefail
cd "$(dirname "$0")"

CHECKER=${CI_HEALTH_CHECKER:-$HOME/.local/bin/dairo-ci-health}
if [ ! -x "$CHECKER" ]; then
  echo "missing checker: $CHECKER — see README.md" >&2
  exit 1
fi

sudo cp dairo-ci-health.service dairo-ci-health.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dairo-ci-health.timer
echo "Installed."
echo "  next run:   systemctl list-timers dairo-ci-health.timer"
echo "  run now:    sudo systemctl start dairo-ci-health.service"
echo "  report log: tail -40 ~/dairo-ci-health.log"
