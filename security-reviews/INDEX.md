# Security review register

Updated: 2026-11-27

This register is the canonical overview of review runs, security findings (`SEC-*`), audit findings (`AUD-*`), PASS statements and self-verification for `luka-loehr/atlas`. Details stay in the linked finding files and runs. The block between the markers is generated from `findings/`, `data/passes.json` and `runs/` by `scripts/update_humans_read_this_first.py`.

## System state

- 2026-11-27: security-reviews framework ported to `luka-loehr/atlas` and four baseline whole-codebase review runs completed at `d068e6d`: 9 `SEC-*` findings (1 high, 6 medium, 2 low), 4 `AUD-*` findings (1 medium, 3 low), and 5 `PASS-*` statements, all self-verified by their author with code/test evidence (owner rule 2026-10-31).
- All 13 open findings have corresponding `fix` tasks (`SECQ-20261127-005`..`SECQ-20261127-017`) queued in [`QUEUE.md`](QUEUE.md).

<!-- BEGIN GENERATED: scripts/update_humans_read_this_first.py -->

## Counts

| Kind | open | in_progress | owner-decision | fixed | accepted | rejected | duplicate | blocked |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SEC | 9 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| AUD | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Verify pending: 0 findings, 0 PASS statements. Re-verify pending: 0 fixes.

## Security findings (SEC)

| ID | Status | Severity | Track | Title | Fix | Verify | Re-verify | Needs host |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [SEC-20261127-001001-ARCH-001](findings/SEC-20261127-001001-ARCH-001.md) | open | high | architecture | WebSocket endpoints lack Origin validation and /v1/system/terminal inherits server secrets into the PTY shell | - | confirmed | not-applicable | no |
| [SEC-20261127-001000-TM-001](findings/SEC-20261127-001000-TM-001.md) | open | medium | threat-model | Bearer token accepted in URL query string on every /v1 route including terminal, power and mutation endpoints | - | confirmed | not-applicable | no |
| [SEC-20261127-001002-CRYPTO-001](findings/SEC-20261127-001002-CRYPTO-001.md) | open | medium | crypto-implementation | decode_aws_chunked_bytes discards chunk signatures and has an integer overflow in slice bounds | - | confirmed | not-applicable | no |
| [SEC-20261127-002000-SVC-001](findings/SEC-20261127-002000-SVC-001.md) | open | medium | service-pentest | Unbounded Vec batch inputs across Photos and Drive endpoints allow excessive DB and memory load | - | confirmed | not-applicable | no |
| [SEC-20261127-002001-SVC-001](findings/SEC-20261127-002001-SVC-001.md) | open | medium | service-pentest | Unbounded concurrent pdftoppm execution on Drive thumbnails and unbounded subprocess pipe buffering | - | confirmed | not-applicable | no |
| [SEC-20261127-004000-OPS-001](findings/SEC-20261127-004000-OPS-001.md) | open | medium | operations | disk-guard.sh sources a mutable state file with fallback to world-writable /var/tmp | - | confirmed | not-applicable | no |
| [SEC-20261127-004001-OPS-001](findings/SEC-20261127-004001-OPS-001.md) | open | medium | operations | Postgres backup dumps lack restrictive umask and atlas-server systemd/install lack permission and hardening guards | - | confirmed | not-applicable | no |
| [SEC-20261127-002002-SVC-001](findings/SEC-20261127-002002-SVC-001.md) | open | low | service-pentest | Share Worker putManifest buffers full body before size check and parseRange omits safe-integer check | - | confirmed | not-applicable | no |
| [SEC-20261127-004002-SYS-001](findings/SEC-20261127-004002-SYS-001.md) | open | low | system-audit | CLI ssh invocations omit -- host option separator and exec.rs interpolates remote paths unquoted | - | confirmed | not-applicable | no |

## Audit findings (AUD)

| ID | Status | Severity | Track | Title | Fix | Verify | Re-verify | Needs host |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [AUD-20261127-QUALITY-001](findings/AUD-20261127-QUALITY-001.md) | open | medium | quality-maintainability | drive/browse.rs snippet() allocates two full Vec<char> copies of extracted PDF text per search result | - | confirmed | not-applicable | no |
| [AUD-20261127-OPS-001](findings/AUD-20261127-OPS-001.md) | open | low | operations | Swift API.swift force-unwraps URLComponents and Session.normalize does not restrict schemes to http/https | - | confirmed | not-applicable | no |
| [AUD-20261127-QUALITY-002](findings/AUD-20261127-QUALITY-002.md) | open | low | quality-maintainability | Sequential DB queries and host subprocess calls in drive/browse.rs and system/host.rs | - | confirmed | not-applicable | no |
| [AUD-20261127-QUALITY-003](findings/AUD-20261127-QUALITY-003.md) | open | low | quality-maintainability | Unchecked Mutex and RwLock unwrap() calls in server request and worker paths | - | confirmed | not-applicable | no |

## PASS statements (verified by their author with evidence)

| ID | Verify | Scope | Statement | Origin run |
| --- | --- | --- | --- | --- |
| PASS-20261127-001 | confirmed | crypto-sealing | atlas-common secret sealing (crates/common/src/crypto.rs) derives AES-256-GCM keys via HKDF-SHA256 with domain salt/info, generates 96-bit SystemRandom nonces, binds AAD (access_key_id), rejects master secrets shorter than 16 bytes, and uses subtle::ConstantTimeEq (cargo test -p atlas-common: 9/9 passed at d068e6d). | `runs/20261127-001000-architecture-auth-ws-crypto-secrev/` |
| PASS-20261127-002 | confirmed | system-host-command-safety | crates/server/src/system/host.rs validates Docker container names with safe_name() (rejecting leading '-', '/', and non-alphanumeric characters), restricts /v1/system/power/{action} to exact shutdown/restart -> sudo -n systemctl poweroff\|reboot, and bounds all host commands with kill_on_drop(true) and an 8-second timeout at d068e6d. | `runs/20261127-001000-architecture-auth-ws-crypto-secrev/` |
| PASS-20261127-003 | confirmed | upload-streaming-and-path-confinement | crates/server/src/upload.rs, util.rs, media.rs, and drive/blobs.rs stream uploads to disk under max_upload without buffering bodies in RAM, enforce 64-hex content IDs, allowlist media extensions (fallback bin), canonicalize and confine library paths (util::confine), force Content-Disposition: attachment for HTML/SVG/XML, and send X-Content-Type-Options: nosniff at d068e6d. | `runs/20261127-002000-service-pentest-api-share-secrev/` |
| PASS-20261127-004 | confirmed | share-worker-crypto-and-xss | Cloudflare Share Worker (share/src/crypto.ts, html.ts, admin.ts, public.ts) uses WebCrypto PBKDF2-SHA256 (100,000 iterations, 16-byte CSPRNG salt), constant-time safeEqual, HMAC-SHA256 HttpOnly Secure SameSite=Lax session cookies, per-request 128-bit CSP nonces (default-src 'none'), HTML/scriptJson escaping, allow_download enforcement, and fail-closed SHARE_TOKEN admin auth at d068e6d. | `runs/20261127-002000-service-pentest-api-share-secrev/` |
| PASS-20261127-005 | confirmed | firewall-and-repo-hygiene | scripts/firewall/firewall.nft confines TCP port 8787 strictly to lo and tailscale0 in an independent table inet atlas-fw (dropping LAN and Docker bridge traffic), and repository hygiene scan at d068e6d found zero real Atlas keys, zero real private tailnet hostnames, and zero personal emails (cargo test -p atlas-cli: 5/5 passed). | `runs/20261127-004000-operations-cli-scripts-swift-secrev/` |

## Runs

| Run | Track | Status | Register | Redaction |
| --- | --- | --- | --- | --- |
| [20261127-001000-architecture-auth-ws-crypto-secrev](runs/20261127-001000-architecture-auth-ws-crypto-secrev/report.md) | architecture | completed | synced | checked |
| [20261127-002000-service-pentest-api-share-secrev](runs/20261127-002000-service-pentest-api-share-secrev/report.md) | service-pentest | completed | synced | checked |
| [20261127-003000-quality-maintainability-perf-memory-secrev](runs/20261127-003000-quality-maintainability-perf-memory-secrev/report.md) | quality-maintainability | completed | synced | checked |
| [20261127-004000-operations-cli-scripts-swift-secrev](runs/20261127-004000-operations-cli-scripts-swift-secrev/report.md) | operations | completed | synced | checked |

<!-- END GENERATED -->
