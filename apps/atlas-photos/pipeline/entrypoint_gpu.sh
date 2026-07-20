#!/usr/bin/env bash
# atlas-photos pipeline — GPU container entrypoint.
# 1. download_models.py: idempotent — fetches SigLIP2, buffalo_l and
#    Qwen2.5-VL-3B-AWQ into /models (HF_HOME=/models/hf) only if missing.
# 2. exec worker_gpu.py: the sequenced GPU worker loop (embed -> faces -> caption).
set -e

# The vllm image guarantees python3; some variants also symlink `python`.
PY="$(command -v python || command -v python3)"

"$PY" /app/download_models.py
exec "$PY" /app/worker_gpu.py
