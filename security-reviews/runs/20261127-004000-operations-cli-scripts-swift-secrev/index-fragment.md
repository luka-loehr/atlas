# Index fragment: 20261127-004000-operations-cli-scripts-swift-secrev

- Queue: `SECQ-20261127-004` (`done`)
- Findings:
- [SEC-20261127-004000-OPS-001](../../findings/SEC-20261127-004000-OPS-001.md) (medium): disk-guard.sh sources a mutable state file with fallback to world-writable /var/tmp
- [SEC-20261127-004001-OPS-001](../../findings/SEC-20261127-004001-OPS-001.md) (medium): Postgres backup dumps lack restrictive umask and atlas-server systemd/install lack permission and hardening guards
- [SEC-20261127-004002-SYS-001](../../findings/SEC-20261127-004002-SYS-001.md) (low): CLI ssh invocations omit -- host option separator and exec.rs interpolates remote paths unquoted
- [AUD-20261127-OPS-001](../../findings/AUD-20261127-OPS-001.md) (low): Swift API.swift force-unwraps URLComponents and Session.normalize does not restrict schemes to http/https
- PASS statements:
- `PASS-20261127-005`: firewall.nft confines TCP 8787 to lo and tailscale0, and public-repo hygiene scan found zero real secrets or private user data
