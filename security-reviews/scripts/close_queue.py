#!/usr/bin/env python3
"""Close finished verify rows in QUEUE.md.

A row is closed only when the result it waits for is recorded and nothing it
depends on is still outstanding:

- its Status is open, claimed or in_review (never blocked, done or superseded);
- its Notes name no unmet dependency (a PR, a train, a deploy, "until",
  "once", "after", "blocked", "waits", "not yet live"); such rows need a person;
- finding-verify: every listed finding has Verify status confirmed or refuted;
- pass-verify: every listed pass has verify_status confirmed or refuted;
- fix-reverify: every listed finding has Re-verify status confirmed, and in its
  Status history the latest re-verify entry comes after the latest entry that
  records a fix (a fix commit, in_progress, fixed, addressed, residual) or a
  failed re-verify.

Dry run by default; --apply rewrites QUEUE.md. Standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import review_lib as lib  # noqa: E402

CLOSABLE_STATUSES = {"open", "claimed", "in_review"}
CLOSABLE_TYPES = {"finding-verify", "fix-reverify", "pass-verify"}
ITEM_RE = re.compile(r"(?:SEC|AUD|PASS)-[A-Z0-9-]+")
DEPENDENCY_RE = re.compile(
    r"\bPR\s*#?\d+|#\d+|\btrains?\b|\bdeploy(?:s|ed|ment)?\b|\buntil\b|\bonce\b"
    r"|\bafter\b|\bblocked\b|\bwaits?\b|\bwaiting\b|\bnot yet live\b|\bpending\b",
    re.IGNORECASE,
)
# A history entry that records a re-verify result: it starts with the re-verify
# ("- 2026-10-06 re-verify ...", "- 2026-10-06 verify and re-verify ...") or says
# "re-verify confirmed". A failed re-verify counts like a fix: it needs a new one.
REVERIFY_ENTRY_RE = re.compile(
    r"^- [\d-]+:? (?:verify and )?re-verify\b|\bre-verify confirmed\b", re.IGNORECASE
)
NOT_REVERIFY_RE = re.compile(r"not a re-verify|recorded as pending|\bqueued\b", re.IGNORECASE)
REVERIFY_CONFIRMED_RE = re.compile(r"(?i:re-verify confirmed)|\bCONFIRMED\b")
REVERIFY_FAILED_RE = re.compile(r"(?i:re-verify failed)|\bFAILED\b")
FIX_RE = re.compile(
    r"\bfixed\b|\bin_progress\b|\baddressed\b|\bresidual\b|\bfix(?:ed)? (?:on main )?in [0-9a-f]{7,}",
    re.IGNORECASE,
)
SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")


def history_lines(text: str) -> list[str]:
    body = lib.section(text, "Status history") or ""
    return [line for line in body.splitlines() if line.startswith("- ")]


def reverify_after_fix(text: str, fix_field: str | None) -> tuple[bool, str]:
    """True when the latest re-verify entry is newer than every fix entry and did not fail."""
    lines = history_lines(text)
    fix_shas = set(SHA_RE.findall(fix_field or ""))
    last_confirm = -1
    last_fix = -1
    for index, line in enumerate(lines):
        if REVERIFY_ENTRY_RE.search(line) and not NOT_REVERIFY_RE.search(line):
            if REVERIFY_FAILED_RE.search(line) and not REVERIFY_CONFIRMED_RE.search(line):
                last_fix = index
            else:
                last_confirm = index
        elif FIX_RE.search(line) or any(sha in line for sha in fix_shas):
            last_fix = index
    if last_confirm < 0:
        return False, "no re-verify entry in the status history"
    if last_fix > last_confirm:
        return False, "a fix or failed re-verify entry is newer than the latest re-verify"
    return True, ""


def decide(
    row: dict[str, str],
    findings: dict[str, dict[str, Any]],
    passes: dict[str, dict[str, Any]],
) -> tuple[bool, str]:
    """Return (close, reason). reason explains why a row stays as it is."""
    if row["Type"] not in CLOSABLE_TYPES:
        return False, "type is not closed by this script"
    if row["Status"] not in CLOSABLE_STATUSES:
        return False, f"status {row['Status']}"
    dependency = DEPENDENCY_RE.search(row.get("Note", ""))
    if dependency:
        return False, f"notes name a dependency ({dependency.group(0)!r}); needs a person"
    ids = ITEM_RE.findall(row.get("Findings", ""))
    if not ids:
        return False, "no listed items"
    for item in ids:
        if row["Type"] == "pass-verify":
            record = passes.get(item)
            if record is None:
                return False, f"{item} unknown"
            if record.get("verify_status") not in ("confirmed", "refuted"):
                return False, f"{item} verify {record.get('verify_status')}"
            continue
        record = findings.get(item)
        if record is None:
            return False, f"{item} unknown"
        if row["Type"] == "finding-verify":
            if record.get("verify_status") not in ("confirmed", "refuted"):
                return False, f"{item} verify {record.get('verify_status')}"
            continue
        if record.get("re_verify_status") != "confirmed":
            return False, f"{item} re-verify {record.get('re_verify_status')}"
        ok, why = reverify_after_fix(record.get("text", ""), record.get("fix"))
        if not ok:
            return False, f"{item}: {why}"
    return True, ""


def load_state() -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    findings = {}
    for path in lib.finding_paths():
        record = lib.parse_finding(path)
        record["text"] = path.read_text(encoding="utf-8")
        findings[record["id"]] = record
    passes = {p["id"]: p for p in lib.load_passes()}
    return findings, passes


def close_rows(text: str, findings, passes, closer: str, today: str) -> tuple[str, list[str]]:
    header: list[str] | None = None
    closed = []
    out = []
    for line in text.splitlines(keepends=True):
        if line.startswith("| Task "):
            header = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if header and line.startswith("| SECQ-"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if len(cells) == len(header):
                row = dict(zip(header, cells))
                ok, reason = decide(row, findings, passes)
                if ok:
                    notes = row["Note"]
                    prefix = notes.rstrip(".") + ". " if notes not in ("", "-") else ""
                    row["Status"] = "done"
                    row["Note"] = (
                        f"{prefix}Closed by {closer} {today} (close_queue.py): every listed result is "
                        "recorded and no dependency is named."
                    )
                    line = "| " + " | ".join(row[h] for h in header) + " |\n"
                    closed.append(row["Task"])
                elif row["Status"] in CLOSABLE_STATUSES and row["Type"] in CLOSABLE_TYPES:
                    print(f"keep {row['Task']}: {reason}")
        out.append(line)
    return "".join(out), closed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--by", required=True, help="agent name recorded in the closing note")
    parser.add_argument("--apply", action="store_true", help="rewrite QUEUE.md (default: dry run)")
    args = parser.parse_args()
    findings, passes = load_state()
    queue = lib.ROOT / "QUEUE.md"
    text, closed = close_rows(
        queue.read_text(encoding="utf-8"), findings, passes, args.by, date.today().isoformat()
    )
    for row_id in closed:
        print(("closed " if args.apply else "would close ") + row_id)
    if args.apply and closed:
        queue.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
