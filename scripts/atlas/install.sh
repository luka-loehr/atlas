#!/usr/bin/env bash
# Build and install atlas-server and atlas-ml from this checkout, then
# (re)start both units. Run on the server; `atlas deploy` on the Mac does
# exactly that over ssh. Nothing is installed and nothing restarts unless the
# release build succeeded.
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! sudo test -f /etc/atlas/atlas.env; then
  echo "missing /etc/atlas/atlas.env — copy scripts/atlas/atlas.env.example there and fill it in" >&2
  exit 1
fi

# cargo is not on the PATH of a non-interactive ssh session
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
cargo build --release -p atlas-server -p atlas-ml

sudo install -m755 target/release/atlas-server target/release/atlas-ml /usr/local/bin/
. scripts/lib/install-unit.sh
install_unit scripts/atlas/atlas-server.service scripts/atlas/atlas-ml.service
sudo systemctl daemon-reload
sudo systemctl enable --quiet atlas-server atlas-ml
sudo systemctl restart atlas-server atlas-ml

sleep 2
systemctl is-active atlas-server atlas-ml
