# Authorization for security reviews

Status: binding. Owner authorization of 2026-11-27.
Repository: `luka-loehr/atlas` (public).

## Principle

Active tests are allowed only against the targets below. Everything
else is blocked until this file says otherwise.

## Authorized active targets

| Target | What is allowed | Limits |
| --- | --- | --- |
| Local `127.0.0.1` ephemeral Atlas server (`atlas-server`) | HTTP/WebSocket API tests, S3/IAM tests, upload/download/share/drive/photos tests with ephemeral throwaway data and keys | Ephemeral data directory and keys created per run, bound to `127.0.0.1` only, stopped and removed at the end |
| Local test PostgreSQL (`127.0.0.1`) | Migrations, query/unit tests (`cargo test`), synthetic test rows | Dedicated throwaway database only, never a production or backup database |
| Local Cloudflare Share Worker unit tests (`share/`) | `npm --prefix share test` (in-memory bucket and local worker harness) | No live Cloudflare account calls, no Wrangler deploy |
| Local static analysis and CLI/Swift unit checks | `cargo fmt`, `cargo clippy`, `cargo test`, static inspection of `crates/`, `share/`, `scripts/`, `app/` | No live SSH, no network calls to real hosts |

## Never

- The owner's personal machines (including the live Atlas host, Mac, iPhone, or any tailnet host): never SSH to, start, stop, connect to, inspect or modify them during a review run.
- Other projects in the shared cloud or Cloudflare accounts, and any third-party service.
- The owner's real passwords, real Atlas keys (`ATLK...`, `atls_...`), real `/etc/atlas/atlas.env` contents, or real personal photos/drive data.
- Load or stress tests against any non-local target, credential stuffing, persistent exploits, or data exfiltration.

## Freeze rule

When the owner says he is using, upgrading, or testing Atlas, nobody deploys, restarts services, or runs active tests against shared resources until he is done. Check before every active run.

## Test data

- Ephemeral test databases, directories, buckets and keys are named with a run marker such as `secrev-<run-slug>`.
- Tokens, secrets and keys are never printed or committed; record their class only.
- Every temporary directory, process and test database is stopped and removed at the end and the cleanup checked.

## Abort

Stop immediately on an unexpected target, real user data, an unexpected mutation, repeated timeouts, or an unclear cleanup.
