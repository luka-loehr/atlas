#!/usr/bin/env python3
"""makeshow — turn ANY song into a light show.

    python3 makeshow.py path/to/song.mp3 [--force] [--title "..."]
    python3 makeshow.py https://youtube.com/watch?v=...   # yt-dlp -> mp3 -> show

1. URL? downloads + converts to mp3 (yt-dlp), title from the video
2. ships the song to atlas, runs the GPU analysis there (Beat This! +
   librosa) -> analysis.json (cached)
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
    s = "".join(c if c.isalnum() else "-" for c in base)
    while "--" in s:
        s = s.replace("--", "-")
    return s.strip("-")[:60].rstrip("-")


def download_audio(url):
    """YouTube (or any yt-dlp source) -> mp3 in downloads/, returns (path, title)."""
    if not shutil.which("yt-dlp") or not shutil.which("ffmpeg"):
        sys.exit("yt-dlp + ffmpeg noetig:  brew install yt-dlp ffmpeg")
    dl = os.path.join(ROOT, "downloads")
    os.makedirs(dl, exist_ok=True)
    print(f"download: {url}")
    r = subprocess.run(
        ["yt-dlp", "--no-playlist", "-x", "--audio-format", "mp3",
         "--audio-quality", "0", "--no-simulate", "--quiet",
         "-o", os.path.join(dl, "%(title)s.%(ext)s"),
         "--print", "after_move:filepath", url],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"yt-dlp FAILED:\n{r.stderr.strip()[-800:]}")
    path = r.stdout.strip().splitlines()[-1]
    title = os.path.splitext(os.path.basename(path))[0]
    print(f"download: ok -> {os.path.relpath(path, ROOT)}")
    return path, title


def analyze_local(song, name, force):
    """Run the analyzer on THIS machine (used when makeshow runs on atlas)."""
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, f"{name}.analysis.json")
    if os.path.exists(cached) and not force:
        print(f"analysis: cached ({os.path.relpath(cached, ROOT)})")
        with open(cached) as f:
            return json.load(f)
    print("analysis: running Beat This! + librosa locally (GPU) ...")
    py = os.path.join(ROOT, "analyze", ".venv", "bin", "python")
    run([py, os.path.join(ROOT, "analyze", "analyze_song.py"), song, cached])
    with open(cached) as f:
        return json.load(f)


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
    ap.add_argument("song", help="mp3 path OR a URL (YouTube etc.)")
    ap.add_argument("--force", action="store_true", help="re-run analysis")
    ap.add_argument("--title")
    ap.add_argument("--bpm", type=float,
                    help="official BPM: densify the fitted lattice to match")
    ap.add_argument("--extreme", action="store_true",
                    help="denser strobes, full brightness, more fog")
    ap.add_argument("--local", action="store_true",
                    help="analyze on THIS machine (when run on atlas itself)")
    args = ap.parse_args()
    title = args.title
    if args.song.startswith(("http://", "https://")):
        song, video_title = download_audio(args.song)
        title = title or video_title
    else:
        song = os.path.abspath(args.song)
        if not os.path.exists(song):
            sys.exit(f"not found: {song}")
    name = slug(title) if title else slug(song)

    analysis = (analyze_local if args.local else analyze_on_atlas)(song, name, args.force)

    if args.bpm:                                      # official-BPM lattice override
        f = analysis["tempo"]["bpm"]
        k = max(1, round(args.bpm / f))
        if k > 1 and abs(f * k - args.bpm) / args.bpm < 0.05:
            analysis["tempo"]["bpm"] = f * k          # densify: anchor stays valid
            print(f"tempo override: {f:.2f} -> {f * k:.2f} bpm "
                  f"(x{k}, offiziell {args.bpm:g})")
        elif abs(f - args.bpm) / args.bpm >= 0.05:
            print(f"WARNUNG: offiziell {args.bpm:g} passt nicht zu "
                  f"gemessen {f:.2f} (kein ganzzahliges Verhaeltnis) — nutze {f:.2f}")

    os.makedirs(SHOWS, exist_ok=True)
    # keep a copy of the song next to the shows for stable relative paths
    local_song = os.path.join(SHOWS, f"{name}{os.path.splitext(song)[1]}")
    if not os.path.exists(local_song):
        shutil.copy(song, local_song)

    seq, warnings = compile_show(analysis, os.path.basename(local_song),
                                 title=title or name,
                                 opts={"extreme": args.extreme})
    out = os.path.join(SHOWS, f"{name}.show.json")
    sequence.save(seq, out)
    summarize(seq, warnings)
    print(f"\nwrote {os.path.relpath(out, ROOT)}")
    print(f"play:  python3 play.py {os.path.relpath(out, ROOT)}")
    git_autopush(name, title or name)


def git_autopush(name, title):
    """Commit + push the new show (json + audio + analysis). Non-fatal."""
    def g(*args):
        return subprocess.run(["git", "-C", ROOT, *args],
                              capture_output=True, text=True)
    if g("rev-parse", "--git-dir").returncode != 0:
        return
    g("add", f"shows/{name}.show.json", f"analysis_cache/{name}.analysis.json")
    g("add", *(p for p in [os.path.join("shows", f)
                           for f in os.listdir(SHOWS) if f.startswith(name + ".")]
               if os.path.exists(os.path.join(ROOT, p))))
    if not g("status", "--porcelain").stdout.strip():
        return
    if g("commit", "-m", f"show: {title}").returncode == 0:
        r = g("push")
        print("git: Show committet & gepusht" if r.returncode == 0
              else f"git: Push fehlgeschlagen (committet): {r.stderr.strip()[-200:]}")


if __name__ == "__main__":
    main()
