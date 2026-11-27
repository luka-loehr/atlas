# Security reviews

This folder organizes security reviews and security-related audits of
`luka-loehr/atlas` (self-hosted cloud server in Rust/axum with S3/IAM,
PostgreSQL + pgvector, GPU ML worker, Cloudflare Share Worker, CLI, and
SwiftUI iOS/macOS app).

## Goal

The system makes traceable:

- what was reviewed
- who reviewed it and with which model and session
- which repository state (commit) applied
- which redacted evidence was collected
- which findings are open, fixed, accepted, rejected or waiting for an owner decision
- which findings and PASS statements are still unverified
- how each fix was verified by the agent that built it

## Tracks

- Architecture
- Threat model
- Service and API pentest
- Cryptographic implementation
- System audit
- Quality and maintainability
- Operations
- Privacy

Each track has repository-specific questions under [`tracks/`](tracks/).

## Quick start

1. Read [`AGENTS.md`](AGENTS.md) completely.
2. Read [`AUTHORIZATION.md`](AUTHORIZATION.md).
3. For local service or API tests read [`SERVICE_REVIEW_HARNESS.md`](SERVICE_REVIEW_HARNESS.md).
4. For browser tests read [`BROWSER_REVIEW_HARNESS.md`](BROWSER_REVIEW_HARNESS.md).
5. Check [`INDEX.md`](INDEX.md) and [`QUEUE.md`](QUEUE.md).
6. Read the matching track file under `tracks/`.
7. Search existing findings, claims and runs.
8. Create a claim and your own run folder from the templates.
9. Document redaction, cleanup and the register sync before you finish.

## Kinds of work

- Review runs analyze and change only `security-reviews/`.
- A finding verify checks with evidence whether a finding holds.
- A PASS verify checks with evidence whether a PASS statement holds.
- Fix runs change product code only when the coordinator or the owner asked for that fix ([`FIX_AGENT_GUIDE.md`](FIX_AGENT_GUIDE.md)).
- A re-verify is the fixer's own check of its fix (tests plus a local or live check).

An empty register is not a PASS. Every PASS, finding and fix is verified with
evidence by the agent that produced it; there is no independent verify
(owner decision 2026-10-31).

## Layout

- `claims/` visible work reservations.
- `runs/` review reports, trails and redacted evidence.
- `findings/` canonical `SEC-*` (security) and `AUD-*` (audit) findings.
- `fix-logs/` documented fixes.
- `reviewer-packs/` packs for external reviewers.
- `templates/` mandatory templates.
- `tracks/` repository-specific review questions.
- `data/` structured inputs for the generated pages.
- `scripts/` renderers and the register validator (runs in CI); `close_queue.py --by <agent>` closes finished verify rows (dry run unless `--apply`); its unit tests (`test_close_queue.py`) run in CI alongside `check_review_system.py`.

## Human entry points

- [`humans_read_this_first.html`](humans_read_this_first.html): security state, owner decisions, open verifies.
- [`audits.html`](audits.html): audit, quality and operations findings.

Both are generated; the citable sources stay `INDEX.md`, the finding files,
runs, trails and fix logs.

## Integrity check

```bash
python3 security-reviews/scripts/update_humans_read_this_first.py
python3 security-reviews/scripts/update_audits_html.py
python3 security-reviews/scripts/check_review_system.py
python3 -m unittest security-reviews/scripts/test_close_queue.py
```

The last two commands run in CI (`.github/workflows/security-reviews.yml`) on
every push and pull request and fail on schema, link, verify-chain,
authorization or redaction problems.

## Public repository rule

This repository is public. Its security reviews contain no internal host
names, private tailnet names, private IPv4 addresses, real e-mail addresses,
or raw secret values from `/etc/atlas/atlas.env`. `scripts/check_review_system.py`
enforces this with a public-repo redaction scan.
