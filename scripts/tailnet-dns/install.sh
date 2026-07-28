#!/usr/bin/env bash
# Install/refresh the tailnet DNS follower (AdGuard while atlas is up).
#
# Credentials are NOT written here — create /etc/atlas-tailnet-dns.env first,
# see README.md. The install refuses to arm the unit without it, because an
# unauthenticated `down` at shutdown leaves the tailnet pointing at a box that
# is powering off.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f /etc/atlas-tailnet-dns.env ]; then
  echo "missing /etc/atlas-tailnet-dns.env — see README.md" >&2
  exit 1
fi

sudo install -m755 tailnet-dns.sh /usr/local/bin/atlas-tailnet-dns
sudo cp atlas-tailnet-dns.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-tailnet-dns.service
echo "Installed."
echo "  published value:  sudo atlas-tailnet-dns status"
echo "  history:          journalctl -u atlas-tailnet-dns -n 50"
