#!/usr/bin/env python3
"""makeshow — turn ANY song into a light show.

    python3 makeshow.py path/to/song.mp3 [--force] [--title "..."]

1. ships the song to atlas
2. runs the GPU analysis there (Beat This! + librosa) -> analysis.json (cached)
3. compiles the analysis into shows/<name>.show.json using the v6 design rules
4. prints the show timeline

Then:  python3 play.py shows/<name>.show.json
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lslib import sequence
from lslib.compiler import compile_show

ROOT = os.path.dirname(os.path.abspath(__file__))
ATLAS = "atlas"
ATLAS_DIR = "~/projects/lightshow"
CACHE = os.path.join(ROOT, "analysis_cache")
SHOWS = os.path.join(ROOT, "shows")


def run(cmd, **kw):
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(cmd)}")
    return r


def slug(name):
    base = os.path.splitext(os.path.basename(name))[0].lower()
    return "".join(c if c.isalnum() else "-" for c in base).strip("-")


def analyze_on_atlas(song, name, force):
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, f"{name}.analysis.json")
    if os.path.exists(cached) and not force:
        print(f"analysis: cached ({os.path.relpath(cached, ROOT)})")
        with open(cached) as f:
            return json.load(f)
    print("analysis: shipping song to atlas ...")
    run(["scp", "-q", song, f"{ATLAS}:{ATLAS_DIR}/analyze/in-{name}.audio"])
    print("analysis: running Beat This! + librosa on atlas (GPU) ...")
    run(["ssh", ATLAS,
         f"cd {ATLAS_DIR}/analyze && .venv/bin/python analyze_song.py "
         f"in-{name}.audio out-{name}.json && rm -f in-{name}.audio"])
    run(["scp", "-q", f"{ATLAS}:{ATLAS_DIR}/analyze/out-{name}.json", cached])
    run(["ssh", ATLAS, f"rm -f {ATLAS_DIR}/analyze/out-{name}.json"])
    with open(cached) as f:
        return json.load(f)


def summarize(seq, warnings):
    m = seq["meta"]
    print(f"\n=== {m['title']} ===")
    print(f"{m['bpm']:.2f} BPM | anchor {m['anchor_ms'] / 1000:.2f}s | "
          f"{m['duration_ms'] / 1000:.1f}s | {len(seq['cues'])} cues")
    for w in warnings:
        print(f"  WARNUNG: {w}")
    print("timeline:")
    for c in seq["cues"]:
        print(f"  {c['t0'] / 1000:7.2f} - {c['t1'] / 1000:7.2f}  {c['fx']}")
    for dev, wins in seq["devices"].items():
        tot = sum(b - a for a, b in wins) / 1000
        print(f"devices/{dev}: {len(wins)} windows, {tot:.1f}s total")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("song")
    ap.add_argument("--force", action="store_true", help="re-run analysis")
    ap.add_argument("--title")
    args = ap.parse_args()
    song = os.path.abspath(args.song)
    if not os.path.exists(song):
        sys.exit(f"not found: {song}")
    name = slug(song)

    analysis = analyze_on_atlas(song, name, args.force)

    os.makedirs(SHOWS, exist_ok=True)
    # keep a copy of the song next to the shows for stable relative paths
    local_song = os.path.join(SHOWS, f"{name}{os.path.splitext(song)[1]}")
    if not os.path.exists(local_song):
        shutil.copy(song, local_song)

    seq, warnings = compile_show(analysis, os.path.basename(local_song),
                                 title=args.title or name)
    out = os.path.join(SHOWS, f"{name}.show.json")
    sequence.save(seq, out)
    summarize(seq, warnings)
    print(f"\nwrote {os.path.relpath(out, ROOT)}")
    print(f"play:  python3 play.py {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
