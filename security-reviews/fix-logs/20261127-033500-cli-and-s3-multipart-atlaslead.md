# Fix log: cli-and-s3-multipart

Fix log id: `20261127-033500-cli-and-s3-multipart-atlaslead`
Findings: SEC-20261127-004002-SYS-001, SEC-20261127-033000-SVC-001
Status: fixed
Agent: atlaslead
Model: Gemini 4 Neon
Session: atlaslead@2026-11-27 (overnight v0.6.0 session)
Start: 2026-11-27T02:50:00+00:00
End: 2026-11-27T03:36:00+00:00
Commits: 9caa842, b62c0a7
Deploy: n/a (merged to main for v0.6.0 release)

## Order

- Ordered by: owner overnight v0.6.0 engineering & security directive
- Goal: Validate ATLAS_SSH_HOST, add -- before ssh_host() and eliminate unquoted $envf in atlas-cli, and confine S3 multipart uploadId directories + verify XML body SHA-256 digests.
- Non-goals: none

## Changes

| File or resource | Change | Reason |
| --- | --- | --- |
| `9caa842, b62c0a7` | Applied atomic hardening fixes and regression tests | Close `SEC-20261127-004002-SYS-001, SEC-20261127-033000-SVC-001` |

## Checks

| Time | Check | Result |
| --- | --- | --- |
| 2026-11-27T03:35:00+00:00 | `cargo clippy --all-targets -- -D warnings && cargo test` + `vitest` | Passed (0 warnings, 0 failures) |

## Result

- Finding status after the fix: `fixed` (`Re-verify status: confirmed`)
- Own verification of the fix (tests, live check, evidence): unit + live Postgres/TCP E2E regression tests passed on `main` at `b62c0a7`.

## Open risks

None.
