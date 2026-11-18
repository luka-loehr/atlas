# atlas — the services and their installer

The two long-running Atlas processes as systemd units, and the scripts that
put them on the box.

| File | |
|---|---|
| `install.sh` | runs `models.sh`, builds `atlas-server` and `atlas-ml` in release mode, installs them to `/usr/local/bin`, renders and enables the complete boot stack, then restarts it. It stops if `/etc/atlas/atlas.env` is missing, and no binary or unit is replaced unless the build succeeded. `atlas deploy` on the Mac brings `~/atlas` to `origin/main` and runs exactly this over ssh |
| `atlas-postgres.service` | brings the Compose database up at boot and waits for its healthcheck before the API starts |
| `models.sh` | builds llama.cpp's server from a pinned commit plus the patch below, with CUDA (it stops when the CUDA toolkit's `nvcc` is missing), into `/usr/local/lib/atlas/`; downloads the embedding model and the face, animal and text models into `~/models` (`ATLAS_MODELS_DIR`); installs ONNX Runtime with CUDA into `/usr/local/lib/atlas/onnxruntime`. Re-running skips what is there; `install.sh` runs it first on every install |
| `llama-server-video-frames.patch` | the patch `models.sh` applies to llama.cpp before building its server |
| `atlas.env.example` | template for `/etc/atlas/atlas.env` (mode 0600), read by both units |
| `atlas-server.service` | API on :8787 plus ingest workers; starts after healthy Postgres |
| `atlas-ml.service` | model worker on 127.0.0.1:8786; starts after the API |

```bash
# first time
sudo install -d -m755 /etc/atlas
sudo install -m600 scripts/atlas/atlas.env.example /etc/atlas/atlas.env
sudoedit /etc/atlas/atlas.env          # ATLAS_TOKEN, POSTGRES_PASSWORD
cp db/.env.example db/.env             # then set the same POSTGRES_PASSWORD in it (db/README.md)
scripts/atlas/models.sh
scripts/atlas/install.sh

# afterwards
systemctl status atlas-server atlas-ml
journalctl -u atlas-server -u atlas-ml -f
```

Run these from the repository root; the checkout is expected at `~/atlas`
(`atlas-postgres.service` starts the database from `~/atlas/db`).

The units ship with `SET-BY-INSTALLER` as the user; `install.sh` substitutes
the installing account and its home directory (see
[`../lib/install-unit.sh`](../lib/install-unit.sh)).
