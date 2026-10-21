# atlas-ml — the model worker

The two models of the photo pipeline, in their own process so the server
never links a GPU runtime and a model crash never takes the API down.

- **Meaning.** [WeMM-Embedding-2B](https://huggingface.co/tencent/WeMM-Embedding-2B)
  puts photos, videos and search text into one 2048-dimensional space. It
  runs on the GPU as a GGUF model inside a llama.cpp server that atlas-ml
  starts, supervises and stops.
- **Faces.** InsightFace `buffalo_l` (SCRFD detection, ArcFace recognition) on
  ONNX Runtime; each face is matched to a person or starts a new one.

Nothing generative runs here: no captions, no tagging model.

```bash
atlas-ml          # work the embed and faces queues, answer on 127.0.0.1:8786
```

| Route | |
|---|---|
| `GET /health` | which models are loaded |
| `POST /embed {"text": "…"}` | a search as two vectors: `still` (the question for photos) and `clip` (for videos) |
| `POST /warm` | load the embedding model ahead of a search |

Only atlas-server talks to it. Logs: `journalctl -u atlas-ml -f`.

## How it works

- **Queues.** It claims `embed` and `faces` jobs from the same Postgres queue
  the server fills (protocol in [`atlas-core`](../core/src/queue.rs)); the
  server's thumbnail job queues both once the 2048 thumbnail exists. Two
  loops run side by side: embeddings on the GPU, four at once in the
  llama.cpp server's slots (two slots are always left for a search), and
  faces on the CPU. The queue lives in Postgres: a restart, a crash or a
  power-off resumes where it stopped.
- **GPU only.** The llama.cpp server is pinned to one CUDA device
  (`ATLAS_EMBED_DEVICE`) with every layer and the vision tower on it. Without
  that device it does not start, the jobs fail visibly and are retried; it
  never falls back to the CPU.
- **The model's own recipe** (its processor and MMEB evaluation, in
  [`embedder.rs`](src/embedder.rs) `recipe`): every input is the user turn
  closed by the `<embedding>` token, whose last hidden state is the vector.
  **Stills** are resized by `smart_resize` (bicubic, 64 to 1800 visual
  tokens) and end with "Represent the given image." **Videos** are read at
  one frame per second, 4 to 64 frames over the whole clip (by frame index
  and each frame's own timestamp, so variable frame rates are sampled right),
  tone-mapped to SDR when HDR, each frame at most 256 tokens; the vision tower
  merges them in pairs, every pair labelled with its time ("<12.5
  seconds>"), and the clip ends with "Understand the content of the provided
  video." A **search** is embedded twice, as the model's text-to-image and
  text-to-video retrieval questions, and atlas-server matches each against
  its kind. Measured against the PyTorch reference: cosine 0.98 to 0.99 for
  text, stills and clips.
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
| `ATLAS_MODELS_DIR` | `~/models` | `wemm-embedding/{model,mmproj}.gguf`, `buffalo_l/{det_10g,w600k_r50}.onnx` |
| `ATLAS_LLAMA_SERVER` | `/usr/local/lib/atlas/llama-server` | built by `models.sh`, with Atlas' video-frames patch |
| `ATLAS_EMBED_DEVICE` | `CUDA0` | the GPU the embedding model runs on (`llama-server --list-devices`) |
| `ATLAS_ML_IDLE_S` | `600` | seconds until the embedding model is unloaded |
| `ATLAS_EMBED_SLOTS` | `6` | requests the embedding server runs side by side; the queue uses all but two |
| `ATLAS_ML_BIND` | `127.0.0.1:8786` | |
| `ATLAS_LLAMA_PORT` | `8785` | loopback port of the llama.cpp server |

Models and the llama.cpp build come from
[`scripts/atlas/models.sh`](../../scripts/atlas/models.sh). The weights keep
their own licenses; `buffalo_l` is for non-commercial research use.
