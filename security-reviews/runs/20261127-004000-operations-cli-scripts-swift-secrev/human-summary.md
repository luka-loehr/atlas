# Human summary: 20261127-004000-operations-cli-scripts-swift-secrev

Audited CLI SSH/shell quoting, config handling, systemd units and operational scripts (firewall.nft, disk-guard, pg-backup, install.sh), Swift client URL handling, and public-repo secret/IP hygiene. Found 2 medium (disk-guard.sh sourcing mutable state in /var/tmp fallback; pg-backup umask and atlas-server systemd/env hardening), 2 low (CLI ssh -- guard & exec.rs quoting; Swift URL scheme & force-unwrap), and confirmed 1 PASS statement.

## Key findings

- [SEC-20261127-004000-OPS-001](../../findings/SEC-20261127-004000-OPS-001.md) (medium): disk-guard.sh sources a mutable state file with fallback to world-writable /var/tmp
- [SEC-20261127-004001-OPS-001](../../findings/SEC-20261127-004001-OPS-001.md) (medium): Postgres backup dumps lack restrictive umask and atlas-server systemd/install lack permission and hardening guards
- [SEC-20261127-004002-SYS-001](../../findings/SEC-20261127-004002-SYS-001.md) (low): CLI ssh invocations omit -- host option separator and exec.rs interpolates remote paths unquoted
- [AUD-20261127-OPS-001](../../findings/AUD-20261127-OPS-001.md) (low): Swift API.swift force-unwraps URLComponents and Session.normalize does not restrict schemes to http/https
