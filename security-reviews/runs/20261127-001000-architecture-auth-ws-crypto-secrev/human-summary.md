# Human summary: 20261127-001000-architecture-auth-ws-crypto-secrev

Reviewed auth middleware, query-token exposure, WebSocket endpoints (/v1/system/terminal, /v1/system/live), host power/container controls, atlas-common AEAD secret sealing and SigV4 helpers, and migration 0017. Found 1 high (WebSocket Origin validation & PTY secret env inheritance), 2 medium (global ?token= query auth, aws-chunked unchecked bounds & ignored chunk signatures), and confirmed 2 PASS statements.

## Key findings

- [SEC-20261127-001001-ARCH-001](../../findings/SEC-20261127-001001-ARCH-001.md) (high): WebSocket endpoints lack Origin validation and /v1/system/terminal inherits server secrets into the PTY shell
- [SEC-20261127-001000-TM-001](../../findings/SEC-20261127-001000-TM-001.md) (medium): Bearer token accepted in URL query string on every /v1 route including terminal, power and mutation endpoints
- [SEC-20261127-001002-CRYPTO-001](../../findings/SEC-20261127-001002-CRYPTO-001.md) (medium): decode_aws_chunked_bytes discards chunk signatures and has an integer overflow in slice bounds
