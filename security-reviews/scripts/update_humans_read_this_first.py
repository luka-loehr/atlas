#!/usr/bin/env python3
"""Regenerate data/findings.json, the generated block of INDEX.md and
humans_read_this_first.html from findings/, data/passes.json and
data/timeline.json. With --check, fail if any of them is out of date."""

from __future__ import annotations

import sys

import review_lib as lib


def outputs() -> dict[str, str]:
    findings = lib.load_findings()
    passes = lib.load_passes()
    return {
        "data/findings.json": lib.render_findings_json(findings),
        "INDEX.md": lib.render_index(findings, passes),
        "humans_read_this_first.html": lib.render_humans(findings, passes, lib.load_timeline()),
    }


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for relative, content in outputs().items():
        path = lib.ROOT / relative
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == content:
            continue
        if check:
            stale.append(relative)
        else:
            path.write_text(content, encoding="utf-8")
            print(f"wrote {relative}")
    if stale:
        print("out of date (run scripts/update_humans_read_this_first.py): " + ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
