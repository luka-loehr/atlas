# Review report: 20261127-001000-architecture-auth-ws-crypto-secrev

- Track: `architecture`
- Scope: `auth-ws-crypto`
- Queue: `SECQ-20261127-001`
- Agent / Model: `secrev` / `Gemini 4 Neon`
- Session: `secrev@2026-11-27 (security-review session ca10409f)`
- Repository state: `d068e6d`
- Authorization: [`AUTHORIZATION.md`](../../AUTHORIZATION.md#authorized-active-targets)

## Summary

Reviewed auth middleware, query-token exposure, WebSocket endpoints (/v1/system/terminal, /v1/system/live), host power/container controls, atlas-common AEAD secret sealing and SigV4 helpers, and migration 0017. Found 1 high (WebSocket Origin validation & PTY secret env inheritance), 2 medium (global ?token= query auth, aws-chunked unchecked bounds & ignored chunk signatures), and confirmed 2 PASS statements.

## Findings

- [SEC-20261127-001001-ARCH-001](../../findings/SEC-20261127-001001-ARCH-001.md) (high): WebSocket endpoints lack Origin validation and /v1/system/terminal inherits server secrets into the PTY shell
- [SEC-20261127-001000-TM-001](../../findings/SEC-20261127-001000-TM-001.md) (medium): Bearer token accepted in URL query string on every /v1 route including terminal, power and mutation endpoints
- [SEC-20261127-001002-CRYPTO-001](../../findings/SEC-20261127-001002-CRYPTO-001.md) (medium): decode_aws_chunked_bytes discards chunk signatures and has an integer overflow in slice bounds

## PASS statements

- `PASS-20261127-001`: atlas-common AES-256-GCM sealing, HKDF-SHA256 derivation, SystemRandom nonces, AAD binding, and subtle::ConstantTimeEq
- `PASS-20261127-002`: system/host.rs safe_name() Docker validation, power() allowlist, and 8s kill_on_drop timeouts

## Redaction and cleanup

- Redaction: checked; no raw secrets, private IPv4 addresses, real tailnet hostnames, or personal emails recorded.
- Cleanup: not applicable (read-only static analysis and local unit tests only).
