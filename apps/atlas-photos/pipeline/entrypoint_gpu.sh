#!/usr/bin/env bash
# atlas-photos pipeline — GPU container entrypoint.
# 1. download_models.py: idempotent — fetches SigLIP2, buffalo_l and
#    Qwen2.5-VL-3B-AWQ into /models (HF_HOME=/models/hf) only if missing.
# 2. exec worker_gpu.py: the sequenced GPU worker loop (embed -> faces -> caption).
set -e

# The vllm image guarantees python3; some variants also symlink `python`.
PY="$(command -v python || command -v python3)"

# onnxruntime-gpu (InsightFace) needs cudnn/cublas on the loader path; in the
# vllm image they exist only as pip packages inside site-packages/nvidia/*.
# Without this, ORT silently falls back to the CPU provider (faces run ~20x
# slower). Torch's preload helps in-process, but an explicit path is reliable.
NVLIBS="$("$PY" - <<'EOF'
import glob, os, sysconfig
site = sysconfig.get_paths()["purelib"]
print(":".join(sorted(d for d in glob.glob(os.path.join(site, "nvidia", "*", "lib"))
                      if os.path.isdir(d))))
EOF
)"
export LD_LIBRARY_PATH="${NVLIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

"$PY" /app/download_models.py
exec "$PY" /app/worker_gpu.py
