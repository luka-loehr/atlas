# agents — the atlas agents platform

Long-running AI agents that live on atlas. Each agent gets a section here;
the agent's actual home (code, state, secrets) lives outside the repo on the
atlas box. No iOS app yet — this is the server-side platform.

## hermes

Luka's personal agent, migrated 2026-07-23 from the Mac (launchd) to atlas —
full state carried over: `state.db` (95k messages, 515 sessions, FTS),
state-snapshots, sessions, skills, cron, memories, SOUL.md, config + secrets,
plus `~/hermes-workspace`. Platform-specific parts (venv, node_modules,
caches, logs) were rebuilt on Linux, not copied. The Mac copy stays intact as
rollback (launchd services disabled, not deleted). WhatsApp was dropped
entirely during the migration (bloat; session was already logged out) —
**Telegram is the only messaging platform**.

- **Home**: `~/.hermes` (state) + `~/.hermes/hermes-agent` (upstream
  `NousResearch/hermes-agent` checkout). Runtime: uv-managed venv
  (Python 3.12; repo requires `<3.14` — atlas system python is 3.14).
- **Service**: hermes manages its own systemd **user** unit
  (`hermes gateway install --force`), linger enabled so it runs headless.
  Status: `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status
  hermes-gateway`, logs in `~/.hermes/logs/gateway.log`.
- **CLI**: `hermes` on PATH (`~/.local/bin/hermes` wrapper →
  `venv/bin/hermes`, symlinked to `/usr/local/bin/hermes`).
- **Self-update**: `hermes update` — pulls upstream, syncs venv + skills,
  migrates config, drains and restarts its own gateway. Verified working
  (v0.18.2 → v0.19.0 on migration day).
- **Reauth a provider**: `hermes auth add <provider> --type oauth
  --no-browser` (e.g. `openai-codex`), then open the printed URL anywhere.
- **Email platform removed** (2026-07-23, Luka's call): it depended on a
  Proton Mail Bridge that only existed on the Mac. `EMAIL_*` vars stripped
  from `~/.hermes/.env` — Telegram is the sole platform.
