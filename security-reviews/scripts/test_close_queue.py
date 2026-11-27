"""Tests for close_queue.py: python3 -m unittest discover -s security-reviews/scripts -p 'test_*.py'."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import close_queue as cq  # noqa: E402


def finding(history: list[str], verify="confirmed", reverify="confirmed", fix="aaaaaaa", status="fixed"):
    text = "# SEC-X: t\n\nStatus: fixed\n\n## Status history\n\n" + "\n".join(history) + "\n"
    return {
        "status": status,
        "verify_status": verify,
        "re_verify_status": reverify,
        "fix": fix,
        "text": text,
    }


def row(type_="fix-reverify", status="open", notes="-", items="SEC-20261006-210000-OPS-001"):
    return {"Task": "SECQ-20261007-099", "Status": status, "Type": type_, "Findings": items, "Note": notes}


FID = "SEC-20261006-210000-OPS-001"
CONFIRMED_THEN_FIXED = [
    "- 2026-10-06: in_progress, fixed on main in 91e1749 by snapshots.",
    "- 2026-10-07 re-verify confirmed by secreview: the lock rules hold. Status fixed.",
    "- 2026-10-07 residual addressed by worker PR #22 (54bf146; not yet live). Re-verify after the train.",
]
FIXED_THEN_CONFIRMED = [
    "- 2026-10-07 fixed by supplychain in 5aa7199.",
    "- 2026-10-06 re-verify by closer at f22558f: FAILED on one point. Not fixed: covers() uses any().",
    "- 2026-10-06 re-verify (SECQ-20261007-002) by closer (model; not supplychain) at 7a21e82: CONFIRMED.",
]


class CloseQueueTest(unittest.TestCase):
    def test_secq_20261007_003_stays_blocked(self):
        # The row that was closed wrongly: blocked on PR #22, and a fix landed after the re-verify.
        findings = {FID: finding(CONFIRMED_THEN_FIXED)}
        notes = "Blocked until PR #22 (54bf146) is live. Then independent re-verify (not snapshots)."
        self.assertFalse(cq.decide(row(status="blocked", notes=notes), findings, {})[0])
        self.assertFalse(cq.decide(row(status="open", notes=notes), findings, {})[0])

    def test_fix_newer_than_reverify_keeps_row(self):
        close, reason = cq.decide(row(), {FID: finding(CONFIRMED_THEN_FIXED)}, {})
        self.assertFalse(close)
        self.assertIn("newer", reason)

    def test_fix_commit_named_after_reverify_keeps_row(self):
        history = [
            "- 2026-10-07 re-verify confirmed by closer.",
            "- 2026-10-07 follow-up commit bbbbbbb by fixer.",
        ]
        self.assertFalse(cq.decide(row(), {FID: finding(history, fix="aaaaaaa, bbbbbbb")}, {})[0])

    def test_reverify_newer_than_fix_closes(self):
        self.assertEqual(cq.decide(row(), {FID: finding(FIXED_THEN_CONFIRMED)}, {}), (True, ""))

    def test_reverify_entry_without_the_word_confirmed_closes(self):
        history = [
            "- 2026-10-06 fixed by stream: c07a09b deployed in train 4; independent re-verify queued (SECQ-X).",
            "- 2026-10-06 re-verify (SECQ-X) by closer live: origin.kiste.run answers 401; the guest saw no x-kiste-*.",
        ]
        self.assertTrue(cq.decide(row(), {FID: finding(history, fix="c07a09b")}, {})[0])

    def test_failed_in_the_evidence_is_not_a_failed_reverify(self):
        history = [
            "- 2026-10-06: in_progress, fixed in 7e13ca8.",
            "- 2026-10-06 fixed: deployed. Verify and re-verify confirmed by closer: a failed load falls back.",
        ]
        self.assertTrue(cq.decide(row(), {FID: finding(history, fix="7e13ca8")}, {})[0])

    def test_failed_reverify_last_keeps_row(self):
        history = FIXED_THEN_CONFIRMED[:2]
        self.assertFalse(cq.decide(row(), {FID: finding(history)}, {})[0])

    def test_reverify_status_not_confirmed_keeps_row(self):
        for status in ("pending", "failed", "not-applicable"):
            self.assertFalse(cq.decide(row(), {FID: finding(FIXED_THEN_CONFIRMED, reverify=status)}, {})[0])

    def test_no_confirming_history_line_keeps_row(self):
        history = ["- 2026-10-07 fixed in 5aa7199.", "- 2026-10-07 finder's triage (not a re-verify): confirmed."]
        self.assertFalse(cq.decide(row(), {FID: finding(history)}, {})[0])

    def test_dependency_notes_keep_row(self):
        findings = {FID: finding(FIXED_THEN_CONFIRMED)}
        for notes in (
            "Re-verify after the train ships.",
            "Waits for PR #31.",
            "Once the lock is live, check it.",
            "Not yet live.",
            "Needs deploy of 1234abc.",
        ):
            self.assertFalse(cq.decide(row(notes=notes), findings, {})[0], notes)

    def test_blocked_done_superseded_never_close(self):
        findings = {FID: finding(FIXED_THEN_CONFIRMED)}
        for status in ("blocked", "done", "superseded"):
            self.assertFalse(cq.decide(row(status=status), findings, {})[0])

    def test_every_listed_item_must_qualify(self):
        other = "SEC-20261007-141500-OPS-001"
        findings = {FID: finding(FIXED_THEN_CONFIRMED), other: finding(CONFIRMED_THEN_FIXED)}
        self.assertFalse(cq.decide(row(items=f"{FID}, {other}"), findings, {})[0])
        self.assertFalse(cq.decide(row(items=f"{FID}, SEC-20990101-000000-OPS-001"), findings, {})[0])

    def test_finding_verify(self):
        self.assertTrue(cq.decide(row("finding-verify"), {FID: finding([], verify="refuted")}, {})[0])
        for status in ("pending", "blocked"):
            self.assertFalse(cq.decide(row("finding-verify"), {FID: finding([], verify=status)}, {})[0])

    def test_pass_verify(self):
        r = row("pass-verify", items="PASS-20261005-001")
        self.assertTrue(cq.decide(r, {}, {"PASS-20261005-001": {"verify_status": "confirmed"}})[0])
        self.assertFalse(cq.decide(r, {}, {"PASS-20261005-001": {"verify_status": "pending"}})[0])
        self.assertFalse(cq.decide(r, {}, {})[0])

    def test_other_types_untouched(self):
        self.assertFalse(cq.decide(row("review"), {FID: finding(FIXED_THEN_CONFIRMED)}, {})[0])

    def test_close_rows_rewrites_only_qualifying_rows(self):
        findings = {FID: finding(FIXED_THEN_CONFIRMED)}
        table = (
            "## Tasks\n\n"
            "| Task | Status | Type | Track | Scope | Priority | Findings | Claim | Note |\n"
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
            f"| SECQ-20261007-001 | open | fix-reverify | - | s | p1 | {FID} | - | - |\n"
            f"| SECQ-20261007-003 | blocked | fix-reverify | - | s | p1 | {FID} | - | Blocked until PR #22 is live. |\n"
        )
        out, closed = cq.close_rows(table, findings, {}, "tester", "2026-10-07")
        self.assertEqual(closed, ["SECQ-20261007-001"])
        self.assertIn("| SECQ-20261007-001 | done |", out)
        self.assertIn("| SECQ-20261007-003 | blocked |", out)


if __name__ == "__main__":
    unittest.main()
