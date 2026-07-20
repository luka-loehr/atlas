#!/usr/bin/env python3
"""Golden test: the modular player must render the ported Party Rock
sequence FRAME-IDENTICAL to the legacy hand-coded show.py (v6)."""
import importlib.util
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, ROOT)
from lslib import sequence
from lslib.player import Player

def main():
    spec = importlib.util.spec_from_file_location(
        "legacy", os.path.join(ROOT, "tests", "reference_show_v6.py"))
    legacy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(legacy)

    seq = sequence.load(os.path.join(ROOT, "shows", "party-rock.show.json"))
    player = Player(seq)

    diffs = 0
    first = None
    for t in range(-20300, 260400, 40):
        a = legacy.render(float(t))
        b = player.render(float(t))
        if a != b:
            diffs += 1
            if first is None:
                first = (t, a, b)
    total = len(range(-20300, 260400, 40))
    if diffs:
        t, a, b = first
        print(f"FAIL: {diffs}/{total} frames differ; first at t={t}ms")
        print(f"  legacy: {list(a)}")
        print(f"  player: {list(b)}")
        sys.exit(1)
    print(f"GOLDEN PASS: {total} frames identical (legacy show.py == modular player)")

if __name__ == "__main__":
    main()
