# Claim: <claim-id>

Claim id: `<YYYYMMDD-HHMMSS-track-scope-agent>`
Task: `SECQ-YYYYMMDD-NNN`
Run: `runs/<run-id>/`
Status: active | completed | blocked | abandoned | stale
Agent: <name or thread>
Model: <exact model id or unknown>
Session: <session id or description>
Track: architecture | threat-model | service-pentest | crypto-implementation | system-audit | quality-maintainability | operations | baseline | browser | reviewer-pack
Claim type: review | audit | finding-verify | pass-verify | fix-reverify | reviewer-pack
Scope: <scope>
Start: YYYY-MM-DDTHH:MM:SS+02:00
Next check or planned end: YYYY-MM-DDTHH:MM:SS+02:00
coordinator task: <t_... or ->

## Expected paths and targets

- `...`

## Planned checks

- <check>

## Verify of a finding or PASS statement

- Original run, agent, model, session:
- Verified ids:
- Verified by its author with evidence (owner rule 2026-10-31): yes | no
- Result: confirmed | refuted | blocked

## Re-verify of a fix

- Finding id:
- Fix commit and deploy:
- Finder and fixer (agent, model, session):
- Re-verifier is independent of finder and fixer: yes | no
- Result: fix confirmed | fix incomplete | blocked

## Overlapping claims

- <claim or ->

## Status history

- YYYY-MM-DDTHH:MM:SS+02:00 active: claim created.
