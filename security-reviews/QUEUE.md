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
| SECQ-20261127-005 | done | fix | threat-model | restrict-query-token | p1 | SEC-20261127-001000-TM-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); ?token= restricted strictly to GET/HEAD media/blob playback routes. |
| SECQ-20261127-006 | done | fix | architecture | ws-origin-and-terminal-env | p1 | SEC-20261127-001001-ARCH-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); Origin validated on WS upgrades, PTY env scrubbed, max 4 sessions. |
| SECQ-20261127-007 | done | fix | crypto-implementation | aws-chunked-bounds-and-sig | p2 | SEC-20261127-001002-CRYPTO-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); checked_add bounds, 64 MiB cap, and chunk-signature validation. |
| SECQ-20261127-008 | done | fix | service-pentest | bound-batch-vec-inputs | p2 | SEC-20261127-002000-SVC-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); explicit batch array caps enforced on Photos and Drive endpoints. |
| SECQ-20261127-009 | done | fix | service-pentest | bound-pdftoppm-and-pipe-buffer | p2 | SEC-20261127-002001-SVC-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); 2-permit pdftoppm semaphore and 4 MiB pipe cap in atlas_core::process. |
| SECQ-20261127-010 | done | fix | service-pentest | share-manifest-and-range-guards | p3 | SEC-20261127-002002-SVC-001 | - | Fixed and self-verified in 410e5de by atlaslead (Gemini 4 Neon); streaming manifest cap and Number.isSafeInteger Range check (58/58 vitest). |
| SECQ-20261127-011 | done | fix | quality-maintainability | drive-snippet-memory | p2 | AUD-20261127-QUALITY-001 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); zero-full-copy fast_snippet UTF-8 windowing in drive/browse.rs. |
| SECQ-20261127-012 | done | fix | quality-maintainability | concurrent-read-queries | p3 | AUD-20261127-QUALITY-002 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); concurrent DB and host status probes via tokio::try_join!/join!. |
| SECQ-20261127-013 | done | fix | quality-maintainability | lock-poison-handling | p3 | AUD-20261127-QUALITY-003 | - | Fixed and self-verified in 7fa950e by atlaslead (Gemini 4 Neon); poison-safe lock recovery across server modules. |
| SECQ-20261127-014 | done | fix | operations | disk-guard-no-source | p2 | SEC-20261127-004000-OPS-001 | - | Fixed and self-verified in 410e5de by atlaslead (Gemini 4 Neon); safe key/value state parser and 0700 state dir in disk-guard.sh. |
| SECQ-20261127-015 | done | fix | operations | pg-backup-umask-and-systemd | p2 | SEC-20261127-004001-OPS-001 | - | Fixed and self-verified in 410e5de by atlaslead (Gemini 4 Neon); umask 077 in backup.sh, 0600 check in install.sh, systemd hardening. |
| SECQ-20261127-016 | done | fix | system-audit | cli-ssh-option-and-quoting | p3 | SEC-20261127-004002-SYS-001 | - | Fixed and self-verified in 9caa842 by atlaslead (Gemini 4 Neon); validate_ssh_host, -- separator on ssh/rsync, POSIX quoting. |
| SECQ-20261127-017 | done | fix | operations | swift-url-scheme-and-unwrap | p3 | AUD-20261127-OPS-001 | - | Fixed and self-verified in 410e5de by atlaslead (Gemini 4 Neon); http/https scheme validation and safe URLComponents handling. |
| SECQ-20261127-018 | done | review | service-pentest | v060-s3-iam-cli | p1 | SEC-20261127-033000-SVC-001, PASS-20261127-006, PASS-20261127-007, PASS-20261127-008 | 20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead | Completed delta v0.6.0 review by atlaslead (Gemini 4 Neon) at 9caa842; 1 high finding caught and 3 PASS statements confirmed. |
| SECQ-20261127-019 | done | fix | service-pentest | confine-multipart-upload-id | p1 | SEC-20261127-033000-SVC-001 | - | Fixed and self-verified in b62c0a7 by atlaslead (Gemini 4 Neon); strict mpu_<hex> validation and E2E traversal regression test. |
