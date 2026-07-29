# agents — the atlas agent platform

Long-running AI agents that live on atlas. Their actual homes (state, secrets,
checkouts) are outside the repo on the box; what is tracked here is the glue
Luka wrote himself — the event bridge, the CLIs the agents call, and the
operating rules they share.

Two things run: **paperclip**, a company of agents that does delegated work,
and **hermes**, Luka's personal agent, which is that company's CEO.

## What is deliberately not here

The per-role onboarding documents are **not published**. Each one names a third
party's infrastructure and accounts — a school's self-hosted Forgejo instance
and the classmate who owns the repos, the commercial messaging account whose
keys send real mail — and points at the file on the box holding the live
credential for it, alongside standing risk notes about which units must not be
restarted. They live under `~/.paperclip` on the server and are held out of the
repo by `agents/.gitignore`. What is tracked is only the part that is safe to
read in public: `COMMS.md`, the shared operating rules, and
`hermes-skill/SKILL.md`, the manifest that frames Hermes as the CEO.

## paperclip

Open-source "autonomous companies" platform (paperclip.ing), installed
2026-07-23. System unit `paperclip` (`npx -y paperclipai run --bind tailnet`),
home `~/.paperclip` (embedded Postgres on :54329). UI and API on the tailnet at
`http://<atlas-tailnet-host>:3100`. CLI: `npx paperclipai <cmd>`.

Nothing about paperclip itself is tracked here — it is installed from npm and
its state lives in `~/.paperclip`.

Also on atlas: the native OpenAI **Codex CLI** (`codex`, installed via the
chatgpt.com install script; auth with `codex login`).

## hermes

Luka's personal agent, migrated 2026-07-23 from the Mac to atlas with its full
state (`state.db`, sessions, skills, cron, memories, SOUL.md, config) plus
`~/hermes-workspace`.

**Telegram is the only messaging platform.** Hermes reaches Luka over Telegram
and nowhere else: there is no WhatsApp integration and no email platform. The
mail gateway that used to sit here was removed — it needed a Proton bridge
running alongside it, which was never worth the moving part. Nothing in this
directory sends mail, and the agent CLIs below are the only other way anything
reaches Hermes.

- **Home**: `~/.hermes` (state) + `~/.hermes/hermes-agent` (upstream
  `NousResearch/hermes-agent` checkout). Runtime: uv-managed venv (Python 3.12;
  the repo requires `<3.14`, atlas' system python is 3.14). Nothing under
  `~/.hermes` is in this repo.
- **Service**: hermes manages its own systemd **user** unit
  (`hermes gateway install --force`), linger enabled so it runs headless.
  Status: `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status
  hermes-gateway`; logs in `~/.hermes/logs/gateway.log`.
- **CLI**: `hermes` on PATH (`~/.local/bin/hermes` wrapper → `venv/bin/hermes`,
  symlinked to `/usr/local/bin/hermes`).
- **Self-update**: `hermes update` — pulls upstream, syncs venv + skills,
  migrates config, drains and restarts its own gateway.
- **Reauth a provider**: `hermes auth add <provider> --type oauth --no-browser`
  (e.g. `openai-codex`), then open the printed URL anywhere.

## paperclip-bridge — what is actually in this directory

Paperclip has no outbound webhooks, so the iOS app would have to poll it from
the phone. `paperclip-bridge` polls the board API on the box instead, diffs the
result, and pushes only the changes to subscribers over SSE. It is stdlib-only
Python 3 — no venv, no wheels.

| File | What it is |
|---|---|
| `bridge.py` | The service. Poller thread + `ThreadingHTTPServer` on :3111 |
| `asks.py` | The ask store bridge.py imports — SQLite at `~/.paperclip/asks.db` |
| `paperclip-bridge.service` | System unit, `EnvironmentFile=/etc/paperclip-bridge.env` |
| `paperclip-bridge.env.example` | Template for that env file — every setting, no values |
| `ask-luka` | Agent CLI: ask Luka one question, block until he answers |
| `owner-sweep` | Timer CLI: route open, unowned issues to the Chief of staff and wake them |
| `paperclip-task` | Hermes' handle on the company: `create` / `list` / `inbox` / `result` / `comment` |
| `report-to-hermes` | Agent CLI: hand a finished task or a question up to Hermes |
| `COMMS.md` | The company's operating rules — how work is finished, owned and escalated |
| `hermes-skill/SKILL.md` | Claude skill manifest (`name: paperclip`) that frames Hermes as the CEO |

### File convention

- **No extension = an executable the agents invoke by bare name.** Each one has
  a `#!/usr/bin/env python3` shebang, is mode `755`, and is documented by name
  in `COMMS.md` or `hermes-skill/SKILL.md`. They are put on the agents' PATH by
  symlink on the box; nothing imports them.
- **`.py` = a module of the bridge service**, run by the interpreter from the
  unit (`ExecStart=/usr/bin/python3 .../bridge.py`), never invoked by name.

### HTTP surface

Auth is the same board API key as the app, sent as `Authorization: Bearer <key>`
or `?token=` (EventSource cannot set headers).

| Route | |
|---|---|
| `GET /health` | Plain JSON, no auth: subscriber count, agent count, last error |
| `GET /stream` | SSE — a full `snapshot`, then `delta`, `run`, `ask` and `error` events |
| `GET /asks[?status=]` | Pending (default) or recent asks |
| `GET /asks/<id>` | One ask |
| `GET /spend` | Per-agent token usage, priced per model |
| `POST /asks` | Register a question; publishes an `ask` event |

### Configuration

Everything deployment-specific comes from the environment — there are no
addresses, company ids or keys in the source. Copy
`paperclip-bridge.env.example` to `/etc/paperclip-bridge.env` (mode 600) and
fill it in.

`bridge.py` refuses to start unless `PAPERCLIP_TOKEN`, `PAPERCLIP_COMPANY` and
`PAPERCLIP_API` are set. `BRIDGE_BIND` is the one setting with a fallback, and
it fails closed: unset **and** empty both land on `127.0.0.1`, never `0.0.0.0`.
The empty case is the one that matters — `EnvironmentFile=` turns a bare
`BRIDGE_BIND=` into an empty string, and `ThreadingHTTPServer` reads an empty
host as every interface, which would publish a tailnet-only service on the LAN.
The four CLIs likewise exit 3 with a clear message when their URL or company id
is unset.

The board API key itself is never in the repo. On the box it lives in
`/etc/paperclip-bridge.env` and `~/.paperclip/atlas-automation.key`; in the iOS
app it lives in the gitignored `Secrets.swift` (see
`apps/atlas-agents/ios/Sources/Shared/Secrets.example.swift`).

### Known gaps

These are real and worth fixing; they are recorded here rather than papered over.

- **`/board/*` is not implemented by this `bridge.py`.** The iOS app's
  `BoardAPI.swift` calls `GET /board/issues`, `/board/issues/{key}` and
  `/board/fleet` on port 3111, and this service routes none of them.
- **An ask cannot be answered through the bridge.** `POST /asks` creates one and
  `GET /asks/<id>` reads it back, but there is no route that calls
  `asks.answer()` or `asks.cancel()`, so `ask-luka` can only ever time out
  (exit 2) and `asks.pending()` returns the question forever.
