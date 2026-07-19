#!/usr/bin/env python3
"""play — run a compiled .show.json light show.

    python3 play.py shows/<name>.show.json [start_s] [end_s] [--no-preroll]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lslib import sequence
from lslib.player import Player


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("show")
    ap.add_argument("start", nargs="?", type=float, default=0.0)
    ap.add_argument("end", nargs="?", type=float, default=None)
    ap.add_argument("--no-preroll", action="store_true")
    ap.add_argument("--no-audio", action="store_true",
                    help="lights only (audio plays elsewhere, e.g. the iOS app)")
    args = ap.parse_args()

    seq = sequence.load(args.show)
    song = None if args.no_audio else sequence.song_path(seq, args.show)
    if song and not os.path.exists(song):
        print(f"WARNUNG: Song nicht gefunden ({song}) — Lichter ohne Musik")
        song = None
    Player(seq).play(song, start_s=args.start, end_s=args.end,
                     preroll=not args.no_preroll)


if __name__ == "__main__":
    main()
