"""Qwen3-VL-Embedding-2B text-embedding sidecar for semantic photo search.

POST /embed {"text": "..."}  ->  {"vec": [2048 floats, L2-normalized]}
GET  /health                 ->  {"ok": true}

The query MUST use the same model the images were embedded with (same joint
space). Runs CPU-only next to the pipeline (compose service `embed-api`) — a
2B VL model on CPU is ~1-3 s per query, the price for query/image space parity.
Bound to 127.0.0.1: only the Rust photo server on the same host may call it.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch

MODEL_ID = "Qwen/Qwen3-VL-Embedding-2B"
# ATLAS_EMBED_REVISION: git revision of the model repo — its bundled scripts/
# code is imported and executed below, so pin a commit sha to freeze the
# supply chain (default "main").
EMBED_REVISION = os.environ.get("ATLAS_EMBED_REVISION", "main")
# EMBED_API_PORT: loopback listen port (default 8093)
PORT = int(os.environ.get("EMBED_API_PORT", "8093"))

# most cores for snappy queries; leave a few for postgres + the GPU pipeline's
# CPU-side work. Measured ~0.2-1.2 s per query at this width.
torch.set_num_threads(max(4, (os.cpu_count() or 4) * 3 // 4))

_embedder = None
# torch inference is serialized: concurrent forward passes on CPU just fight
# over the same cores and blow up latency for everyone
_infer_lock = threading.Lock()


def load():
    global _embedder
    from huggingface_hub import snapshot_download
    mp = snapshot_download(MODEL_ID, revision=EMBED_REVISION)
    sys.path.insert(0, os.path.join(mp, "scripts"))
    from qwen3_vl_embedding import Qwen3VLEmbedder
    _embedder = Qwen3VLEmbedder(model_name_or_path=mp, torch_dtype=torch.float32)


def embed_text(text: str) -> list[float]:
    with _infer_lock:
        v = _embedder.process([{"text": text}])[0]
    if hasattr(v, "detach"):
        v = v.detach().float().cpu().numpy()
    v = np.asarray(v, dtype=np.float32).reshape(-1)
    n = np.linalg.norm(v)
    if n > 0:
        v = v / n
    return [round(float(x), 6) for x in v.tolist()]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"ok": True, "model": MODEL_ID})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/embed":
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(n) or b"{}")
            text = str(payload.get("text", "")).strip()
            if not text:
                self._json(400, {"error": "text required"})
                return
            # embed_text() already serializes on _infer_lock; taking it here too
            # would re-enter the non-reentrant lock and deadlock every request.
            vec = embed_text(text[:300])
            self._json(200, {"vec": vec})
        except Exception as e:  # noqa: BLE001 — sidecar must never die on a query
            self._json(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"embed-api: loading {MODEL_ID} …", flush=True)
    load()
    print(f"embed-api: ready on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
