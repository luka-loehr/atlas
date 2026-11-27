# Fix log: server-auth-ws-bounds

Fix log id: `20261127-030000-server-auth-ws-bounds-atlaslead`
Findings: SEC-20261127-001000-TM-001, SEC-20261127-001001-ARCH-001, SEC-20261127-001002-CRYPTO-001, SEC-20261127-002000-SVC-001, SEC-20261127-002001-SVC-001, AUD-20261127-QUALITY-001, AUD-20261127-QUALITY-002, AUD-20261127-QUALITY-003
Status: fixed
Agent: atlaslead
Model: Gemini 4 Neon
Session: atlaslead@2026-11-27 (overnight v0.6.0 session)
Start: 2026-11-27T02:50:00+00:00
End: 2026-11-27T03:36:00+00:00
Commits: 7fa950e
Deploy: n/a (merged to main for v0.6.0 release)

## Order

- Ordered by: owner overnight v0.6.0 engineering & security directive
- Goal: Harden query-token scope, WebSocket Origin & PTY env scrubbing, aws-chunked overflow bounds, batch Vec caps, pdftoppm semaphore & pipe caps, UTF-8 snippet windowing, concurrent queries, and lock-poison recovery.
- Non-goals: none

## Changes

| File or resource | Change | Reason |
| --- | --- | --- |
| `7fa950e` | Applied atomic hardening fixes and regression tests | Close `SEC-20261127-001000-TM-001, SEC-20261127-001001-ARCH-001, SEC-20261127-001002-CRYPTO-001, SEC-20261127-002000-SVC-001, SEC-20261127-002001-SVC-001, AUD-20261127-QUALITY-001, AUD-20261127-QUALITY-002, AUD-20261127-QUALITY-003` |

## Checks

| Time | Check | Result |
| --- | --- | --- |
| 2026-11-27T03:35:00+00:00 | `cargo clippy --all-targets -- -D warnings && cargo test` + `vitest` | Passed (0 warnings, 0 failures) |

## Result

- Finding status after the fix: `fixed` (`Re-verify status: confirmed`)
- Own verification of the fix (tests, live check, evidence): unit + live Postgres/TCP E2E regression tests passed on `main` at `b62c0a7`.

## Open risks

None.
