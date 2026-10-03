# atlas — the services and their installer

The two long-running Atlas processes as systemd units, and the scripts that
put them on the box.

| File | |
|---|---|
| `install.sh` | builds `atlas-server` and `atlas-ml` in release mode, installs them to `/usr/local/bin`, renders and enables both units, restarts them. Nothing is replaced unless the build succeeded. `atlas deploy` on the Mac runs exactly this over ssh |
| `models.sh` | one-time: builds llama.cpp's server from a pinned commit (CUDA when available) into `/usr/local/lib/atlas/`, downloads the embedding model and the face models into `~/models`. Re-running skips what is there |
| `atlas.env.example` | template for `/etc/atlas/atlas.env` (mode 0600), read by both units |
| `atlas-server.service` | API on :8787 plus ingest workers; starts after Docker so the database is up |
| `atlas-ml.service` | model worker on 127.0.0.1:8786 |

```bash
# first time
sudo install -d -m755 /etc/atlas
sudo install -m600 scripts/atlas/atlas.env.example /etc/atlas/atlas.env
sudoedit /etc/atlas/atlas.env          # ATLAS_TOKEN, POSTGRES_PASSWORD
scripts/atlas/models.sh
scripts/atlas/install.sh

# afterwards
systemctl status atlas-server atlas-ml
journalctl -u atlas-server -u atlas-ml -f
```

The units ship with `SET-BY-INSTALLER` as the user; `install.sh` substitutes
the installing account (see
[`../lib/install-unit.sh`](../lib/install-unit.sh)).
