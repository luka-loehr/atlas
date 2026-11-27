"""Shared parsing and rendering for the security-reviews registers.

Standard library only (CI runs it with the runner's python3). The canonical
sources are the Markdown files under findings/, the hand-maintained
data/passes.json, data/timeline.json and QUEUE.md; data/findings.json, the
generated block of INDEX.md and both HTML pages are derived from them.
"""

from __future__ import annotations

import html
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

SEC_ID_RE = re.compile(r"SEC-(\d{8})-(\d{6})-(ARCH|TM|SVC|CRYPTO|SYS|OPS|PRIV)-(\d{3})")
AUD_ID_RE = re.compile(r"AUD-(\d{8})-(SYSTEM|QUALITY|OPS)-(\d{3})")
PASS_ID_RE = re.compile(r"PASS-(\d{8})-(\d{3})")
QUEUE_ID_RE = re.compile(r"SECQ-\d{8}-\d{3}")
RUN_ID_RE = re.compile(r"\d{8}-\d{6}-[a-z0-9]+(?:-[a-z0-9]+)*")

SEC_TRACK_CODES = {
    "ARCH": "architecture",
    "TM": "threat-model",
    "SVC": "service-pentest",
    "CRYPTO": "crypto-implementation",
    "SYS": "system-audit",
    "OPS": "operations",
    "PRIV": "privacy",
}
AUD_SCOPE_TRACKS = {
    "SYSTEM": {"system-audit"},
    "QUALITY": {"quality-maintainability"},
    "OPS": {"operations"},
}
TRACKS = [
    "architecture",
    "threat-model",
    "service-pentest",
    "crypto-implementation",
    "system-audit",
    "quality-maintainability",
    "operations",
    "privacy",
]
RUN_TRACKS = set(TRACKS) | {"baseline", "browser", "reviewer-pack"}

FINDING_STATUSES = [
    "open",
    "in_progress",
    "owner-decision",
    "fixed",
    "accepted",
    "rejected",
    "duplicate",
    "blocked",
]
SEVERITIES = ["critical", "high", "medium", "low", "info"]
VERIFY_STATUSES = {"pending", "confirmed", "refuted", "blocked"}
REVERIFY_STATUSES = {"not-applicable", "pending", "confirmed", "failed"}
CLOSED_STATUSES = {"fixed", "accepted", "rejected", "duplicate"}

FINDING_FIELDS = [
    "Status",
    "Severity",
    "Track",
    "Repository",
    "Origin run",
    "Source",
    "Found by",
    "Found model",
    "Found session",
    "Found on",
    "Repository state",
    "Needs host",
    "Fix",
    "Fixed by",
    "Deployed",
    "Verify status",
    "Verify by",
    "Verify model",
    "Verify session",
    "Re-verify status",
    "Re-verify by",
    "Re-verify model",
    "Re-verify session",
]

QUEUE_STATUSES = {"open", "claimed", "in_review", "done", "blocked", "superseded"}
QUEUE_TYPES = {
    "review",
    "audit",
    "finding-verify",
    "pass-verify",
    "fix-reverify",
    "fix",
    "infra",
    "reviewer-pack",
}

GENERATED_BEGIN = "<!-- BEGIN GENERATED: scripts/update_humans_read_this_first.py -->"
GENERATED_END = "<!-- END GENERATED -->"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def repo_config() -> dict[str, Any]:
    return load_json(ROOT / "data" / "repo.json")


def strip_ticks(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value.startswith("`") and value.endswith("`"):
        value = value[1:-1].strip()
    return value


def field(text: str, name: str) -> str | None:
    match = re.search(rf"^{re.escape(name)}:[ \t]*(.*?)[ \t]*$", text, re.MULTILINE)
    if not match:
        return None
    return strip_ticks(match.group(1))


def section(text: str, heading: str) -> str | None:
    match = re.search(
        rf"^## {re.escape(heading)}[ \t]*\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL
    )
    return match.group(1).strip() if match else None


def parse_finding(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    first = text.splitlines()[0] if text else ""
    title = first.split(":", 1)[1].strip() if ":" in first else ""
    record: dict[str, Any] = {
        "id": path.stem,
        "kind": "SEC" if path.stem.startswith("SEC-") else "AUD",
        "title": title,
        "heading": first,
        "path": f"findings/{path.name}",
    }
    for name in FINDING_FIELDS + ["Category", "Security relevance", "Queue"]:
        value = field(text, name)
        key = name.lower().replace(" ", "_").replace("-", "_")
        record[key] = value
    record["summary"] = (section(text, "Summary") or "").split("\n\n")[0].replace("\n", " ")
    record["owner_steps"] = section(text, "Owner decision steps")
    record["has_summary"] = section(text, "Summary") is not None
    record["has_history"] = section(text, "Status history") is not None
    record["has_verify_section"] = section(text, "How to verify") is not None
    return record


def finding_paths() -> list[Path]:
    return sorted(p for p in (ROOT / "findings").glob("*.md") if p.name != "README.md")


def load_findings() -> list[dict[str, Any]]:
    return [parse_finding(p) for p in finding_paths()]


def severity_rank(value: str | None) -> int:
    return SEVERITIES.index(value) if value in SEVERITIES else len(SEVERITIES)


def status_rank(value: str | None) -> int:
    return FINDING_STATUSES.index(value) if value in FINDING_STATUSES else len(FINDING_STATUSES)


def sort_key(record: dict[str, Any]) -> tuple[int, int, str]:
    return (status_rank(record.get("status")), severity_rank(record.get("severity")), record["id"])


def parse_table(text: str, heading: str) -> list[dict[str, str]]:
    body = section(text, heading)
    if body is None:
        return []
    lines = [line for line in body.splitlines() if line.strip().startswith("|")]
    if len(lines) < 2:
        return []
    header = [cell.strip() for cell in lines[0].strip().strip("|").split("|")]
    rows = []
    for line in lines[2:]:
        cells = [strip_ticks(cell.strip()) for cell in line.strip().strip("|").split("|")]
        if len(cells) != len(header):
            rows.append({"__malformed__": line})
            continue
        rows.append(dict(zip(header, cells)))
    return rows


def load_queue() -> list[dict[str, str]]:
    text = (ROOT / "QUEUE.md").read_text(encoding="utf-8")
    return parse_table(text, "Tasks")


def load_passes() -> list[dict[str, Any]]:
    return load_json(ROOT / "data" / "passes.json")["passes"]


def load_timeline() -> list[dict[str, Any]]:
    return load_json(ROOT / "data" / "timeline.json")["entries"]


def run_dirs() -> list[Path]:
    runs = ROOT / "runs"
    return sorted(p for p in runs.iterdir() if p.is_dir() and not p.name.startswith("."))


def parse_iso(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo is not None else None


# ---------------------------------------------------------------- rendering


def findings_data(findings: list[dict[str, Any]]) -> dict[str, Any]:
    keep = [
        "id", "kind", "title", "status", "severity", "track", "repository", "origin_run",
        "source", "found_by", "found_model", "found_on", "repository_state", "needs_host",
        "fix", "fixed_by", "deployed", "verify_status", "verify_by", "verify_model",
        "verify_session", "re_verify_status", "re_verify_by", "re_verify_model",
        "re_verify_session", "category", "security_relevance", "queue", "path", "summary",
    ]
    ordered = sorted(findings, key=sort_key)
    return {
        "repository": repo_config()["repository"],
        "findings": [{key: record.get(key) for key in keep} for record in ordered],
    }


def render_findings_json(findings: list[dict[str, Any]]) -> str:
    return json.dumps(findings_data(findings), indent=2, ensure_ascii=False) + "\n"


def counts(findings: list[dict[str, Any]], kind: str) -> dict[str, int]:
    result = {status: 0 for status in FINDING_STATUSES}
    for record in findings:
        if record["kind"] == kind and record.get("status") in result:
            result[record["status"]] += 1
    return result


def md_cell(value: Any) -> str:
    return str(value if value not in (None, "") else "-").replace("|", "\\|").replace("\n", " ")


def render_index_block(findings: list[dict[str, Any]], passes: list[dict[str, Any]]) -> str:
    lines = [GENERATED_BEGIN, "", "## Counts", ""]
    lines.append("| Kind | " + " | ".join(FINDING_STATUSES) + " |")
    lines.append("| --- |" + " --- |" * len(FINDING_STATUSES))
    for kind in ("SEC", "AUD"):
        c = counts(findings, kind)
        lines.append(f"| {kind} | " + " | ".join(str(c[s]) for s in FINDING_STATUSES) + " |")
    pending_verify = sum(1 for f in findings if f.get("verify_status") == "pending")
    pending_reverify = sum(1 for f in findings if f.get("re_verify_status") == "pending")
    open_passes = sum(1 for p in passes if p.get("verify_status") == "pending")
    lines += [
        "",
        f"Verify pending: {pending_verify} findings, {open_passes} PASS statements. "
        f"Re-verify pending: {pending_reverify} fixes.",
        "",
    ]
    for kind, heading in (("SEC", "Security findings (SEC)"), ("AUD", "Audit findings (AUD)")):
        lines += [f"## {heading}", ""]
        lines.append("| ID | Status | Severity | Track | Title | Fix | Verify | Re-verify | Needs host |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        rows = [f for f in sorted(findings, key=sort_key) if f["kind"] == kind]
        for f in rows:
            lines.append(
                f"| [{f['id']}]({f['path']}) | {md_cell(f.get('status'))} | {md_cell(f.get('severity'))} | "
                f"{md_cell(f.get('track'))} | {md_cell(f.get('title'))} | {md_cell(f.get('fix'))} | "
                f"{md_cell(f.get('verify_status'))} | {md_cell(f.get('re_verify_status'))} | "
                f"{md_cell(f.get('needs_host'))} |"
            )
        if not rows:
            lines.append("| - | - | - | - | No findings registered. An empty register is not a PASS. | - | - | - | - |")
        lines.append("")
    lines += ["## PASS statements (verified by their author with evidence)", ""]
    lines.append("| ID | Verify | Scope | Statement | Origin run |")
    lines.append("| --- | --- | --- | --- | --- |")
    for p in passes:
        lines.append(
            f"| {p['id']} | {md_cell(p.get('verify_status'))} | {md_cell(p.get('scope'))} | "
            f"{md_cell(p.get('statement'))} | `{md_cell(p.get('origin_run'))}` |"
        )
    if not passes:
        lines.append("| - | - | - | No PASS statements. | - |")
    lines += ["", "## Runs", ""]
    lines.append("| Run | Track | Status | Register | Redaction |")
    lines.append("| --- | --- | --- | --- | --- |")
    for run in run_dirs():
        try:
            meta = load_json(run / "metadata.json")
        except (OSError, json.JSONDecodeError):
            meta = {}
        lines.append(
            f"| [{run.name}](runs/{run.name}/report.md) | {md_cell(meta.get('track'))} | "
            f"{md_cell(meta.get('status'))} | {md_cell(meta.get('register_status'))} | "
            f"{md_cell(meta.get('redaction_status'))} |"
        )
    lines += ["", GENERATED_END]
    return "\n".join(lines)


def render_index(findings: list[dict[str, Any]], passes: list[dict[str, Any]]) -> str:
    current = (ROOT / "INDEX.md").read_text(encoding="utf-8")
    block = render_index_block(findings, passes)
    if GENERATED_BEGIN in current and GENERATED_END in current:
        head, rest = current.split(GENERATED_BEGIN, 1)
        _, tail = rest.split(GENERATED_END, 1)
        return head + block + tail
    return current.rstrip("\n") + "\n\n" + block + "\n"


STYLE = """
:root{--bg:#ffffff;--fg:#111111;--muted:#5c5c5c;--line:#d9d9d9;--panel:#f6f6f6;
--crit:#b00020;--high:#c2410c;--med:#a16207;--low:#1d4ed8;--ok:#166534;--brand:#1d4ed8}
@media (prefers-color-scheme: dark){:root{--bg:#0f0f0f;--fg:#ececec;--muted:#a3a3a3;
--line:#2e2e2e;--panel:#181818;--crit:#ff6b81;--high:#fb923c;--med:#facc15;--low:#93c5fd;
--ok:#86efac;--brand:#93c5fd}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,
"Segoe UI",sans-serif}
main{max-width:1180px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:1.6rem;margin:0 0 4px}h2{font-size:1.15rem;margin:32px 0 8px;
border-bottom:1px solid var(--line);padding-bottom:4px}
p.lead{color:var(--muted);margin:0 0 16px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px}
.card{border:1px solid var(--line);background:var(--panel);padding:10px;border-radius:4px}
.card b{display:block;font-size:1.4rem}
.wrap{overflow-x:auto;border:1px solid var(--line);border-radius:4px}
table{border-collapse:collapse;width:100%;min-width:720px}
th,td{text-align:left;vertical-align:top;padding:6px 8px;border-bottom:1px solid var(--line)}
th{background:var(--panel);font-weight:600;position:sticky;top:0}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace}
.sev-critical{color:var(--crit);font-weight:700}.sev-high{color:var(--high);font-weight:700}
.sev-medium{color:var(--med);font-weight:600}.sev-low{color:var(--low)}.sev-info{color:var(--muted)}
.pending{color:var(--high)}.confirmed{color:var(--ok)}.refuted{color:var(--muted)}
.note{border-left:3px solid var(--brand);padding:6px 10px;background:var(--panel)}
a{color:var(--brand)}
"""


def esc(value: Any) -> str:
    return html.escape(str(value if value not in (None, "") else "-"))


def page(title: str, lead: str, body: str) -> str:
    return (
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        f"<title>{esc(title)}</title>\n<style>{STYLE}</style>\n</head>\n<body>\n<main>\n"
        f"<h1>{esc(title)}</h1>\n<p class=\"lead\">{lead}</p>\n{body}\n</main>\n</body>\n</html>\n"
    )


def findings_table(rows: list[dict[str, Any]], audit: bool) -> str:
    head = ["ID", "Status", "Severity", "Track", "Title", "Fix", "Deployed", "Verify", "Re-verify", "Needs host"]
    out = ["<div class=\"wrap\"><table><thead><tr>"]
    out += [f"<th>{h}</th>" for h in head]
    out.append("</tr></thead><tbody>")
    for f in rows:
        verify = f.get("verify_status") or "-"
        reverify = f.get("re_verify_status") or "-"
        out.append(
            "<tr>"
            f"<td><a href=\"{esc(f['path'])}\"><code>{esc(f['id'])}</code></a></td>"
            f"<td>{esc(f.get('status'))}</td>"
            f"<td class=\"sev-{esc(f.get('severity'))}\">{esc(f.get('severity'))}</td>"
            f"<td>{esc(f.get('track'))}</td>"
            f"<td>{esc(f.get('title'))}<br><small>{esc(f.get('summary'))}</small></td>"
            f"<td>{esc(f.get('fix'))}</td><td>{esc(f.get('deployed'))}</td>"
            f"<td class=\"{esc(verify)}\">{esc(verify)}</td>"
            f"<td class=\"{esc(reverify)}\">{esc(reverify)}</td>"
            f"<td>{esc(f.get('needs_host'))}</td></tr>"
        )
    if not rows:
        out.append(
            f"<tr><td colspan=\"{len(head)}\">No findings registered. An empty register is not a PASS.</td></tr>"
        )
    out.append("</tbody></table></div>")
    return "".join(out)


def count_cards(findings: list[dict[str, Any]], kind: str) -> str:
    c = counts(findings, kind)
    cards = "".join(f"<div class=\"card\">{esc(s)}<b>{n}</b></div>" for s, n in c.items())
    return f"<div class=\"cards\">{cards}</div>"


def render_humans(findings: list[dict[str, Any]], passes: list[dict[str, Any]], timeline: list[dict[str, Any]]) -> str:
    cfg = repo_config()
    sec = sorted((f for f in findings if f["kind"] == "SEC"), key=sort_key)
    owner = [f for f in sec if f.get("status") == "owner-decision"]
    pending_verify = [f for f in findings if f.get("verify_status") == "pending"]
    pending_reverify = [f for f in findings if f.get("re_verify_status") == "pending"]
    body = []
    body.append(
        "<div class=\"note\">Generated from <code>findings/</code>, <code>data/passes.json</code> and "
        "<code>data/timeline.json</code> by <code>scripts/update_humans_read_this_first.py</code>; do not edit. "
        "The citable sources are <a href=\"INDEX.md\">INDEX.md</a>, the finding files, runs and fix logs. "
        "A <b>fixed</b> finding carries the builder's own verification with evidence; "
        "an empty register is not a PASS.</div>"
    )
    body.append("<h2>Security findings by status</h2>" + count_cards(findings, "SEC"))
    body.append(
        f"<p>Verify pending: <b>{len(pending_verify)}</b> findings and "
        f"<b>{sum(1 for p in passes if p.get('verify_status') == 'pending')}</b> PASS statements. "
        f"Re-verify pending: <b>{len(pending_reverify)}</b> fixes.</p>"
    )
    body.append("<h2>Owner decisions</h2>")
    if owner:
        items = "".join(
            f"<li><a href=\"{esc(f['path'])}\"><code>{esc(f['id'])}</code></a> {esc(f.get('title'))}</li>"
            for f in owner
        )
        body.append(f"<ul>{items}</ul><p>Exact steps are in each finding under \"Owner decision steps\".</p>")
    else:
        body.append("<p>None.</p>")
    body.append("<h2>Security findings (SEC)</h2>" + findings_table(sec, audit=False))
    body.append("<h2>PASS statements</h2>")
    rows = "".join(
        "<tr>"
        f"<td><code>{esc(p['id'])}</code></td>"
        f"<td class=\"{esc(p.get('verify_status'))}\">"
        f"{'Verify open (unverified PASS)' if p.get('verify_status') == 'pending' else esc(p.get('verify_status'))}</td>"
        f"<td>{esc(p.get('scope'))}</td><td>{esc(p.get('statement'))}</td>"
        f"<td><code>{esc(p.get('origin_run'))}</code></td></tr>"
        for p in passes
    ) or "<tr><td colspan=\"5\">No PASS statements.</td></tr>"
    body.append(
        "<div class=\"wrap\"><table><thead><tr><th>ID</th><th>Verify</th><th>Scope</th><th>Statement</th>"
        f"<th>Origin run</th></tr></thead><tbody>{rows}</tbody></table></div>"
    )
    body.append("<h2>Timeline</h2>")
    entries = sorted(timeline, key=lambda e: str(e.get("at")), reverse=True)
    items = "".join(f"<li><code>{esc(e.get('at'))}</code> {esc(e.get('text'))}</li>" for e in entries)
    body.append(f"<ul>{items}</ul>" if items else "<p>No entries.</p>")
    lead = (
        f"Security review state of <code>{esc(cfg['repository'])}</code>. Audit, quality and operations "
        "findings are in <a href=\"audits.html\">audits.html</a>."
    )
    return page(f"{cfg['repository']}: security reviews", lead, "\n".join(body))


def render_audits(findings: list[dict[str, Any]]) -> str:
    cfg = repo_config()
    aud = sorted((f for f in findings if f["kind"] == "AUD"), key=sort_key)
    body = [
        "<div class=\"note\">Generated from <code>findings/AUD-*.md</code> by "
        "<code>scripts/update_audits_html.py</code>; do not edit. A \"checked without finding\" audit note "
        "is not a security PASS.</div>",
        "<h2>Audit findings by status</h2>" + count_cards(findings, "AUD"),
        "<h2>Audit findings (AUD)</h2>" + findings_table(aud, audit=True),
    ]
    lead = (
        f"Audit, quality and operations findings of <code>{esc(cfg['repository'])}</code>. Security findings are "
        "in <a href=\"humans_read_this_first.html\">humans_read_this_first.html</a>."
    )
    return page(f"{cfg['repository']}: audits", lead, "\n".join(body))
