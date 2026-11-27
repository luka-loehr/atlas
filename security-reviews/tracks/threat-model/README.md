# Track: Threat Model (`luka-loehr/atlas`)

Models realistic adversaries, entry points, and abuse paths across `luka-loehr/atlas`:

- **Network / browser attacker**: Cross-site WebSocket hijacking (CSWSH), CSRF, XSS in Share Worker HTML, referrer/log leakage of query-string tokens.
- **Unauthenticated internet / LAN caller**: Unauthenticated endpoints, public Share Worker routes, range-request abuse, DoS via unbounded inputs.
- **Compromised client / scoped key**: Escalation from read/write/scoped keys to admin, path traversal in Drive/Photos, cross-user or cross-share access.
- **Malicious media / document**: Crafted PDF, HEIF, JPEG, video, or archive triggering memory exhaustion, subprocess argument injection, or symlink escapes during preview/thumbnail/OCR processing.
- **Local / operational compromise**: CLI SSH argument injection, world-readable config or backup files, overly permissive firewall rules or systemd unit privileges.

## Key questions

1. Which endpoints accept authentication via query parameters or lack Origin validation on WebSocket upgrades?
2. Which endpoints allow unbounded request arrays, large in-memory buffers, or expensive synchronous work?
3. Can untrusted filenames, share slugs, or metadata escape path confinement, SQL bindings, HTML templates, or shell/subprocess invocations?
