#!/usr/bin/env bash
# Everything atlas-ml runs on, fetched and built once:
#
#   * llama.cpp's server, built with CUDA from a pinned commit plus Atlas'
#     patch that lets the frames of one clip be merged in time
#     (llama-server-video-frames.patch), installed as
#     /usr/local/lib/atlas/llama-server
#   * WeMM-Embedding-2B as GGUF (Q8_0, 2.6 GB) plus its vision projector
#     (BF16, 0.7 GB), from a pinned revision, checked against their sha256
#   * InsightFace buffalo_l: SCRFD face detection and ArcFace recognition
#     (non-commercial research license)
#
# Re-running skips whatever is already there; a llama.cpp server from
# another commit or patch is built again. install.sh runs this first.
set -euo pipefail
cd "$(dirname "$0")"

MODELS="${ATLAS_MODELS_DIR:-$HOME/models}"
LLAMA_COMMIT=9b56ccf
PATCH="$PWD/llama-server-video-frames.patch"
BUILD="${ATLAS_BUILD_DIR:-$HOME/build}/llama.cpp"
SERVER=/usr/local/lib/atlas/llama-server

# ---- llama.cpp server ------------------------------------------------------
want="$LLAMA_COMMIT $(sha256sum "$PATCH" | cut -c1-16)"
if [ ! -x "$SERVER" ] || [ "$(cat "$SERVER.build" 2>/dev/null)" != "$want" ]; then
  export PATH="/usr/local/cuda/bin:$PATH"
  if ! command -v nvcc >/dev/null; then
    echo "the CUDA toolkit (nvcc) is missing: atlas-ml runs its embedding model on the GPU only (docs/SETUP.md)" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$BUILD")"
  [ -d "$BUILD" ] || git clone https://github.com/ggml-org/llama.cpp "$BUILD"
  git -C "$BUILD" fetch --quiet origin
  git -C "$BUILD" checkout --quiet --force "$LLAMA_COMMIT"
  git -C "$BUILD" apply "$PATCH"
  echo "building llama.cpp $LLAMA_COMMIT with the video-frames patch (CUDA) ..."
  cmake -S "$BUILD" -B "$BUILD/build-static" -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=native \
        -DLLAMA_CURL=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$BUILD/build-static" -j"$(nproc)" --target llama-server >/dev/null
  git -C "$BUILD" checkout --quiet --force "$LLAMA_COMMIT"   # leave the checkout clean
  sudo install -D -m755 "$BUILD/build-static/bin/llama-server" "$SERVER"
  echo "$want" | sudo tee "$SERVER.build" >/dev/null
fi

# ---- embedding model -------------------------------------------------------
fetch() { # url dest sha256
  if [ ! -s "$2" ]; then
    mkdir -p "$(dirname "$2")"
    echo "downloading $(basename "$2") ..."
    curl -fL --retry 5 -C - -o "$2.part" "$1"
    echo "$3  $2.part" | sha256sum --check --quiet || { echo "checksum mismatch: $1" >&2; rm -f "$2.part"; exit 1; }
    mv "$2.part" "$2"
  fi
}
HF=https://huggingface.co/DreamBlooms/WeMM-Embedding-2B-GGUF/resolve/c896b0570a32d4060bc62faa21b60cea4f49d142
fetch "$HF/WeMM-Embedding-2B-Q8_0.gguf" "$MODELS/wemm-embedding/model.gguf" \
  441c18c67d1a7a07fb903a7a075062adb64f38c4b87126e2476a4b4d6a178248
fetch "$HF/mmproj-WeMM-Embedding-2B-BF16.gguf" "$MODELS/wemm-embedding/mmproj.gguf" \
  c7271c975cab83ebd12ce2807e7b77e91134afd9f1658bd4dca986212a60560d

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
