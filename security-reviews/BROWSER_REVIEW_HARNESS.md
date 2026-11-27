# Browser review harness

Status: binding. Applies to any browser-driven review of `luka-loehr/atlas` web surfaces (such as the Cloudflare Share Worker public album/file pages rendered locally).

## Purpose

Browser reviews check rendered HTML, CSP/XSS behavior, responsive layout and range/media playback against local ephemeral Share Worker or `127.0.0.1` instances with synthetic test assets. They must never touch live production share domains, the owner's browser profile, or real personal media.

## Tooling

- Headless Chromium against `http://127.0.0.1:<port>` only.
- Screenshots stored only after redaction review under `runs/<run-id>/evidence/artifacts/` with no secrets, private addresses, or real personal media visible.

## Procedure

1. Claim and run folder.
2. Check the freeze rule in `AUTHORIZATION.md`.
3. Start the local ephemeral target on `127.0.0.1` with synthetic fixtures.
4. Exercise target pages (public share view, password-protected share, malformed slugs, XSS-canary filenames) and record status codes, headers, console errors, and DOM observations.
5. Stop the local server and delete temporary fixtures.
6. Perform redaction review and register sync.

## Done criterion

The browser run is completed when the scoped pages ran against local synthetic fixtures, the local process and fixtures were cleaned up, and the redaction review is recorded.
