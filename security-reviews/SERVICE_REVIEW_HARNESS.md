# Service review harness

Status: binding. Applies to local active tests against `atlas-server`, `atlas-ml`, `atlas` CLI, or the Cloudflare Share Worker in `luka-loehr/atlas`.

## Purpose

Service reviews exercise the real HTTP/WebSocket handlers, S3/IAM auth, Postgres queries, and Share Worker routes locally. They must stay strictly inside `AUTHORIZATION.md` (local `127.0.0.1` ephemeral instances and local test Postgres only) and leave nothing behind.

## Required properties of a run

- Ephemeral temporary directories and throwaway test keys/tokens (never real credentials or `/etc/atlas/atlas.env`).
- Services bound strictly to `127.0.0.1`.
- Dedicated throwaway Postgres database when DB tests run.
- Small request budgets; no external network calls.
- Freeze rule checked before the run.
- Cleanup of processes, temporary directories, and test databases verified at the end.

## Allowed test types

- Auth and authorization checks (unauthenticated, wrong key, expired/revoked key, scope checks, WebSocket handshake and Origin checks).
- Input validation, path confinement, streaming upload limits, unbounded vector payloads, PDF/media preview edge cases.
- Share Worker unit tests (`npm --prefix share test`) covering crypto, range requests, admin auth, and HTML escaping.
- Local unit and integration tests (`cargo test`).

## Evidence

Exit codes, status codes, header names, timings, redacted code references, and unit test counts. Never raw secrets, private IPv4s, or real user data.

## Abort

Stop on an unexpected target, real data, an unexpected mutation, or an unclear cleanup.
