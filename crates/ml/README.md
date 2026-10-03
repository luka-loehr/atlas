# atlas-ml — the model worker

The two models of the photo pipeline, in their own process so the server
never links a GPU runtime and a model crash never takes the API down.

- **Meaning.** Qwen3-VL-Embedding-2B puts photos, videos and search text into
  one 2048-dimensional space. It runs as a GGUF model inside a llama.cpp
  server that atlas-ml starts, supervises and stops.
- **Faces.** InsightFace `buffalo_l` (SCRFD detection, ArcFace recognition) on
  ONNX Runtime; each face is matched to a person or starts a new one.

Nothing generative runs here: no captions, no tagging model.

```bash
atlas-ml          # work the embed and faces queues, answer on 127.0.0.1:8786
```

| Route | |
|---|---|
| `GET /health` | which models are loaded |
| `POST /embed {"text": "…"}` | the vector of a search query |
| `POST /warm` | load the embedding model ahead of a search |

Only atlas-server talks to it. Logs: `journalctl -u atlas-ml -f`.

## How it works

- **Queues.** It claims `embed` and `faces` jobs from the same Postgres queue
  the server fills (protocol in [`atlas-core`](../core/src/queue.rs)), one
  model at a time on the GPU.
- **Stills** are resized exactly as the model's reference preprocessing does
  (`smart_resize`, bicubic) and embedded at up to 1800 visual tokens.
  **Videos** are six frames spread over the clip, embedded together in one
  prompt.
- **Idle unload.** After `ATLAS_ML_IDLE_S` seconds without work the llama.cpp
  server is stopped and its GPU memory returned; the next job or `/warm`
  starts it again.
- **People.** A new face joins the person of its nearest known face (cosine
  above 0.6), else the nearest person centroid (above 0.55), else becomes a
  new person. Re-running a photo keeps assignments made by hand.
- **No silent fallback.** If a model is missing or fails, the job fails
  visibly and search reports `semantic: unavailable`.

## Configuration

From `/etc/atlas/atlas.env`, documented in [`config.rs`](src/config.rs).

| Variable | Default | |
|---|---|---|
| `ATLAS_MODELS_DIR` | `~/models` | `qwen3-vl-embedding/{model,mmproj}.gguf`, `buffalo_l/{det_10g,w600k_r50}.onnx` |
| `ATLAS_LLAMA_SERVER` | `/usr/local/lib/atlas/llama-server` | built by `models.sh` |
| `ATLAS_EMBED_GPU_LAYERS` | `99` (all) | `0` runs the embedding model on the CPU |
| `ATLAS_ML_IDLE_S` | `600` | seconds until the embedding model is unloaded |
| `ATLAS_ML_BIND` | `127.0.0.1:8786` | |
| `ATLAS_LLAMA_PORT` | `8785` | loopback port of the llama.cpp server |

Models and the llama.cpp build come from
[`scripts/atlas/models.sh`](../../scripts/atlas/models.sh). The weights keep
their own licenses; `buffalo_l` is for non-commercial research use.
