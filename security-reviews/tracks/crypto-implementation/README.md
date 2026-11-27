# Track: Cryptographic Implementation (`luka-loehr/atlas`)

Audits cryptographic primitives, key derivation, nonce management, constant-time comparisons, and secret sealing across:

- `crates/common/src/crypto.rs` (AEAD sealing/unsealing, key handling, nonce generation, error handling).
- `crates/server/src/auth.rs` (token/key generation, hashing, constant-time comparison, S3/IAM signature verification).
- `db/migrations/*` (including migration `0017` and credential/secret storage tables).
- `share/src/crypto.ts` (WebCrypto usage, password hashing/verification, signed URLs/tokens, constant-time comparisons).

## Key questions

1. Are AEAD ciphers, nonces, and associated data used safely with zero nonce reuse?
2. Are all token, secret, HMAC, and password comparisons constant-time?
3. Are cryptographic random generators (`OsRng`, `crypto.getRandomValues`) used for all keys, tokens, nonces, and share slugs?
4. Are plaintext secrets prevented from leaking into logs, error messages, or unsealed DB columns?
