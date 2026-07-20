"""SigLIP2 text-embedding sidecar for semantic photo search.

POST /embed {"text": "..."}  ->  {"vec": [768 floats, L2-normalized]}
GET  /health                 ->  {"ok": true}

Runs CPU-only next to the pipeline workers (compose service `embed-api`).
Shares the HF cache volume with the GPU worker, so startup needs no download.
Text-tower inference on CPU is tens of milliseconds — fine for live search.
Bound to 127.0.0.1: only the Rust photo server on the same host may call it.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch

MODEL_ID = "google/siglip2-base-patch16-384"
PORT = int(os.environ.get("EMBED_API_PORT", "8093"))

torch.set_num_threads(max(2, (os.cpu_count() or 4) // 4))

_model = None
_processor = None
# torch inference is serialized: concurrent forward passes on CPU just fight
# over the same cores and blow up latency for everyone
_infer_lock = threading.Lock()


def load():
    global _model, _processor
    from transformers import AutoModel, AutoProcessor

    _model = AutoModel.from_pretrained(MODEL_ID, torch_dtype=torch.float32)
    _model.eval()
    _processor = AutoProcessor.from_pretrained(MODEL_ID)


@torch.no_grad()
def embed_text(text: str) -> list[float]:
    # SigLIP is trained on 64-token max_length-padded text — deviating from
    # that at inference degrades retrieval quality
    inputs = _processor(
        text=[text], padding="max_length", max_length=64, return_tensors="pt"
    )
    feats = _model.get_text_features(**inputs)
    if not torch.is_tensor(feats):
        feats = feats.pooler_output
    v = feats[0]
    v = v / v.norm()
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
            with _infer_lock:
                vec = embed_text(text[:300])
            self._json(200, {"vec": vec})
        except Exception as e:  # noqa: BLE001 — sidecar must never die on a query
            self._json(500, {"error": str(e)})


if __name__ == "__main__":
    print(f"embed-api: loading {MODEL_ID} …", flush=True)
    load()
    print(f"embed-api: ready on 127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
