#!/usr/bin/env python3
"""Regenerate audits.html from findings/AUD-*.md. With --check, fail if it
is out of date."""

from __future__ import annotations

import sys

import review_lib as lib


def main() -> int:
    path = lib.ROOT / "audits.html"
    content = lib.render_audits(lib.load_findings())
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        return 0
    if "--check" in sys.argv[1:]:
        print("out of date (run scripts/update_audits_html.py): audits.html")
        return 1
    path.write_text(content, encoding="utf-8")
    print("wrote audits.html")
    return 0


if __name__ == "__main__":
    sys.exit(main())
