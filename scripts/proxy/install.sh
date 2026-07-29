#!/usr/bin/env bash
# Install/refresh the atlas dev-subdomain proxy: host Caddy + cloudflared units.
#
# This arms the LOCAL systemd side only. The Cloudflare cloud side (named
# tunnel, ingress, wildcard DNS, token) is done by ./setup.sh, which then calls
# this script. Run install.sh directly to re-arm/refresh the units after a
# config edit, or to recover them without re-touching Cloudflare.
#
# The tunnel token is NOT written here — /etc/atlas/cloudflared.env must exist
# already (setup.sh writes it). This script refuses to arm the tunnel without
# it, so cloudflared never starts unauthenticated.
set -euo pipefail
cd "$(dirname "$0")"

# Binaries must be present (see setup.sh header for install commands).
command -v caddy      >/dev/null 2>&1 || { echo "caddy not installed — see setup.sh header" >&2; exit 1; }
command -v cloudflared >/dev/null 2>&1 || { echo "cloudflared not installed — see setup.sh header" >&2; exit 1; }

if [ ! -f /etc/atlas/cloudflared.env ]; then
  echo "missing /etc/atlas/cloudflared.env — run ./setup.sh first" >&2
  exit 1
fi

# Base Caddy config (empty-but-ready: admin API on, routes added at runtime).
sudo install -d -m755 /etc/atlas
sudo install -m644 ../../proxy/caddy.json /etc/atlas/caddy.json
# Refuse to install a config that will not parse — same guard as the firewall.
caddy validate --config /etc/atlas/caddy.json

# Distro packages ship their own caddy.service / cloudflared.service in
# /lib/systemd/system. Stop and disable them first; the atlas units copied to
# /etc/systemd/system below have the same names and take precedence, so this
# just clears the old enablement/instance before we install and enable ours.
for unit in caddy cloudflared; do
  if systemctl list-unit-files "$unit.service" >/dev/null 2>&1; then
    sudo systemctl disable --now "$unit.service" 2>/dev/null || true
  fi
done

sudo cp caddy.service cloudflared.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now caddy.service
sudo systemctl enable --now cloudflared.service

echo "Installed."
echo "  caddy admin:   curl -sf localhost:2019/config/ >/dev/null && echo ok"
echo "  tunnel state:  systemctl status cloudflared --no-pager"
echo "  proxy routes:  curl -sf localhost:2019/config/apps/http/servers/atlas/routes | jq ."
