#!/usr/bin/env python3
"""The three GPU stages of the pipeline: embed (SigLIP2), faces (InsightFace),
caption (Qwen2.5-VL via vLLM).

Each stage is load()/process_batch(conn, jobs)/unload(). Only ONE stage may be
loaded at a time (8GB card) — worker_gpu.py enforces the sequencing. Heavy
imports live inside load() so a broken dep in one stage never kills the others.

process_batch takes [(job_id, asset_id), ...] and returns [(job_id, err), ...]
with err=None on success. Every handler is idempotent: embeddings are pure
upserts, faces are delete-then-insert per asset, captions are plain UPDATEs +
ON CONFLICT DO NOTHING tags — a re-run after a crash never duplicates anything.
"""
import base64
import gc
import json
import os
import re

import numpy as np
from PIL import Image

MODELS = os.environ.get("MODELS_DIR", "/models")
os.environ.setdefault("HF_HOME", os.path.join(MODELS, "hf"))  # before hf libs load
PHOTOS = os.environ.get("PHOTOS_DIR", "/photos")
THUMBS = os.path.join(PHOTOS, "thumbs")
FACE_CROPS = os.path.join(PHOTOS, "faces")

# A job settled with this prefix is requeued WITHOUT an attempts penalty —
# used when the input thumb simply doesn't exist yet (the CPU worker is still
# thumbnailing a fresh ingest). Prevents mass-'failed' GPU jobs during the
# initial takeout backfill when thumbs lag behind.
RETRY = "RETRY: "


def thumb(asset_id, *sizes):
    """First existing thumb path for the given sizes, else None."""
    for s in sizes:
        p = os.path.join(THUMBS, f"{asset_id}.{s}.webp")
        if os.path.exists(p):
            return p
    return None


def vec_lit(v):
    """pgvector literal — cast with ::vector in SQL."""
    return "[" + ",".join(f"{float(x):.7g}" for x in v) + "]"


def free_cuda():
    gc.collect()
    try:
        import torch
        if torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


# ------------------------------------------------------------------ embed ---

class EmbedStage:
    """SigLIP2 image embeddings -> embeddings(model='siglip2', vec vector(768))."""
    KIND = "embed"
    BATCH = 32
    MODEL_ID = "google/siglip2-base-patch16-384"

    def load(self):
        import torch
        from transformers import AutoModel, AutoProcessor
        self.torch = torch
        self.model = AutoModel.from_pretrained(
            self.MODEL_ID, dtype=torch.float16).to("cuda").eval()
        self.processor = AutoProcessor.from_pretrained(self.MODEL_ID)

    def process_batch(self, conn, jobs):
        results = []
        imgs, keep = [], []
        for jid, aid in jobs:
            p = thumb(aid, 512, 2048)
            if not p:
                results.append((jid, RETRY + "no thumb yet"))
                continue
            try:
                imgs.append(Image.open(p).convert("RGB"))
                keep.append((jid, aid))
            except Exception as e:
                results.append((jid, f"thumb unreadable: {type(e).__name__}: {e}"))
        if not keep:
            return results

        torch = self.torch
        inputs = self.processor(images=imgs, return_tensors="pt")
        inputs = {k: v.to("cuda", torch.float16) if v.is_floating_point() else v.to("cuda")
                  for k, v in inputs.items()}
        with torch.no_grad():
            feats = self.model.get_image_features(**inputs)
        feats = torch.nn.functional.normalize(feats.float(), dim=-1).cpu().numpy()

        cur = conn.cursor()
        for (jid, aid), vec in zip(keep, feats):
            try:
                cur.execute(
                    """INSERT INTO embeddings (owner_type, owner_id, model, vec)
                       VALUES ('asset', %s, 'siglip2', %s::vector)
                       ON CONFLICT (owner_type, owner_id, model)
                       DO UPDATE SET vec = EXCLUDED.vec""",
                    (aid, vec_lit(vec)))
                results.append((jid, None))
            except Exception as e:
                results.append((jid, f"db: {type(e).__name__}: {e}"))
        return results

    def unload(self):
        self.model = self.processor = None
        free_cuda()


# ------------------------------------------------------------------ faces ---

class FaceStage:
    """SCRFD det + ArcFace embeddings; incremental person clustering via
    persons.centroid (running mean) and 'depicts' edges."""
    KIND = "faces"
    BATCH = 16
    SIM_THRESHOLD = 0.55

    def _make_app(self, providers, ctx_id):
        from insightface.app import FaceAnalysis
        app = FaceAnalysis(name="buffalo_l",
                           root=os.path.join(MODELS, "insightface"),
                           providers=providers)
        app.prepare(ctx_id=ctx_id, det_size=(640, 640))
        return app

    def load(self):
        # ORT's CUDA EP needs libcudnn on the loader path; in the vllm image
        # cuDNN lives only inside torch's pip packages, so import torch FIRST
        # (it dlopens cudnn/cublas, making them resolvable for onnxruntime).
        import torch  # noqa: F401  — cudnn preload for the ORT CUDA EP
        try:
            import onnxruntime
            if hasattr(onnxruntime, "preload_dlls"):
                onnxruntime.preload_dlls()
        except Exception:
            pass
        # Still fall back to CPU, which is plenty fast for face detection.
        try:
            self.app = self._make_app(
                ["CUDAExecutionProvider", "CPUExecutionProvider"], 0)
            used = self.app.models["detection"].session.get_providers()[0]
            print(f"[faces] onnxruntime provider: {used}", flush=True)
        except Exception as e:
            print(f"[faces] CUDA EP failed ({type(e).__name__}: {e}) "
                  "-> CPUExecutionProvider", flush=True)
            self.app = self._make_app(["CPUExecutionProvider"], -1)
        os.makedirs(FACE_CROPS, exist_ok=True)

    def process_batch(self, conn, jobs):
        results = []
        for jid, aid in jobs:
            try:
                self._process_asset(conn, aid)
                results.append((jid, None))
            except Exception as e:
                # keep the RETRY sentinel intact so the worker requeues
                # penalty-free instead of counting an attempt
                msg = str(e)
                results.append((jid, msg if msg.startswith("RETRY:")
                                else f"{type(e).__name__}: {e}"))
        return results

    def _process_asset(self, conn, aid):
        p = thumb(aid, 2048, 512)
        if not p:
            raise FileNotFoundError(RETRY + "no thumb yet")
        img = Image.open(p).convert("RGB")
        arr = np.ascontiguousarray(np.array(img)[:, :, ::-1])  # RGB -> BGR
        h, w = arr.shape[:2]
        detected = []
        for f in self.app.get(arr):
            if f.det_score < 0.5:
                continue
            x1, y1, x2, y2 = [float(v) for v in f.bbox]
            if (x2 - x1) * (y2 - y1) < 0.02 * w * h:  # tiny background faces
                continue
            bbox = [max(0.0, min(1.0, x1 / w)), max(0.0, min(1.0, y1 / h)),
                    max(0.0, min(1.0, x2 / w)), max(0.0, min(1.0, y2 / h))]
            emb = np.asarray(f.normed_embedding, dtype=np.float64)
            detected.append((bbox, float(f.det_score), emb))

        touched = set()
        with conn.transaction():
            cur = conn.cursor()
            # per-asset idempotency: wipe our previous output (rows AND crop
            # files), then re-insert. Crop files are keyed by face id.
            cur.execute("SELECT id FROM faces WHERE asset_id = %s", (aid,))
            for (old_id,) in cur.fetchall():
                old_crop = os.path.join(FACE_CROPS, f"{old_id}.webp")
                if os.path.exists(old_crop):
                    os.remove(old_crop)
            cur.execute("DELETE FROM faces WHERE asset_id = %s", (aid,))
            cur.execute("DELETE FROM edges WHERE src_type='asset' AND src_id=%s "
                        "AND rel='depicts'", (aid,))
            for bbox, score, emb in detected:
                pid, sim = self._assign_person(cur, emb)
                touched.add(pid)
                face_id = cur.execute(
                    """INSERT INTO faces (asset_id, person_id, bbox, quality, embedding)
                       VALUES (%s, %s, %s, %s, %s::vector) RETURNING id""",
                    (aid, pid, bbox, score, vec_lit(emb))).fetchone()[0]
                self._save_crop(img, bbox, face_id)
                cur.execute(  # first decent face becomes the person's avatar
                    "UPDATE persons SET cover_face_id=%s "
                    "WHERE id=%s AND cover_face_id IS NULL", (face_id, pid))
                cur.execute(
                    """INSERT INTO edges (src_type, src_id, rel, dst_type, dst_id, confidence)
                       VALUES ('asset', %s, 'depicts', 'person', %s, %s)
                       ON CONFLICT (src_type, src_id, rel, dst_type, dst_id)
                       DO UPDATE SET confidence = GREATEST(edges.confidence,
                                                           EXCLUDED.confidence)""",
                    (aid, str(pid), sim))
            if touched:
                # Recompute from ground truth so crash-retries never inflate
                # face_count / over-weight the centroid (running mean above is
                # only the online approximation for the nearest-neighbor step).
                cur.execute(
                    """UPDATE persons p SET face_count = c.n, centroid = c.a
                       FROM (SELECT person_id, count(*) AS n, avg(embedding) AS a
                             FROM faces WHERE person_id = ANY(%s)
                             GROUP BY person_id) c
                       WHERE p.id = c.person_id""", (sorted(touched),))

    def _save_crop(self, img, bbox, face_id):
        """Square avatar crop (25% margin around the bbox) -> faces/<id>.webp."""
        try:
            w, h = img.size
            x1, y1, x2, y2 = bbox[0] * w, bbox[1] * h, bbox[2] * w, bbox[3] * h
            cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
            side = max(x2 - x1, y2 - y1) * 1.5
            box = (max(0, int(cx - side / 2)), max(0, int(cy - side / 2)),
                   min(w, int(cx + side / 2)), min(h, int(cy + side / 2)))
            crop = img.crop(box)
            crop.thumbnail((256, 256), Image.LANCZOS)
            crop.save(os.path.join(FACE_CROPS, f"{face_id}.webp"),
                      "WEBP", quality=86, method=6)
        except Exception as e:   # avatar is cosmetic — never fail the job on it
            print(f"[faces] crop {face_id} failed: {e}", flush=True)

    def _assign_person(self, cur, emb):
        """Nearest centroid by cosine; join if sim > 0.55 (running-mean centroid
        update), else create a new person. Returns (person_id, confidence)."""
        lit = vec_lit(emb)
        cur.execute(
            """SELECT id, face_count, centroid::text,
                      1 - (centroid <=> %s::vector) AS sim
               FROM persons
               WHERE merged_into IS NULL AND centroid IS NOT NULL
               ORDER BY centroid <=> %s::vector
               LIMIT 1""", (lit, lit))
        row = cur.fetchone()
        if row and row[3] is not None and row[3] > self.SIM_THRESHOLD:
            pid, fc, cent_txt, sim = row[0], row[1] or 1, row[2], float(row[3])
            cent = np.array([float(x) for x in cent_txt.strip("[]").split(",")])
            new = cent * fc + emb
            new /= np.linalg.norm(new) or 1.0
            cur.execute("UPDATE persons SET centroid=%s::vector, face_count=%s "
                        "WHERE id=%s", (vec_lit(new), fc + 1, pid))
            return pid, sim
        cur.execute("INSERT INTO persons (centroid, face_count) "
                    "VALUES (%s::vector, 1) RETURNING id", (lit,))
        return cur.fetchone()[0], 1.0

    def unload(self):
        self.app = None
        free_cuda()


# ---------------------------------------------------------------- caption ---

CAPTION_PROMPT = (
    "Beschreibe dieses Foto. Antworte NUR mit einem JSON-Objekt, exakt so:\n"
    '{"caption": "<genau ein deutscher Satz>", '
    '"tags": ["5-12 lowercase english keywords"]}')


class CaptionStage:
    """Qwen2.5-VL-3B-AWQ via offline vLLM -> assets.caption (German) + tags."""
    KIND = "caption"
    BATCH = 8
    MODEL_ID = "Qwen/Qwen2.5-VL-3B-Instruct-AWQ"

    def load(self):
        from vllm import LLM, SamplingParams
        # HF_HOME=/models/hf is set above; download_models.py pre-fetched the
        # snapshot, so passing the HF id resolves locally.
        # quantization is auto-detected (awq_marlin on Ada — faster than the
        # plain awq kernel); max_num_seqs=8 keeps the multimodal profiling run
        # inside the 8GB budget (default 256 would inflate it).
        self.llm = LLM(model=self.MODEL_ID,
                       gpu_memory_utilization=0.80, max_model_len=4096,
                       max_num_seqs=8, enforce_eager=True,
                       limit_mm_per_prompt={"image": 1})
        self.params = SamplingParams(temperature=0.2, max_tokens=256)

    def _messages(self, data_uri, strict=False):
        text = CAPTION_PROMPT + (" Return ONLY the JSON, nothing else." if strict else "")
        return [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": data_uri}},
            {"type": "text", "text": text}]}]

    def _data_uri(self, aid):
        p = thumb(aid, 512, 2048)
        if not p:
            return None
        with open(p, "rb") as f:
            return "data:image/webp;base64," + base64.b64encode(f.read()).decode()

    def process_batch(self, conn, jobs):
        results = []
        uris, keep = [], []
        for jid, aid in jobs:
            uri = self._data_uri(aid)
            if uri is None:
                results.append((jid, RETRY + "no thumb yet"))
            else:
                uris.append(uri)
                keep.append((jid, aid))
        if not keep:
            return results

        outs = self.llm.chat([self._messages(u) for u in uris],
                             self.params, use_tqdm=False)
        for (jid, aid), uri, out in zip(keep, uris, outs):
            text = out.outputs[0].text
            parsed = parse_caption_json(text)
            if parsed is None:  # one strict retry per contract
                retry = self.llm.chat([self._messages(uri, strict=True)],
                                      self.params, use_tqdm=False)
                parsed = parse_caption_json(retry[0].outputs[0].text)
            if parsed is None:
                results.append((jid, f"caption JSON unparseable: {text[:120]!r}"))
                continue
            caption, tags = parsed
            try:
                with conn.transaction():
                    cur = conn.cursor()
                    cur.execute("UPDATE assets SET caption=%s WHERE id=%s",
                                (caption, aid))
                    for t in tags:
                        cur.execute(
                            """INSERT INTO tags (asset_id, tag, source)
                               VALUES (%s, %s, 'qwen2.5-vl')
                               ON CONFLICT DO NOTHING""", (aid, t))
                results.append((jid, None))
            except Exception as e:
                results.append((jid, f"db: {type(e).__name__}: {e}"))
        return results

    def unload(self):
        self.llm = self.params = None
        try:  # vLLM keeps process-group state around; tear it down for real
            from vllm.distributed.parallel_state import (
                destroy_model_parallel, destroy_distributed_environment)
            destroy_model_parallel()
            destroy_distributed_environment()
        except Exception:
            pass
        free_cuda()


def parse_caption_json(text):
    """Robust repair: strip code fences, cut to outermost {...}, validate.
    Returns (caption, tags) or None."""
    t = re.sub(r"```(?:json)?", "", text).strip()
    a, b = t.find("{"), t.rfind("}")
    if a == -1 or b <= a:
        return None
    try:
        d = json.loads(t[a:b + 1])
    except ValueError:
        return None
    caption = str(d.get("caption", "")).strip()
    if not caption:
        return None
    raw = d.get("tags", [])
    tags = []
    if isinstance(raw, list):
        for x in raw:
            x = str(x).strip().lower()
            if x and x not in tags:
                tags.append(x)
    return caption[:500], tags[:12]
