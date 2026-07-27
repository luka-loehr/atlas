#!/usr/bin/env bash
# Install/refresh the atlas host firewall (drops LAN traffic to 8787/8788).
set -euo pipefail
cd "$(dirname "$0")"
sudo install -d -m755 /etc/atlas
sudo install -m644 atlas-firewall.nft /etc/atlas/firewall.nft
sudo nft -c -f /etc/atlas/firewall.nft          # refuse to install a ruleset that will not parse
sudo cp atlas-firewall.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now atlas-firewall.service
echo "Installed. Active rules:  sudo nft list table inet atlas-fw"
echo "Lift temporarily:         sudo systemctl stop atlas-firewall"
