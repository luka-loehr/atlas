# Security review queue

Updated: 2026-11-27

The queue coordinates reviews, audits, fixes and reviewer packs for `luka-loehr/atlas`. A claim under `claims/` reserves work visibly but is not a hard lock. Statuses: open, claimed, in_review, done, blocked, superseded. Types: review, audit, finding-verify, pass-verify, fix-reverify, fix, infra, reviewer-pack.

Rules: the agent that builds a change verifies it itself and records the result with evidence in the finding or in `data/passes.json` (agent, model, session); no verify task is queued for someone else (owner decision 2026-10-31).

## Tasks

| Task | Status | Type | Track | Scope | Priority | Findings | Claim | Note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SECQ-20261127-001 | done | review | architecture | auth-ws-crypto | p1 | SEC-20261127-001000-TM-001, SEC-20261127-001001-ARCH-001, SEC-20261127-001002-CRYPTO-001, PASS-20261127-001, PASS-20261127-002 | 20261127-001000-architecture-auth-ws-crypto-secrev | Completed and self-verified by secrev (Gemini 4 Neon) at d068e6d; findings and PASS statements synced. |
| SECQ-20261127-002 | done | review | service-pentest | api-share | p1 | SEC-20261127-002000-SVC-001, SEC-20261127-002001-SVC-001, SEC-20261127-002002-SVC-001, PASS-20261127-003, PASS-20261127-004 | 20261127-002000-service-pentest-api-share-secrev | Completed and self-verified by secrev (Gemini 4 Neon) at d068e6d; findings and PASS statements synced. |
| SECQ-20261127-003 | done | audit | quality-maintainability | perf-memory | p2 | AUD-20261127-QUALITY-001, AUD-20261127-QUALITY-002, AUD-20261127-QUALITY-003 | 20261127-003000-quality-maintainability-perf-memory-secrev | Completed and self-verified by secrev (Gemini 4 Neon) at d068e6d; findings synced. |
| SECQ-20261127-004 | done | audit | operations | cli-scripts-swift | p1 | SEC-20261127-004000-OPS-001, SEC-20261127-004001-OPS-001, SEC-20261127-004002-SYS-001, AUD-20261127-OPS-001, PASS-20261127-005 | 20261127-004000-operations-cli-scripts-swift-secrev | Completed and self-verified by secrev (Gemini 4 Neon) at d068e6d; findings and PASS statement synced. |
| SECQ-20261127-005 | open | fix | threat-model | restrict-query-token | p1 | SEC-20261127-001000-TM-001 | - | Restrict ?token= auth to read-only media routes or media-scoped tokens; reject on /v1/system/* and mutations. |
| SECQ-20261127-006 | open | fix | architecture | ws-origin-and-terminal-env | p1 | SEC-20261127-001001-ARCH-001 | - | Validate Origin header on /v1/system/terminal and /v1/system/live; scrub server secrets from PTY env and bound concurrent sessions. |
| SECQ-20261127-007 | open | fix | crypto-implementation | aws-chunked-bounds-and-sig | p2 | SEC-20261127-001002-CRYPTO-001 | - | Fix checked_add overflow in decode_aws_chunked_bytes and verify or reject signed streaming chunks. |
| SECQ-20261127-008 | open | fix | service-pentest | bound-batch-vec-inputs | p2 | SEC-20261127-002000-SVC-001 | - | Add explicit array length caps on /v1/assets/*, /v1/drive/move, and /v1/drive/trash/* batch endpoints. |
| SECQ-20261127-009 | open | fix | service-pentest | bound-pdftoppm-and-pipe-buffer | p2 | SEC-20261127-002001-SVC-001 | - | Gate on-demand PDF thumbnail rendering with a semaphore/singleflight and cap stdout/stderr buffering in atlas_core::process::output. |
| SECQ-20261127-010 | open | fix | service-pentest | share-manifest-and-range-guards | p3 | SEC-20261127-002002-SVC-001 | - | Check Content-Length before reading manifest body in share/src/admin.ts and add Number.isSafeInteger checks in share/src/range.ts. |
| SECQ-20261127-011 | open | fix | quality-maintainability | drive-snippet-memory | p2 | AUD-20261127-QUALITY-001 | - | Eliminate full-text Vec<char> allocations in drive/browse.rs snippet() (or slice match window in SQL). |
| SECQ-20261127-012 | open | fix | quality-maintainability | concurrent-read-queries | p3 | AUD-20261127-QUALITY-002 | - | Run independent DB queries and host commands concurrently in drive/browse.rs and system/host.rs. |
| SECQ-20261127-013 | open | fix | quality-maintainability | lock-poison-handling | p3 | AUD-20261127-QUALITY-003 | - | Replace unchecked Mutex/RwLock .unwrap() calls in crates/server/src/ with poison-safe recovery. |
| SECQ-20261127-014 | open | fix | operations | disk-guard-no-source | p2 | SEC-20261127-004000-OPS-001 | - | Parse disk-guard.state without bash source and avoid world-writable /var/tmp fallback. |
| SECQ-20261127-015 | open | fix | operations | pg-backup-umask-and-systemd | p2 | SEC-20261127-004001-OPS-001 | - | Set umask 077 in scripts/pg-backup/backup.sh, verify /etc/atlas/atlas.env 0600 in install.sh, and harden atlas-server.service. |
| SECQ-20261127-016 | open | fix | system-audit | cli-ssh-option-and-quoting | p3 | SEC-20261127-004002-SYS-001 | - | Validate ATLAS_SSH_HOST against leading '-', pass -- before host in ssh calls, and quote remote paths in exec.rs/secrets.rs. |
| SECQ-20261127-017 | open | fix | operations | swift-url-scheme-and-unwrap | p3 | AUD-20261127-OPS-001 | - | Restrict Session.normalize to http/https schemes and remove URLComponents force-unwraps in API.swift. |
