"""Lokaler Server fuer die Aussortier-Website — wie das Face-Tool: stdlib,
ThreadingHTTPServer, kurze Requests, kein Framework.

Zustand liegt SERVERSEITIG in decided.json (id -> "del"|"keep") und wird beim
Laden mit dem echten Papierkorb auf atlas abgeglichen — ein Reload oder anderer
Browser zeigt also nie wieder bereits Geloeschtes.

    python3 serve.py            # -> http://localhost:8890
"""
import json
import os
import threading
import urllib.parse
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# ATLAS_PHOTOS_URL: Basis-URL des atlas-photos-Servers (Thumbs + Mutations-API).
ATLAS = os.environ.get("ATLAS_PHOTOS_URL", "http://atlas.your-tailnet.ts.net:8788")
PORT = 8890
HERE = Path(__file__).resolve().parent
STATE = HERE / "decided.json"
LOCK = threading.Lock()


def load_state():
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {}


def save_state(d):
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(d))
    tmp.replace(STATE)


def atlas(path, body=None):
    req = urllib.request.Request(
        ATLAS + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"} if body is not None else {})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/state":
            return super().do_GET()
        with LOCK:
            decided = load_state()
            # Server-Wahrheit mergen: was auf atlas im Papierkorb liegt, IST del
            try:
                for it in atlas("/api/trash").get("items", []):
                    decided.setdefault(it["id"], "del")
                save_state(decided)
            except Exception:
                pass  # atlas nicht erreichbar -> lokaler Stand reicht
        # "atlas" mitliefern: index.html bekommt die Thumb-Basis-URL von hier
        # statt sie selbst zu hardcoden.
        self.reply({"decided": decided, "atlas": ATLAS})

    def csrf_ok(self):
        # CSRF-Schutz: Custom-Header erzwingen (cross-origin ohne CORS-Preflight
        # unmoeglich) und, falls der Browser Origin schickt, localhost verlangen.
        if self.headers.get("X-Triage") != "1":
            return False
        origin = self.headers.get("Origin")
        if origin:
            host = urllib.parse.urlsplit(origin).hostname
            if host not in ("localhost", "127.0.0.1"):
                return False
        return True

    def do_POST(self):
        if self.path != "/decide":
            self.send_error(404)
            return
        if not self.csrf_ok():
            self.send_error(403)
            return
        try:
            b = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            aid, action = b["id"], b["action"]
            assert isinstance(aid, str) and action in ("del", "keep", "undo")
        except Exception:
            self.send_error(400)
            return
        try:
            with LOCK:
                decided = load_state()
                if action == "del":
                    atlas("/api/mutate/trash", {"ids": [aid]})
                    decided[aid] = "del"
                elif action == "keep":
                    decided[aid] = "keep"
                else:  # undo
                    if decided.get(aid) == "del":
                        atlas("/api/mutate/restore", {"ids": [aid]})
                    decided.pop(aid, None)
                save_state(decided)
        except Exception as e:
            self.send_error(502, str(e))
            return
        self.reply({"ok": True})

    def reply(self, obj):
        payload = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    os.chdir(HERE)
    print(f"Aussortieren: http://localhost:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
