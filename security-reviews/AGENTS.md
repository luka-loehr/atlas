# AGENTS.md (security-reviews)

## Scope

These rules apply to every file under `security-reviews/` of
`luka-loehr/atlas`. They add to the repository's own guidance.

## Purpose

`security-reviews/` holds traceable security review and audit artifacts
for `luka-loehr/atlas` (Rust/axum server, S3/IAM, PostgreSQL + pgvector,
GPU ML worker, Cloudflare Share Worker, CLI, and SwiftUI iOS/macOS app).
It covers the tracks architecture, threat model, service and API pentest,
cryptographic implementation, system audit, quality and maintainability,
operations, and privacy. It contains no product code and no raw operational
data.

## Sources of truth

- `INDEX.md` is the canonical register (its generated block is rebuilt from `findings/`).
- `QUEUE.md` is the coordinating work list.
- `AUTHORIZATION.md` is the only source of permission for active tests.
- Single findings live under `findings/`, runs under `runs/`, fixes under `fix-logs/`.
- `humans_read_this_first.html` and `audits.html` are generated reading layers.

## Review run

A review run is analysis only.

- Only files under `security-reviews/` may be created or changed (plus `.github/workflows/security-reviews.yml` when setting up or maintaining CI validation).
- Product code, tests, scripts outside `security-reviews/` and product docs stay unchanged.
- The whole repository may be read and examined statically.
- Local compile, parser, lint and unit checks are allowed when they call no external target
  and change no operational state: `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `npm --prefix share test`.
- Active HTTP, WebSocket, or database tests are allowed only within
  `AUTHORIZATION.md` and the harness documents (local `127.0.0.1` ephemeral instances and local test Postgres only).
- Findings carry evidence and are redacted. Guesses are written down as assumptions or open questions.

## Hard boundaries

- Never print, store or commit secret values: Atlas access/secret keys (`ATLK...`, `atls_...`),
  tokens, cookies, passwords, sealing keys, database URLs with passwords, Cloudflare API tokens,
  or private keys. Record where a secret lives, never its value.
- Never connect to the owner's personal machines, live Atlas hosts, or other projects.
- Raw request or response bodies, raw logs, database dumps and personal media are not evidence.
- Allowed evidence: redacted code references, status codes, header names, booleans, counts,
  latencies, checksums, commit ids and minimal synthetic marker results.

## Light audit mode

The tracks `system-audit`, `quality-maintainability`, `operations` and `privacy` may use a light audit mode.

- `report.md` uses `templates/AUDIT_REPORT_TEMPLATE.md`.
- Pure quality, maintenance, operations or process findings use `AUD-*` and
  `templates/AUDIT_FINDING_TEMPLATE.md`.
- Findings with a direct security effect use `SEC-*` (track codes `ARCH`, `TM`, `SVC`, `CRYPTO`, `SYS`, `OPS`, `PRIV`).
- "checked without finding" is an audit note, not a security PASS.
- As soon as an audit note is meant as an all-clear, PASS or risk acceptance, it becomes a PASS
  statement or finding with the verify chain below.

## Verify and re-verify

The agent that builds a change verifies it itself (owner decision 2026-10-31). There is no
independent verify, no second model and no fresh-session requirement, and no verify task has
to be queued for someone else.

1. A review produces a finding or a PASS statement.
2. The reviewer verifies it with evidence (reproduction, test, code proof) and records agent, model
   and session in `Verify by/model/session`.
3. A confirmed finding stays and gets a fix run when ordered.
4. A refuted finding becomes `rejected` with the evidence.
5. The fixer verifies its own fix (tests plus a local check where the finding was reproduced), records it
   as `Re-verify status: confirmed` with agent, model and session, and adds the evidence to the
   status history.

Rules:

- A `fixed` finding has `Re-verify status: confirmed` (the builder's own verification).
- A PASS statement or finding with `verify_status: pending` is unverified; pages show it as
  "Verify open" until its author verified it.
- A later finding visibly limits an older PASS in the same area.
- The validator enforces these rules; do not weaken it to make a register pass.

## Finding status

`open`, `in_progress` (a fix exists on a branch, in an unreleased commit or awaits deploy),
`owner-decision` (needs the owner; the finding lists exact steps), `fixed` (commit or change
referenced and deployed or not deployable), `accepted` (risk accepted by the owner, with
reference), `rejected`, `duplicate`, `blocked`.

Verify status: `pending`, `confirmed`, `refuted`, `blocked`.
Re-verify status: `not-applicable`, `pending`, `confirmed`, `failed`.

Run status: `in_review`, `completed`, `blocked`, `aborted`, `register_sync_open`.
Register status: `pending`, `synced`, `blocked`. Redaction status: `pending`, `checked`, `blocked`.
Cleanup: `not_applicable`, `pending`, `checked`, `intentionally_retained`, `blocked`.

## Fix run

A fix run follows `FIX_AGENT_GUIDE.md`: fix log first, finding to `in_progress`, change, checks,
commit and push to `main`, deploy where applicable, finding to `fixed` only with a
commit reference, the deploy state and the fixer's own verification (`Re-verify status: confirmed`).

## Required files of a run

```text
runs/<run-id>/
├── metadata.json
├── report.md
├── trail.md
├── human-summary.md
├── index-fragment.md
└── evidence/
    ├── commands.md
    ├── evidence-index.md
    └── artifacts/        (optional, redacted only)
```

## Attribution

Every claim, run, finding, fix and piece of evidence names the agent or thread, the exact model
(or `unknown`; never guess), the session, the tooling, the time window and the commit.

## Parallel work

Before a run: read `README.md`, this file, `AUTHORIZATION.md`, `INDEX.md`, `QUEUE.md` and the
track file; search findings; check `claims/`; create your claim and run folder; explain overlaps
in the trail. A claim is not a hard lock: after 24 hours without visible progress it is worth
checking, after 48 hours it is stale.

## Evidence and redaction

Every artifact names source, time, agent, model, redaction status and what it shows. Not allowed:
full request or response bodies of real services, full tokens, cookies or keys, `.env` contents,
private network addresses (write placeholders such as `<tailnet-address>` or `<lan-address>`), raw logs, database
dumps, personal names or e-mail addresses of real users (write `<owner-email>`).

## Human pages

After new findings, status changes or fixes:

```bash
python3 security-reviews/scripts/update_humans_read_this_first.py
python3 security-reviews/scripts/update_audits_html.py
python3 security-reviews/scripts/check_review_system.py
```

Never edit generated HTML or the generated block of `INDEX.md` by hand.

## File and id rules

- Run ids and claim files: `YYYYMMDD-HHMMSS-<track>-<scope>-<agent>`, only `a-z`, `0-9`, `-`.
- Security findings: `SEC-YYYYMMDD-HHMMSS-<CODE>-NNN`, codes `ARCH`, `TM`, `SVC`, `CRYPTO`, `SYS`, `OPS`, `PRIV`.
- Audit findings: `AUD-YYYYMMDD-<SCOPE>-NNN`, scopes `SYSTEM`, `QUALITY`, `OPS`.
- PASS statements: `PASS-YYYYMMDD-NNN` in `data/passes.json`.
- Queue tasks: `SECQ-YYYYMMDD-NNN`.
- On a collision raise the time or the number.

## Done criterion

A run is completed only when scope, attribution, trail, evidence, redaction, cleanup and the
register sync are documented. A blocked active test is never replaced by a static check and
reported as passed.
