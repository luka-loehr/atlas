#!/usr/bin/env python3
"""paperclip-bridge — turns Paperclip's polling-only API into a live event stream.

Paperclip has no outbound webhooks (the only webhook route is inbound, for
plugins). This service polls the board API on the box, diffs the result, and
pushes just the changes to subscribers over SSE — so the iOS app holds one
connection instead of hammering the API from the phone.

    GET /stream        SSE: snapshot, then deltas + live run output
    GET /health        plain JSON, no auth

Auth: same board API key as the app, as `Authorization: Bearer <key>` or
`?token=` (EventSource cannot set headers).

Stdlib only — no venv, no wheels to keep up to date.
"""

import json
import os
import queue
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import asks

# Every deployment-specific value comes from the environment — see
# paperclip-bridge.env.example. BRIDGE_BIND defaults to loopback on purpose:
# an empty value would bind 0.0.0.0 and put a tailnet-only service on every
# interface.
PAPERCLIP = os.environ.get("PAPERCLIP_API", "")
COMPANY = os.environ.get("PAPERCLIP_COMPANY", "")
TOKEN = os.environ.get("PAPERCLIP_TOKEN", "")
BIND = os.environ.get("BRIDGE_BIND", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "3111"))
POLL_IDLE = float(os.environ.get("BRIDGE_POLL_IDLE", "5"))
POLL_BUSY = float(os.environ.get("BRIDGE_POLL_BUSY", "1.5"))

subscribers: set["queue.Queue[str]"] = set()
subscribers_lock = threading.Lock()

# atlas rewrites some model ids on the way to the CLI (see the model shim), so
# price the model that actually runs, not the one Paperclip has on file.
EFFECTIVE_MODEL = {"claude-opus-4-8": "claude-opus-5"}
# USD per million tokens.
PRICES = {
    "claude-opus-5": {"in": 5.0, "out": 25.0},
    "claude-fable-5": {"in": 10.0, "out": 50.0},
    "claude-sonnet-5": {"in": 3.0, "out": 15.0},
    "claude-haiku-4-5": {"in": 1.0, "out": 5.0},
    "default": {"in": 5.0, "out": 25.0},
}




def api(path: str):
    req = urllib.request.Request(
        PAPERCLIP + path, headers={"Authorization": "Bearer " + TOKEN}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)


def publish(event: str, data) -> None:
    payload = f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
    with subscribers_lock:
        targets = list(subscribers)
    for q in targets:
        try:
            q.put_nowait(payload)
        except queue.Full:
            pass  # slow client; it will catch up on the next snapshot


def compact_agent(a: dict) -> dict:
    cfg = a.get("adapterConfig") or {}
    return {
        "id": a["id"],
        "name": a.get("name"),
        "role": a.get("role"),
        "status": a.get("status"),
        "reportsTo": a.get("reportsTo"),
        "model": cfg.get("model"),
        "engine": cfg.get("engine"),
        "lastHeartbeatAt": a.get("lastHeartbeatAt"),
    }


def compact_issue(i: dict) -> dict:
    return {
        "id": i["id"],
        "identifier": i.get("identifier"),
        "title": i.get("title"),
        "status": i.get("status"),
        "priority": i.get("priority"),
        "assigneeAgentId": i.get("assigneeAgentId"),
        "updatedAt": i.get("updatedAt"),
    }


class Poller(threading.Thread):
    """Single poller for every subscriber — one API load regardless of clients."""

    daemon = True

    def __init__(self):
        super().__init__()
        self.state: dict = {}
        self.run_cursors: dict[str, int] = {}
        self.last_error: str | None = None
        self.spend: dict = {"agents": [], "totals": {}}
        self.lead_id: str | None = None

    def refresh_spend(self, agents: list) -> None:
        """Per-agent token usage and what it actually costs.

        Paperclip's own cost tracking reads zero here (no cost events are
        recorded for CLI-lane runs), so derive it from the token counters on
        each agent's runtime state instead.
        """
        rows, total_in, total_out, total_cached, total_usd = [], 0, 0, 0, 0.0
        for agent in agents:
            try:
                st = api(f"/api/agents/{agent['id']}/runtime-state")
            except Exception:
                continue
            inp = st.get("totalInputTokens") or 0
            out = st.get("totalOutputTokens") or 0
            cached = st.get("totalCachedInputTokens") or 0
            price = PRICES.get(EFFECTIVE_MODEL.get(agent.get("model"), agent.get("model")), PRICES["default"])
            # cached input reads bill at ~10% of the input rate
            usd = (
                inp / 1_000_000 * price["in"]
                + cached / 1_000_000 * price["in"] * 0.1
                + out / 1_000_000 * price["out"]
            )
            rows.append({
                "agentId": agent["id"],
                "name": agent.get("name"),
                "model": agent.get("model"),
                "inputTokens": inp,
                "outputTokens": out,
                "cachedInputTokens": cached,
                "usd": round(usd, 4),
            })
            total_in += inp
            total_out += out
            total_cached += cached
            total_usd += usd
        self.spend = {
            "agents": sorted(rows, key=lambda r: -r["usd"]),
            "totals": {
                "inputTokens": total_in,
                "outputTokens": total_out,
                "cachedInputTokens": total_cached,
                "usd": round(total_usd, 4),
            },
        }

    def snapshot(self) -> dict:
        agents = [compact_agent(a) for a in api(f"/api/companies/{COMPANY}/agents")]
        issues = [compact_issue(i) for i in api(f"/api/companies/{COMPANY}/issues")]
        arts = api(f"/api/companies/{COMPANY}/artifacts").get("artifacts", [])
        artifacts = [
            {
                "id": a.get("id"),
                "title": a.get("title"),
                "updatedAt": a.get("updatedAt"),
                "issueId": (a.get("issue") or {}).get("id"),
                "issueIdentifier": (a.get("issue") or {}).get("identifier"),
                "agent": (a.get("createdByAgent") or {}).get("name"),
            }
            for a in arts
        ]
        # pending interactions are the things that actually block Luka
        pending = []
        for issue in issues:
            if issue["status"] in ("done", "cancelled"):
                continue
            try:
                for it in api(f"/api/issues/{issue['id']}/interactions"):
                    if it.get("status") == "pending":
                        pending.append(
                            {
                                "id": it["id"],
                                "issueId": issue["id"],
                                "issueIdentifier": issue["identifier"],
                                "kind": it.get("kind"),
                                "prompt": (it.get("payload") or {}).get("prompt"),
                                "createdAt": it.get("createdAt"),
                            }
                        )
            except Exception:
                pass
        return {
            "agents": agents,
            "issues": issues,
            "artifacts": artifacts[:25],
            "interactions": pending,
            "asks": asks.pending(),
            "ts": time.time(),
        }

    def tail_runs(self, agents: list) -> None:
        """Stream new run output for whatever is running right now."""
        running = [a for a in agents if a.get("status") == "running"]
        for agent in running:
            try:
                state = api(f"/api/agents/{agent['id']}/runtime-state")
            except Exception:
                continue
            run_id = state.get("lastRunId")
            if not run_id:
                continue
            try:
                events = api(f"/api/heartbeat-runs/{run_id}/events")
            except Exception:
                continue
            cursor = self.run_cursors.get(run_id, 0)
            fresh = [e for e in events if e.get("seq", 0) > cursor]
            if not fresh:
                continue
            self.run_cursors[run_id] = max(e.get("seq", 0) for e in fresh)
            publish(
                "run",
                {
                    "runId": run_id,
                    "agentId": agent["id"],
                    "agentName": agent.get("name"),
                    "events": [
                        {
                            "seq": e.get("seq"),
                            "type": e.get("eventType"),
                            "stream": e.get("stream"),
                            "level": e.get("level"),
                            "message": (e.get("message") or "")[:600],
                            "at": e.get("createdAt"),
                        }
                        for e in fresh[-40:]
                    ],
                },
            )

    def run(self) -> None:
        while True:
            try:
                snap = self.snapshot()
                self.last_error = None
                if snap != self.state:
                    changed = {
                        k: v for k, v in snap.items()
                        if k != "ts" and self.state.get(k) != v
                    }
                    if self.state:
                        publish("delta", changed)
                    else:
                        publish("snapshot", snap)
                    self.state = snap
                lead = next((a for a in snap["agents"] if a.get("role") == "ceo"), None)
                self.lead_id = lead["id"] if lead else None
                busy = any(a["status"] == "running" for a in snap["agents"])
                if busy:
                    self.tail_runs(snap["agents"])
                self.ticks = getattr(self, "ticks", 0) + 1
                if self.ticks % 10 == 1:  # spend moves slowly; don't hammer the API
                    self.refresh_spend(snap["agents"])
                time.sleep(POLL_BUSY if busy else POLL_IDLE)
            except Exception as exc:  # keep the loop alive through restarts
                self.last_error = str(exc)[:200]
                publish("error", {"message": self.last_error})
                time.sleep(5)


poller = Poller()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # journald already timestamps
        pass

    def authorized(self, params) -> bool:
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer ") and header[7:] == TOKEN:
            return True
        return params.get("token", [None])[0] == TOKEN

    def do_GET(self):
        url = urlparse(self.path)
        params = parse_qs(url.query)

        if url.path == "/health":
            body = json.dumps(
                {
                    "status": "ok",
                    "subscribers": len(subscribers),
                    "agents": len(poller.state.get("agents", [])),
                    "lastError": poller.last_error,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if url.path == "/asks":
            if not self.authorized(params):
                self.send_error(401)
                return
            which = params.get("status", ["pending"])[0]
            self.json_response(asks.pending() if which == "pending" else asks.recent())
            return



        if url.path == "/spend":
            if not self.authorized(params):
                self.send_error(401)
                return
            self.json_response(poller.spend)
            return

        if url.path.startswith("/asks/"):
            if not self.authorized(params):
                self.send_error(401)
                return
            ask = asks.get(url.path.split("/")[2])
            if ask is None:
                self.send_error(404)
                return
            self.json_response(ask)
            return

        if url.path != "/stream":
            self.send_error(404)
            return
        if not self.authorized(params):
            self.send_error(401)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        q: "queue.Queue[str]" = queue.Queue(maxsize=200)
        with subscribers_lock:
            subscribers.add(q)
        try:
            # every new subscriber starts from a full picture
            first = f"event: snapshot\ndata: {json.dumps(poller.state, separators=(',', ':'))}\n\n"
            self.wfile.write(first.encode())
            self.wfile.flush()
            while True:
                try:
                    chunk = q.get(timeout=20)
                except queue.Empty:
                    chunk = ": keepalive\n\n"  # keeps NAT and iOS from dropping us
                self.wfile.write(chunk.encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with subscribers_lock:
                subscribers.discard(q)

    def json_response(self, payload, code: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        url = urlparse(self.path)
        params = parse_qs(url.query)
        if not self.authorized(params):
            self.send_error(401)
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_error(400, "invalid JSON")
            return

        # agent asks Luka something
        if url.path == "/asks":
            headline = (payload.get("headline") or "").strip()
            if not headline:
                self.send_error(400, "headline is required")
                return
            ask = asks.create(
                agent=payload.get("agent") or "Agent",
                headline=headline,
                detail=payload.get("detail"),
                options=payload.get("options") or [],
                issue=payload.get("issue"),
                urgency=payload.get("urgency") or "normal",
            )
            publish("ask", ask)
            self.json_response(ask, 201)
            return


        self.send_error(404)


def main() -> None:
    if not TOKEN or not COMPANY or not PAPERCLIP:
        raise SystemExit(
            "PAPERCLIP_TOKEN, PAPERCLIP_COMPANY and PAPERCLIP_API must be set"
        )
    poller.start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"paperclip-bridge listening on http://{BIND}:{PORT} → {PAPERCLIP}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
