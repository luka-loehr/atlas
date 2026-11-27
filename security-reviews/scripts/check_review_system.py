#!/usr/bin/env python3
"""Validate the security-reviews registers. Runs in CI on every push.

Checks required files and tracks, finding schema and verify/re-verify
fields (the builder verifies its own work; no independent verify),
INDEX/QUEUE/PASS consistency, runs, claims and fix logs, Markdown links,
generated pages being current, the authorization invariants and a redaction
scan. Starts no active test and touches no network.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

import review_lib as lib
import update_audits_html
import update_humans_read_this_first

ROOT = lib.ROOT

REQUIRED_FILES = [
    "README.md",
    "AGENTS.md",
    "AUTHORIZATION.md",
    "BROWSER_REVIEW_HARNESS.md",
    "SERVICE_REVIEW_HARNESS.md",
    "FIX_AGENT_GUIDE.md",
    "INDEX.md",
    "QUEUE.md",
    "humans_read_this_first.html",
    "audits.html",
    "claims/README.md",
    "runs/README.md",
    "findings/README.md",
    "fix-logs/README.md",
    "reviewer-packs/README.md",
    "data/repo.json",
    "data/findings.json",
    "data/passes.json",
    "data/timeline.json",
    "scripts/review_lib.py",
    "scripts/check_review_system.py",
    "scripts/update_humans_read_this_first.py",
    "scripts/update_audits_html.py",
]
REQUIRED_TEMPLATES = [
    "CLAIM_TEMPLATE.md",
    "METADATA_TEMPLATE.json",
    "REVIEW_REPORT_TEMPLATE.md",
    "AUDIT_REPORT_TEMPLATE.md",
    "FINDING_TEMPLATE.md",
    "AUDIT_FINDING_TEMPLATE.md",
    "TRAIL_TEMPLATE.md",
    "HUMAN_SUMMARY_TEMPLATE.md",
    "EVIDENCE_LOG_TEMPLATE.md",
    "INDEX_FRAGMENT_TEMPLATE.md",
    "FIX_LOG_TEMPLATE.md",
    "BROWSER_RUN_TEMPLATE.md",
    "REVIEWER_PACK_README_TEMPLATE.md",
]
RUN_REQUIRED_FILES = [
    "metadata.json",
    "report.md",
    "trail.md",
    "human-summary.md",
    "index-fragment.md",
    "evidence/commands.md",
    "evidence/evidence-index.md",
]
RUN_METADATA_KEYS = {
    "run_id", "track", "scope", "targets", "agent", "model", "session", "tooling", "status",
    "started_at", "ended_at", "repo_state", "environment", "authorization_ref", "host_lock",
    "test_data", "cleanup", "external_services", "register_status", "redaction_status",
}
RUN_STATUSES = {"in_review", "completed", "blocked", "aborted", "register_sync_open"}
REGISTER_STATUSES = {"pending", "synced", "blocked"}
REDACTION_STATUSES = {"pending", "checked", "blocked"}
CLEANUP_STATUSES = {"not_applicable", "pending", "checked", "intentionally_retained", "blocked"}
CLAIM_STATUSES = {"active", "completed", "blocked", "abandoned", "stale"}
FIX_LOG_STATUSES = {"in_progress", "fixed_in_worktree", "fixed", "blocked", "aborted"}
CLAIM_FILE_RE = re.compile(r"\d{8}-\d{6}-[a-z0-9]+(?:-[a-z0-9]+)*\.md")
FIX_LOG_FILE_RE = re.compile(r"\d{8}-\d{6}-[a-z0-9]+(?:-[a-z0-9]+)*\.md")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

# Redaction scan: values that must never land in the registers.
SECRET_PATTERNS = [
    (re.compile(r"\bATLK[0-9A-Z]{16,}\b"), "Atlas access key"),
    (re.compile(r"\batls_[A-Za-z0-9_-]{16,}\b"), "Atlas secret key"),
    (re.compile(r"\b(?:ksta|kstd|kstb|kstr|ksts|kwk|kst|cli|ses)_[A-Za-z0-9_-]{16,}"), "Kiste token value"),
    (re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"), "Stripe secret key"),
    (re.compile(r"\bwhsec_[A-Za-z0-9]{10,}"), "Stripe webhook secret"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "GitHub token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "JWT"),
    (re.compile(r"postgres(?:ql)?://[^\s:/]+:[^\s@<]+@"), "database URL with password"),
]
PRIVATE_IPV4 = re.compile(
    r"(?<![\d.])(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))"
    r"\.\d{1,3}\.\d{1,3}(?![\d/])"
)
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
ALLOWED_EMAIL_DOMAINS = ("example.com", "example.org", "example.net", "users.noreply.github.com")
SCANNED_SUFFIXES = {".md", ".json", ".html", ".txt", ".yml", ".yaml"}


class StrictParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.external: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        for attr in ("src", "srcset", "data"):
            value = values.get(attr) or ""
            if value and not value.startswith(("#", "data:")):
                self.external.append(f"<{tag} {attr}={value}>")
        if tag == "link" and (values.get("href") or "").startswith(("http:", "https:", "//")):
            self.external.append(f"<link href={values.get('href')}>")


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def check_required(errors: list[str]) -> None:
    for relative in REQUIRED_FILES:
        if not (ROOT / relative).is_file():
            errors.append(f"required file missing: {relative}")
    for name in REQUIRED_TEMPLATES:
        if not (ROOT / "templates" / name).is_file():
            errors.append(f"required template missing: templates/{name}")
    tracks = {p.parent.name for p in (ROOT / "tracks").glob("*/README.md")}
    if tracks != set(lib.TRACKS):
        errors.append(f"tracks differ: expected {sorted(lib.TRACKS)}, found {sorted(tracks)}")
    for path in ROOT.rglob("*"):
        if path.is_symlink():
            errors.append(f"symlinks are not allowed: {rel(path)}")


def check_json(errors: list[str]) -> None:
    for path in sorted(ROOT.rglob("*.json")):
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            errors.append(f"invalid JSON: {rel(path)}: {exc}")


def blank(value: str | None) -> bool:
    return value is None or value.strip() in ("", "-")


def check_findings(errors: list[str]) -> list[dict]:
    cfg = lib.repo_config()
    findings = []
    for path in lib.finding_paths():
        name = path.name
        sec = lib.SEC_ID_RE.fullmatch(path.stem)
        aud = lib.AUD_ID_RE.fullmatch(path.stem)
        if not sec and not aud:
            errors.append(f"invalid finding file name: {name}")
            continue
        record = lib.parse_finding(path)
        findings.append(record)
        if not record["heading"].startswith(f"# {path.stem}: ") or not record["title"]:
            errors.append(f"{name}: first line must be '# {path.stem}: <title>'")
        for key in lib.FINDING_FIELDS:
            attr = key.lower().replace(" ", "_").replace("-", "_")
            if record.get(attr) is None:
                errors.append(f"{name}: field missing: {key}")
        status = record.get("status")
        if status not in lib.FINDING_STATUSES:
            errors.append(f"{name}: invalid status {status!r}")
        if record.get("severity") not in lib.SEVERITIES:
            errors.append(f"{name}: invalid severity {record.get('severity')!r}")
        track = record.get("track")
        if sec and track != lib.SEC_TRACK_CODES[sec.group(3)]:
            errors.append(f"{name}: track {track!r} does not match code {sec.group(3)}")
        if aud and track not in lib.AUD_SCOPE_TRACKS[aud.group(2)]:
            errors.append(f"{name}: track {track!r} does not match scope {aud.group(2)}")
        if aud:
            for key in ("Category", "Security relevance"):
                if blank(record.get(key.lower().replace(" ", "_"))):
                    errors.append(f"{name}: field missing: {key}")
        if record.get("repository") != cfg["repository"]:
            errors.append(f"{name}: Repository must be {cfg['repository']}")
        origin = record.get("origin_run") or ""
        run_id = origin.removeprefix("runs/").strip("/")
        if not origin.startswith("runs/") or not (ROOT / "runs" / run_id).is_dir():
            errors.append(f"{name}: origin run missing: {origin!r}")
        for key in ("found_by", "found_model", "found_session", "found_on", "repository_state", "source"):
            if blank(record.get(key)):
                errors.append(f"{name}: attribution field empty: {key}")
        if record.get("needs_host") not in ("yes", "no"):
            errors.append(f"{name}: Needs host must be yes or no")
        for section_name, flag in (("Summary", "has_summary"), ("How to verify", "has_verify_section"), ("Status history", "has_history")):
            if not record.get(flag):
                errors.append(f"{name}: section missing: ## {section_name}")
        verify = record.get("verify_status")
        reverify = record.get("re_verify_status")
        if verify not in lib.VERIFY_STATUSES:
            errors.append(f"{name}: invalid Verify status {verify!r}")
        if reverify not in lib.REVERIFY_STATUSES:
            errors.append(f"{name}: invalid Re-verify status {reverify!r}")
        if verify in ("confirmed", "refuted"):
            for key in ("verify_by", "verify_model", "verify_session"):
                if blank(record.get(key)):
                    errors.append(f"{name}: Verify {verify} needs {key}")
        if status == "fixed":
            if blank(record.get("fix")):
                errors.append(f"{name}: fixed needs Fix (commit or change reference)")
            if blank(record.get("fixed_by")):
                errors.append(f"{name}: fixed needs Fixed by")
            deployed = (record.get("deployed") or "").split(" ")[0]
            if deployed not in ("yes", "n/a"):
                errors.append(f"{name}: fixed needs Deployed yes or n/a (otherwise in_progress)")
            # The builder verifies its own fix (owner 2026-10-31); no independent re-verify.
            if reverify != "confirmed":
                errors.append(f"{name}: fixed needs Re-verify confirmed (the builder's own verification, evidence in the status history)")
        if status == "in_progress" and blank(record.get("fix")):
            errors.append(f"{name}: in_progress needs Fix (branch, PR or commit)")
        if reverify in ("confirmed", "failed"):
            for key in ("re_verify_by", "re_verify_model", "re_verify_session"):
                if blank(record.get(key)):
                    errors.append(f"{name}: Re-verify {reverify} needs {key}")
        if status == "owner-decision":
            steps = record.get("owner_steps") or ""
            if not re.search(r"^\s*1\.\s+\S", steps, re.MULTILINE):
                errors.append(f"{name}: owner-decision needs '## Owner decision steps' with numbered steps")
        if status in ("open", "in_progress", "owner-decision", "blocked") and reverify == "confirmed":
            errors.append(f"{name}: re-verify confirmed but status is {status}")
    return findings


def check_index(errors: list[str], findings: list[dict]) -> None:
    text = (ROOT / "INDEX.md").read_text(encoding="utf-8")
    if lib.GENERATED_BEGIN not in text or lib.GENERATED_END not in text:
        errors.append("INDEX.md: generated block markers missing")
    ids_in_index = set(re.findall(r"(?:SEC|AUD)-\d{8}-[A-Z0-9-]+-\d{3}", text))
    ids_on_disk = {f["id"] for f in findings}
    if ids_in_index != ids_on_disk:
        errors.append(
            f"INDEX.md and findings/ differ: only in index {sorted(ids_in_index - ids_on_disk)}, "
            f"only on disk {sorted(ids_on_disk - ids_in_index)}"
        )


def check_queue(errors: list[str], queue: list[dict[str, str]]) -> None:
    seen = set()
    required = {"Task", "Status", "Type", "Track", "Scope", "Priority", "Findings", "Claim", "Note"}
    if not queue:
        errors.append("QUEUE.md: table under '## Tasks' missing or empty")
    for row in queue:
        if "__malformed__" in row:
            errors.append(f"QUEUE.md: malformed row: {row['__malformed__'][:80]}")
            continue
        missing = required - set(row)
        if missing:
            errors.append(f"QUEUE.md: columns missing: {sorted(missing)}")
            return
        task = row["Task"]
        if not lib.QUEUE_ID_RE.fullmatch(task):
            errors.append(f"QUEUE.md: invalid task id {task!r}")
        if task in seen:
            errors.append(f"QUEUE.md: duplicate task id {task}")
        seen.add(task)
        if row["Status"] not in QUEUE_STATUSES:
            errors.append(f"QUEUE.md: {task}: invalid status {row['Status']!r}")
        if row["Type"] not in lib.QUEUE_TYPES:
            errors.append(f"QUEUE.md: {task}: invalid type {row['Type']!r}")
        if row["Track"] not in lib.RUN_TRACKS and row["Track"] != "-":
            errors.append(f"QUEUE.md: {task}: invalid track {row['Track']!r}")
        for ref in re.findall(r"(?:SEC|AUD)-\d{8}-[A-Z0-9-]+-\d{3}", row["Findings"]):
            if not (ROOT / "findings" / f"{ref}.md").is_file():
                errors.append(f"QUEUE.md: {task}: unknown finding {ref}")
        for ref in re.findall(r"PASS-\d{8}-\d{3}", row["Findings"]):
            if ref not in {p["id"] for p in lib.load_passes()}:
                errors.append(f"QUEUE.md: {task}: unknown PASS statement {ref}")
        claim = row["Claim"]
        if claim not in ("-", "") and not (ROOT / "claims" / f"{claim}.md").is_file():
            errors.append(f"QUEUE.md: {task}: claim file missing: claims/{claim}.md")


QUEUE_STATUSES = lib.QUEUE_STATUSES


def check_passes(errors: list[str]) -> None:
    seen = set()
    for item in lib.load_passes():
        pid = item.get("id", "")
        if not lib.PASS_ID_RE.fullmatch(pid) or pid in seen:
            errors.append(f"data/passes.json: invalid or duplicate id {pid!r}")
        seen.add(pid)
        for key in ("statement", "scope", "origin_run", "found_by", "found_model", "verify_status"):
            if blank(item.get(key)):
                errors.append(f"data/passes.json: {pid}: {key} empty")
        if item.get("verify_status") not in lib.VERIFY_STATUSES:
            errors.append(f"data/passes.json: {pid}: invalid verify_status")
        run = str(item.get("origin_run", "")).removeprefix("runs/").strip("/")
        if not (ROOT / "runs" / run).is_dir():
            errors.append(f"data/passes.json: {pid}: origin run missing: {run}")
        if item.get("verify_status") in ("confirmed", "refuted"):
            for key in ("verify_by", "verify_model", "verify_session"):
                if blank(item.get(key)):
                    errors.append(f"data/passes.json: {pid}: {key} required once verified")


def check_timeline(errors: list[str]) -> None:
    for entry in lib.load_timeline():
        if lib.parse_iso(entry.get("at")) is None:
            errors.append(f"data/timeline.json: timestamp needs ISO-8601 with zone: {entry.get('at')!r}")
        if blank(entry.get("text")):
            errors.append("data/timeline.json: entry without text")


def check_runs(errors: list[str]) -> None:
    anchors = markdown_anchors(ROOT / "AUTHORIZATION.md")
    index_text = (ROOT / "INDEX.md").read_text(encoding="utf-8")
    for run in lib.run_dirs():
        if not lib.RUN_ID_RE.fullmatch(run.name):
            errors.append(f"invalid run id: {run.name}")
        for relative in RUN_REQUIRED_FILES:
            if not (run / relative).is_file():
                errors.append(f"run file missing: runs/{run.name}/{relative}")
        if run.name not in index_text:
            errors.append(f"run not in INDEX.md: {run.name}")
        try:
            meta = lib.load_json(run / "metadata.json")
        except (OSError, json.JSONDecodeError):
            continue
        missing = sorted(RUN_METADATA_KEYS - set(meta))
        if missing:
            errors.append(f"runs/{run.name}/metadata.json: keys missing: {missing}")
        if meta.get("run_id") != run.name:
            errors.append(f"runs/{run.name}/metadata.json: run_id mismatch")
        if meta.get("track") not in lib.RUN_TRACKS:
            errors.append(f"runs/{run.name}: invalid track {meta.get('track')!r}")
        status = meta.get("status")
        if status not in RUN_STATUSES:
            errors.append(f"runs/{run.name}: invalid status {status!r}")
        if meta.get("register_status") not in REGISTER_STATUSES:
            errors.append(f"runs/{run.name}: invalid register_status")
        if meta.get("redaction_status") not in REDACTION_STATUSES:
            errors.append(f"runs/{run.name}: invalid redaction_status")
        if meta.get("cleanup") not in CLEANUP_STATUSES:
            errors.append(f"runs/{run.name}: invalid cleanup {meta.get('cleanup')!r}")
        for key in ("agent", "model", "session", "tooling", "repo_state", "environment", "scope"):
            if blank(str(meta.get(key) or "")):
                errors.append(f"runs/{run.name}: {key} empty (write 'unknown' rather than guess)")
        started = lib.parse_iso(meta.get("started_at"))
        if started is None:
            errors.append(f"runs/{run.name}: started_at needs ISO-8601 with zone")
        ended = meta.get("ended_at")
        if ended is not None and lib.parse_iso(ended) is None:
            errors.append(f"runs/{run.name}: ended_at needs ISO-8601 with zone")
        if started and ended and lib.parse_iso(ended) and lib.parse_iso(ended) < started:
            errors.append(f"runs/{run.name}: ends before it starts")
        if status == "completed":
            if not ended:
                errors.append(f"runs/{run.name}: completed run needs ended_at")
            if meta.get("register_status") != "synced":
                errors.append(f"runs/{run.name}: completed run must be synced with the register")
            if meta.get("redaction_status") != "checked":
                errors.append(f"runs/{run.name}: completed run needs redaction_status checked")
            if meta.get("cleanup") in ("pending", "blocked"):
                errors.append(f"runs/{run.name}: completed run needs its cleanup documented")
        ref = str(meta.get("authorization_ref") or "")
        if ref.split("#", 1)[0] != "security-reviews/AUTHORIZATION.md":
            errors.append(f"runs/{run.name}: authorization_ref must point to security-reviews/AUTHORIZATION.md")
        elif "#" in ref and ref.split("#", 1)[1] not in anchors:
            errors.append(f"runs/{run.name}: authorization anchor missing: {ref}")


def check_claims(errors: list[str]) -> None:
    for path in sorted((ROOT / "claims").glob("*.md")):
        if path.name == "README.md":
            continue
        if not CLAIM_FILE_RE.fullmatch(path.name):
            errors.append(f"invalid claim file name: {path.name}")
        text = path.read_text(encoding="utf-8")
        status = lib.field(text, "Status")
        if status not in CLAIM_STATUSES:
            errors.append(f"claims/{path.name}: invalid status {status!r}")
        for key in ("Agent", "Model", "Session", "Track", "Claim type", "Start", "Run"):
            if blank(lib.field(text, key)):
                errors.append(f"claims/{path.name}: field missing: {key}")
        run = (lib.field(text, "Run") or "").removeprefix("runs/").strip("/")
        if run and not (ROOT / "runs" / run).is_dir():
            errors.append(f"claims/{path.name}: run folder missing: {run}")


def check_fix_logs(errors: list[str]) -> None:
    for path in sorted((ROOT / "fix-logs").glob("*.md")):
        if path.name == "README.md":
            continue
        if not FIX_LOG_FILE_RE.fullmatch(path.name):
            errors.append(f"invalid fix-log file name: {path.name}")
        text = path.read_text(encoding="utf-8")
        status = lib.field(text, "Status")
        if status not in FIX_LOG_STATUSES:
            errors.append(f"fix-logs/{path.name}: invalid status {status!r}")
        for key in ("Agent", "Model", "Session", "Start"):
            if blank(lib.field(text, key)):
                errors.append(f"fix-logs/{path.name}: field missing: {key}")
        refs = re.findall(r"(?:SEC|AUD)-\d{8}-[A-Z0-9-]+-\d{3}", lib.field(text, "Findings") or "")
        if not refs:
            errors.append(f"fix-logs/{path.name}: Findings must list at least one finding id")
        for ref in refs:
            if not (ROOT / "findings" / f"{ref}.md").is_file():
                errors.append(f"fix-logs/{path.name}: unknown finding {ref}")


def markdown_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    seen: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if not match:
            continue
        heading = re.sub(r"[`*_~]", "", match.group(1)).lower()
        base = re.sub(r"[^\w\s-]", "", heading)
        base = re.sub(r"\s", "-", base.strip())
        count = seen.get(base, 0)
        seen[base] = count + 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def check_links(errors: list[str]) -> None:
    for path in sorted(ROOT.rglob("*.md")):
        if "templates" in path.relative_to(ROOT).parts:
            continue
        text = path.read_text(encoding="utf-8")
        text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        for target in LINK_RE.findall(text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            target_path, _, anchor = target.partition("#")
            resolved = (path.parent / target_path).resolve()
            if resolved != ROOT and ROOT not in resolved.parents:
                # Links into the repository itself (product code, docs) are allowed.
                if not resolved.exists():
                    errors.append(f"{rel(path)}: link target missing: {target}")
                continue
            if not resolved.exists():
                errors.append(f"{rel(path)}: link target missing: {target}")
            elif anchor and resolved.suffix == ".md" and anchor not in markdown_anchors(resolved):
                errors.append(f"{rel(path)}: anchor missing: {target}")


def check_html(errors: list[str]) -> None:
    for relative in ("humans_read_this_first.html", "audits.html"):
        path = ROOT / relative
        if not path.is_file():
            continue
        parser = StrictParser()
        try:
            parser.feed(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            errors.append(f"{relative}: HTML not parseable: {exc}")
            continue
        if parser.external:
            errors.append(f"{relative}: external assets are not allowed: {parser.external[:3]}")


def check_generated(errors: list[str]) -> None:
    for relative, content in update_humans_read_this_first.outputs().items():
        path = ROOT / relative
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            errors.append(f"{relative} is out of date: run python3 security-reviews/scripts/update_humans_read_this_first.py")
    audits = update_audits_html.lib.render_audits(lib.load_findings())
    if (ROOT / "audits.html").read_text(encoding="utf-8") != audits:
        errors.append("audits.html is out of date: run python3 security-reviews/scripts/update_audits_html.py")


def check_authorization(errors: list[str]) -> None:
    # data/repo.json lists the phrases AUTHORIZATION.md must keep (fixed boundaries).
    cfg = lib.repo_config()
    text = (ROOT / "AUTHORIZATION.md").read_text(encoding="utf-8").lower()
    invariants = cfg.get("authorization_invariants") or []
    if not invariants:
        errors.append("data/repo.json: authorization_invariants missing")
    for phrase in invariants:
        if phrase.lower() not in text:
            errors.append(f"AUTHORIZATION.md lost a fixed boundary: {phrase!r}")


def check_redaction(errors: list[str]) -> None:
    cfg = lib.repo_config()
    # Public repositories list extra forbidden patterns in data/repo.json, so the
    # script itself names no internal detail.
    # Internal words are listed only as SHA-256 hashes of lower-case tokens.
    forbidden = [(re.compile(item["pattern"], re.I), item["label"]) for item in cfg.get("forbidden_patterns", [])]
    hashed = set(cfg.get("forbidden_token_sha256", []))
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or path.suffix not in SCANNED_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            where = f"{rel(path)}:{number}"
            for pattern, label in SECRET_PATTERNS:
                if pattern.search(line):
                    errors.append(f"redaction: {label} in {where}")
            if PRIVATE_IPV4.search(line):
                errors.append(f"redaction: private IPv4 address in {where} (write a placeholder or a CIDR range)")
            for email in EMAIL.findall(line):
                if not email.lower().endswith(ALLOWED_EMAIL_DOMAINS):
                    errors.append(f"redaction: e-mail address in {where} (write <owner-email> or <test-account>)")
            if hashed:
                for token in re.findall(r"[a-z0-9][a-z0-9-]*[a-z0-9]", line.lower()):
                    candidates = {token, *token.split("-")}
                    if any(hashlib.sha256(c.encode()).hexdigest() in hashed for c in candidates):
                        errors.append(f"public repository: internal name in {where}")
                        break
            if forbidden and path != ROOT / "data" / "repo.json":
                for pattern, label in forbidden:
                    if pattern.search(line):
                        errors.append(f"public repository: {label} in {where}")


def main() -> int:
    errors: list[str] = []
    check_required(errors)
    if errors:
        print("\n".join(errors))
        return 1
    check_json(errors)
    queue = lib.load_queue()
    findings = check_findings(errors)
    check_index(errors, findings)
    check_queue(errors, queue)
    check_passes(errors)
    check_timeline(errors)
    check_runs(errors)
    check_claims(errors)
    check_fix_logs(errors)
    check_links(errors)
    check_html(errors)
    check_generated(errors)
    check_authorization(errors)
    check_redaction(errors)
    if errors:
        print(f"security-reviews check failed with {len(errors)} problem(s):")
        print("\n".join(f"- {e}" for e in errors))
        return 1
    sec = sum(1 for f in findings if f["kind"] == "SEC")
    aud = len(findings) - sec
    print(f"security-reviews ok: {sec} SEC, {aud} AUD findings, {len(lib.load_passes())} PASS statements, "
          f"{len(queue)} queue tasks, {len(lib.run_dirs())} runs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
