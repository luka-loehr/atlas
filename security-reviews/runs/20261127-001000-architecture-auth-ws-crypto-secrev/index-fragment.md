# Index fragment: 20261127-001000-architecture-auth-ws-crypto-secrev

- Queue: `SECQ-20261127-001` (`done`)
- Findings:
- [SEC-20261127-001001-ARCH-001](../../findings/SEC-20261127-001001-ARCH-001.md) (high): WebSocket endpoints lack Origin validation and /v1/system/terminal inherits server secrets into the PTY shell
- [SEC-20261127-001000-TM-001](../../findings/SEC-20261127-001000-TM-001.md) (medium): Bearer token accepted in URL query string on every /v1 route including terminal, power and mutation endpoints
- [SEC-20261127-001002-CRYPTO-001](../../findings/SEC-20261127-001002-CRYPTO-001.md) (medium): decode_aws_chunked_bytes discards chunk signatures and has an integer overflow in slice bounds
- PASS statements:
- `PASS-20261127-001`: atlas-common AES-256-GCM sealing, HKDF-SHA256 derivation, SystemRandom nonces, AAD binding, and subtle::ConstantTimeEq
- `PASS-20261127-002`: system/host.rs safe_name() Docker validation, power() allowlist, and 8s kill_on_drop timeouts
