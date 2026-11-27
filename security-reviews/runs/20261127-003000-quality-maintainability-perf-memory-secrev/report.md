# Review report: 20261127-003000-quality-maintainability-perf-memory-secrev

- Track: `quality-maintainability`
- Scope: `perf-memory`
- Queue: `SECQ-20261127-003`
- Agent / Model: `secrev` / `Gemini 4 Neon`
- Session: `secrev@2026-11-27 (security-review session ca10409f)`
- Repository state: `d068e6d`
- Authorization: [`AUTHORIZATION.md`](../../AUTHORIZATION.md#authorized-active-targets)

## Summary

Audited memory allocations, query concurrency, and panic safety across crates/server, crates/core, and crates/ml. Found 1 medium (drive/browse.rs snippet() dual Vec<char> allocation on up to 60x 200k-char documents) and 2 low (sequential DB/systemctl calls in hot read endpoints, unchecked Mutex/RwLock unwrap() calls in server paths).

## Findings

- [AUD-20261127-QUALITY-001](../../findings/AUD-20261127-QUALITY-001.md) (medium): drive/browse.rs snippet() allocates two full Vec<char> copies of extracted PDF text per search result
- [AUD-20261127-QUALITY-002](../../findings/AUD-20261127-QUALITY-002.md) (low): Sequential DB queries and host subprocess calls in drive/browse.rs and system/host.rs
- [AUD-20261127-QUALITY-003](../../findings/AUD-20261127-QUALITY-003.md) (low): Unchecked Mutex and RwLock unwrap() calls in server request and worker paths

## PASS statements

- None.

## Redaction and cleanup

- Redaction: checked; no raw secrets, private IPv4 addresses, real tailnet hostnames, or personal emails recorded.
- Cleanup: not applicable (read-only static analysis and local unit tests only).
