# Guide for fix agents

Status: binding. Applies when the coordinator or the owner orders the fix of a `SEC-*` or `AUD-*`
finding in `luka-loehr/atlas`.

## Purpose

Review runs find and assess problems. Fix runs change product code, tests, configuration or docs.
The agent that fixes verifies its own fix with evidence and closes it (owner decision 2026-10-31);
there is no independent re-verify.

## Before the fix

1. Read `security-reviews/AGENTS.md`, this guide, the finding, its origin run and evidence.
2. Read `SERVICE_REVIEW_HARNESS.md` if local service checks are needed, `BROWSER_REVIEW_HARNESS.md` for web UI.
3. Create a fix log from `templates/FIX_LOG_TEMPLATE.md`.
4. Set the finding to `in_progress`, fill `Fixed by` (agent, model, session) and add a status history line.
5. Note the expected verification and the non-goals.

## During the fix

The fix log records changed product files, tests, docs, configuration,
checks run and their results, deviations from the recommended hardening, and open risks. No logs,
tokens or secret values as evidence.

## High-risk areas

- Auth, IAM/S3 signing, token handling, WebSocket Origin and query-token handling, secret sealing (`crates/common/src/crypto.rs`), path confinement, upload streaming, Share Worker crypto/escaping, systemd/firewall scripts, CLI SSH quoting.

Existing security rules are never weakened as a side effect.

## Commit, push, deploy

- Run the repository's checks before pushing: `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, and `npm --prefix share test` when `share/` changes.
- Commit and push to `main` (no AI attribution lines); keep `main` deployable.
- If a fix needs deployment to a host (`Needs host: yes`) and has not yet been deployed, keep the finding `in_progress` with `Deployed: no (unreleased)` until deployed, or `n/a` when the change is purely local/dev/docs.

## After the fix

- Update the finding: `Fix` (commit), `Deployed`, status, status history, how to verify.
- `fixed` only with a referenced commit (or documented infrastructure change) and a deploy state of
  `yes` or `n/a`; otherwise `in_progress`.
- Verify the fix yourself (the original reproduction or invariant, the new tests), set `Re-verify status: confirmed` with your agent, model and session, and put the evidence in the status history.
- Regenerate the pages and run `scripts/check_review_system.py`.
- Close the corresponding fix task in `QUEUE.md`.

## Minimum report

Finding, changed files, checks, status set, fix-log path, how the fix was verified, what could not be verified locally.
