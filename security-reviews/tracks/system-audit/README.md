# Track: System Audit (`luka-loehr/atlas`)

Performs whole-codebase system and host-boundary audits across Rust crates, systemd units, shell scripts, CLI, and Swift client code.

## Scope

- `crates/server`, `crates/core`, `crates/ml`, `crates/cli`, `crates/common`.
- `scripts/` (systemd units, `firewall.nft`, `disk-guard`, `pg-backup`, `alerts`, `power`, `proxy`, `install.sh`).
- `app/` (SwiftUI iOS/macOS app: `API.swift`, URL handling, Keychain/token handling).
- Public repository hygiene (no leaked secrets, private IPv4s, real emails, or private tailnet hostnames).

## Key questions

1. Are systemd units hardened (`NoNewPrivileges`, `ProtectSystem`, `PrivateTmp`, least-privilege users, 0600 env files)?
2. Are shell scripts safe against word splitting, quoting bugs, symlink races, and unsafe temporary file handling?
3. Does the CLI quote SSH/remote shell arguments safely and enforce restrictive permissions (0700/0600) on local config and secret files?
4. Does the Swift client validate URLs, enforce TLS/safe schemes, and avoid leaking credentials?
