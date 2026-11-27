# Security review register

Updated: 2026-11-27

This register is the canonical overview of review runs, security findings (`SEC-*`), audit findings (`AUD-*`), PASS statements and self-verification for `luka-loehr/atlas`. Details stay in the linked finding files and runs. The block between the markers is generated from `findings/`, `data/passes.json` and `runs/` by `scripts/update_humans_read_this_first.py`.

## System state

- 2026-11-27: security-reviews framework ported to `luka-loehr/atlas`, four whole-codebase baseline review runs (`d068e6d`) plus one v0.6.0 delta review run (`9caa842`) completed across server, S3/buckets, IAM, ML/core, CLI, scripts, Share Worker, and Swift app.
- All 14 findings (10 `SEC-*`, 4 `AUD-*`) are `fixed` and self-re-verified (`Re-verify status: confirmed`) with unit and live E2E regression tests on `main` (`7fa950e`, `410e5de`, `9caa842`, `b62c0a7`); 8 `PASS-*` statements confirmed; `QUEUE.md` is 100% drained (`0` open tasks).

<!-- BEGIN GENERATED: scripts/update_humans_read_this_first.py -->

## Counts

| Kind | open | in_progress | owner-decision | fixed | accepted | rejected | duplicate | blocked |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SEC | 0 | 0 | 0 | 10 | 0 | 0 | 0 | 0 |
| AUD | 0 | 0 | 0 | 4 | 0 | 0 | 0 | 0 |

Verify pending: 0 findings, 0 PASS statements. Re-verify pending: 0 fixes.

## Security findings (SEC)

| ID | Status | Severity | Track | Title | Fix | Verify | Re-verify | Needs host |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [SEC-20261127-001001-ARCH-001](findings/SEC-20261127-001001-ARCH-001.md) | fixed | high | architecture | WebSocket endpoints lack Origin validation and /v1/system/terminal inherits server secrets into the PTY shell | 7fa950e | confirmed | confirmed | no |
| [SEC-20261127-033000-SVC-001](findings/SEC-20261127-033000-SVC-001.md) | fixed | high | service-pentest | Multipart upload directory join accepts unvalidated uploadId and unlinks directory before verifying DB ownership | b62c0a7 | confirmed | confirmed | no |
| [SEC-20261127-001000-TM-001](findings/SEC-20261127-001000-TM-001.md) | fixed | medium | threat-model | Bearer token accepted in URL query string on every /v1 route including terminal, power and mutation endpoints | 7fa950e | confirmed | confirmed | no |
| [SEC-20261127-001002-CRYPTO-001](findings/SEC-20261127-001002-CRYPTO-001.md) | fixed | medium | crypto-implementation | decode_aws_chunked_bytes discards chunk signatures and has an integer overflow in slice bounds | 7fa950e | confirmed | confirmed | no |
| [SEC-20261127-002000-SVC-001](findings/SEC-20261127-002000-SVC-001.md) | fixed | medium | service-pentest | Unbounded Vec batch inputs across Photos and Drive endpoints allow excessive DB and memory load | 7fa950e | confirmed | confirmed | no |
| [SEC-20261127-002001-SVC-001](findings/SEC-20261127-002001-SVC-001.md) | fixed | medium | service-pentest | Unbounded concurrent pdftoppm execution on Drive thumbnails and unbounded subprocess pipe buffering | 7fa950e | confirmed | confirmed | no |
| [SEC-20261127-004000-OPS-001](findings/SEC-20261127-004000-OPS-001.md) | fixed | medium | operations | disk-guard.sh sources a mutable state file with fallback to world-writable /var/tmp | 410e5de | confirmed | confirmed | no |
| [SEC-20261127-004001-OPS-001](findings/SEC-20261127-004001-OPS-001.md) | fixed | medium | operations | Postgres backup dumps lack restrictive umask and atlas-server systemd/install lack permission and hardening guards | 410e5de | confirmed | confirmed | no |
| [SEC-20261127-002002-SVC-001](findings/SEC-20261127-002002-SVC-001.md) | fixed | low | service-pentest | Share Worker putManifest buffers full body before size check and parseRange omits safe-integer check | 410e5de | confirmed | confirmed | no |
| [SEC-20261127-004002-SYS-001](findings/SEC-20261127-004002-SYS-001.md) | fixed | low | system-audit | CLI ssh invocations omit -- host option separator and exec.rs interpolates remote paths unquoted | 9caa842 | confirmed | confirmed | no |

## Audit findings (AUD)

| ID | Status | Severity | Track | Title | Fix | Verify | Re-verify | Needs host |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [AUD-20261127-QUALITY-001](findings/AUD-20261127-QUALITY-001.md) | fixed | medium | quality-maintainability | drive/browse.rs snippet() allocates two full Vec<char> copies of extracted PDF text per search result | 7fa950e | confirmed | confirmed | no |
| [AUD-20261127-OPS-001](findings/AUD-20261127-OPS-001.md) | fixed | low | operations | Swift API.swift force-unwraps URLComponents and Session.normalize does not restrict schemes to http/https | 410e5de | confirmed | confirmed | no |
| [AUD-20261127-QUALITY-002](findings/AUD-20261127-QUALITY-002.md) | fixed | low | quality-maintainability | Sequential DB queries and host subprocess calls in drive/browse.rs and system/host.rs | 7fa950e | confirmed | confirmed | no |
| [AUD-20261127-QUALITY-003](findings/AUD-20261127-QUALITY-003.md) | fixed | low | quality-maintainability | Unchecked Mutex and RwLock unwrap() calls in server request and worker paths | 7fa950e | confirmed | confirmed | no |

## PASS statements (verified by their author with evidence)

| ID | Verify | Scope | Statement | Origin run |
| --- | --- | --- | --- | --- |
| PASS-20261127-001 | confirmed | crypto-sealing | atlas-common secret sealing (crates/common/src/crypto.rs) derives AES-256-GCM keys via HKDF-SHA256 with domain salt/info, generates 96-bit SystemRandom nonces, binds AAD (access_key_id), rejects master secrets shorter than 16 bytes, and uses subtle::ConstantTimeEq (cargo test -p atlas-common: 9/9 passed at d068e6d). | `runs/20261127-001000-architecture-auth-ws-crypto-secrev/` |
| PASS-20261127-002 | confirmed | system-host-command-safety | crates/server/src/system/host.rs validates Docker container names with safe_name() (rejecting leading '-', '/', and non-alphanumeric characters), restricts /v1/system/power/{action} to exact shutdown/restart -> sudo -n systemctl poweroff\|reboot, and bounds all host commands with kill_on_drop(true) and an 8-second timeout at d068e6d. | `runs/20261127-001000-architecture-auth-ws-crypto-secrev/` |
| PASS-20261127-003 | confirmed | upload-streaming-and-path-confinement | crates/server/src/upload.rs, util.rs, media.rs, and drive/blobs.rs stream uploads to disk under max_upload without buffering bodies in RAM, enforce 64-hex content IDs, allowlist media extensions (fallback bin), canonicalize and confine library paths (util::confine), force Content-Disposition: attachment for HTML/SVG/XML, and send X-Content-Type-Options: nosniff at d068e6d. | `runs/20261127-002000-service-pentest-api-share-secrev/` |
| PASS-20261127-004 | confirmed | share-worker-crypto-and-xss | Cloudflare Share Worker (share/src/crypto.ts, html.ts, admin.ts, public.ts) uses WebCrypto PBKDF2-SHA256 (100,000 iterations, 16-byte CSPRNG salt), constant-time safeEqual, HMAC-SHA256 HttpOnly Secure SameSite=Lax session cookies, per-request 128-bit CSP nonces (default-src 'none'), HTML/scriptJson escaping, allow_download enforcement, and fail-closed SHARE_TOKEN admin auth at d068e6d. | `runs/20261127-002000-service-pentest-api-share-secrev/` |
| PASS-20261127-005 | confirmed | firewall-and-repo-hygiene | scripts/firewall/firewall.nft confines TCP port 8787 strictly to lo and tailscale0 in an independent table inet atlas-fw (dropping LAN and Docker bridge traffic), and repository hygiene scan at d068e6d found zero real Atlas keys, zero real private tailnet hostnames, and zero personal emails (cargo test -p atlas-cli: 5/5 passed). | `runs/20261127-004000-operations-cli-scripts-swift-secrev/` |
| PASS-20261127-006 | confirmed | iam-keys-sigv4-and-ratelimit | crates/server/src/iam/{mod,cache,handlers,ratelimit}.rs enforces constant-time master/Bearer secret comparisons, HKDF-SHA256 + AES-256-GCM AAD-bound secret sealing at rest, AWS SigV4 header & presigned URL verification (±15m skew, <=7d TTL), instant cache & rate-limiter eviction on key revoke/delete, coarse + bucket-level RBAC, and sharded per-key token-bucket 429 rate limiting (verified in s3_iam_openapi_e2e at b62c0a7). | `runs/20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead/` |
| PASS-20261127-007 | confirmed | s3-buckets-sync-and-gc | crates/server/src/{storage,s3}/* enforces strict bucket & object key normalization (rejecting '..', backslashes, control chars), streams uploads to temp files under max_upload with SHA-256/MD5 verification, serves zero-copy HTTP Range 206 responses with nosniff and safe Content-Disposition, garbage-collects blobs only when unreferenced across both objects and drive_files, and losslessly bridges media<->assets and files<->drive (verified in s3_iam_openapi_e2e & queue_db at b62c0a7). | `runs/20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead/` |
| PASS-20261127-008 | confirmed | cli-credentials-tty-and-openapi | crates/cli/src/{credentials,sanitize,client,cmd}/* writes credentials.json atomically with 0700 dir and 0600 O_EXCL temp-file permissions, strips ANSI CSI/OSC/DCS, C0/C1, and BiDi override sequences on all server-controlled terminal output, rejects path traversal in safe_join_local, and crates/server/src/openapi.rs passes automated live route-parity contract tests against the axum router (25/25 CLI tests + openapi_spec_is_3_1_and_covers_all_v1_and_s3_routes passed at b62c0a7). | `runs/20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead/` |

## Runs

| Run | Track | Status | Register | Redaction |
| --- | --- | --- | --- | --- |
| [20261127-001000-architecture-auth-ws-crypto-secrev](runs/20261127-001000-architecture-auth-ws-crypto-secrev/report.md) | architecture | completed | synced | checked |
| [20261127-002000-service-pentest-api-share-secrev](runs/20261127-002000-service-pentest-api-share-secrev/report.md) | service-pentest | completed | synced | checked |
| [20261127-003000-quality-maintainability-perf-memory-secrev](runs/20261127-003000-quality-maintainability-perf-memory-secrev/report.md) | quality-maintainability | completed | synced | checked |
| [20261127-004000-operations-cli-scripts-swift-secrev](runs/20261127-004000-operations-cli-scripts-swift-secrev/report.md) | operations | completed | synced | checked |
| [20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead](runs/20261127-033000-service-pentest-v060-s3-iam-cli-atlaslead/report.md) | service-pentest | completed | synced | checked |

<!-- END GENERATED -->
