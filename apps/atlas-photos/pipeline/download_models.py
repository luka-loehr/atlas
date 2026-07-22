#!/usr/bin/env python3
"""Fetch all GPU-pipeline models into /models (idempotent).

Runs as the entrypoint of the pipeline-gpu container before worker_gpu.py:
skips anything already on disk, so after the first boot this is a no-op that
takes a second. Downloads:

  - Qwen/Qwen3-VL-Embedding-2B             (embed, HF hub -> /models/hf)
  - Qwen/Qwen2.5-VL-3B-Instruct-AWQ        (caption, HF hub -> /models/hf)
  - insightface buffalo_l                  (faces -> /models/insightface)
"""
import os
import sys

MODELS = os.environ.get("MODELS_DIR", "/models")
os.environ.setdefault("HF_HOME", os.path.join(MODELS, "hf"))

# ATLAS_EMBED_REVISION: git revision of the embedding repo (its scripts/ code
# is executed by the workers — pin a commit sha to freeze the supply chain).
EMBED_REVISION = os.environ.get("ATLAS_EMBED_REVISION", "main")

HF_REPOS = [  # (repo, revision) — None = default branch
    ("Qwen/Qwen3-VL-Embedding-2B", EMBED_REVISION),
    ("Qwen/Qwen2.5-VL-3B-Instruct-AWQ", None),
]
INSIGHT_ROOT = os.path.join(MODELS, "insightface")


def dir_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            fp = os.path.join(root, f)
            if not os.path.islink(fp):
                total += os.path.getsize(fp)
    return total


def gb(n):
    return f"{n / 2**30:.2f} GB"


def fetch_hf(repo, revision=None):
    from huggingface_hub import snapshot_download
    kw = {"revision": revision} if revision else {}
    try:  # complete local snapshot -> raises if anything is missing
        path = snapshot_download(repo, local_files_only=True, **kw)
        print(f"  {repo}: present ({gb(dir_size(path))})", flush=True)
        return
    except Exception:
        pass
    print(f"  {repo}: downloading ...", flush=True)
    path = snapshot_download(repo, **kw)
    print(f"  {repo}: done ({gb(dir_size(path))})", flush=True)


def fetch_buffalo():
    dest = os.path.join(INSIGHT_ROOT, "models", "buffalo_l")
    if os.path.isdir(dest) and any(f.endswith(".onnx") for f in os.listdir(dest)):
        print(f"  buffalo_l: present ({gb(dir_size(dest))})", flush=True)
        return
    print("  buffalo_l: downloading ...", flush=True)
    from insightface.utils.storage import ensure_available
    ensure_available("models", "buffalo_l", root=INSIGHT_ROOT)
    print(f"  buffalo_l: done ({gb(dir_size(dest))})", flush=True)


def main():
    os.makedirs(os.environ["HF_HOME"], exist_ok=True)
    os.makedirs(INSIGHT_ROOT, exist_ok=True)
    print(f"models -> {MODELS} (HF_HOME={os.environ['HF_HOME']})", flush=True)
    for repo, revision in HF_REPOS:
        fetch_hf(repo, revision)
    fetch_buffalo()
    print(f"total under {MODELS}: {gb(dir_size(MODELS))}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"FATAL: model download failed: {type(e).__name__}: {e}", flush=True)
        sys.exit(1)
