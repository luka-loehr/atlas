#!/usr/bin/env bash
# Everything atlas-ml runs on, fetched and built once:
#
#   * llama.cpp's server, built from a pinned commit (with CUDA when the
#     toolkit is present) and installed as /usr/local/lib/atlas/llama-server
#   * Qwen3-VL-Embedding-2B as GGUF (Q8_0, 1.8 GB) plus its vision
#     projector (0.8 GB)
#   * InsightFace buffalo_l: SCRFD face detection and ArcFace recognition
#     (non-commercial research license)
#
# Re-running skips whatever is already there.
set -euo pipefail

MODELS="${ATLAS_MODELS_DIR:-$HOME/models}"
LLAMA_COMMIT=b92761a
BUILD="${ATLAS_BUILD_DIR:-$HOME/build}/llama.cpp"

# ---- llama.cpp server ------------------------------------------------------
if [ ! -x /usr/local/lib/atlas/llama-server ]; then
  mkdir -p "$(dirname "$BUILD")"
  [ -d "$BUILD" ] || git clone https://github.com/ggml-org/llama.cpp "$BUILD"
  git -C "$BUILD" fetch --quiet origin
  git -C "$BUILD" checkout --quiet "$LLAMA_COMMIT"
  CUDA=OFF
  if [ -x /usr/local/cuda/bin/nvcc ] || command -v nvcc >/dev/null; then
    CUDA=ON
    export PATH="/usr/local/cuda/bin:$PATH"
  fi
  echo "building llama.cpp $LLAMA_COMMIT (CUDA: $CUDA) ..."
  cmake -S "$BUILD" -B "$BUILD/build-static" -DGGML_CUDA=$CUDA -DLLAMA_CURL=OFF \
        -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD/build-static" -j"$(nproc)" --target llama-server >/dev/null
  sudo install -D -m755 "$BUILD/build-static/bin/llama-server" /usr/local/lib/atlas/llama-server
fi

# ---- embedding model -------------------------------------------------------
fetch() { # url dest
  [ -s "$2" ] && return
  mkdir -p "$(dirname "$2")"
  echo "downloading $(basename "$2") ..."
  curl -fL --retry 5 -C - -o "$2.part" "$1"
  mv "$2.part" "$2"
}
HF=https://huggingface.co/DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF/resolve/main
fetch "$HF/Qwen.Qwen3-VL-Embedding-2B.Q8_0.gguf"        "$MODELS/qwen3-vl-embedding/model.gguf"
fetch "$HF/mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf"  "$MODELS/qwen3-vl-embedding/mmproj.gguf"

# ---- face models -----------------------------------------------------------
if [ ! -s "$MODELS/buffalo_l/det_10g.onnx" ] || [ ! -s "$MODELS/buffalo_l/w600k_r50.onnx" ]; then
  mkdir -p "$MODELS/buffalo_l"
  tmp="$(mktemp -d)"
  echo "downloading buffalo_l ..."
  curl -fL --retry 5 -o "$tmp/buffalo_l.zip" \
    https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip
  unzip -q -o "$tmp/buffalo_l.zip" det_10g.onnx w600k_r50.onnx -d "$MODELS/buffalo_l"
  rm -rf "$tmp"
fi

echo "models ready in $MODELS"
ls -la "$MODELS/qwen3-vl-embedding" "$MODELS/buffalo_l"
