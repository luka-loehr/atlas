"""Sequence file format (.show.json) — the compiled show a player runs.

{
  "version": 1,
  "meta": {
    "song_file": "music.mp3",          // resolved against the media root
    "title": "Party Rock Anthem",
    "bpm": 130.0, "anchor_ms": 59700.0,
    "duration_ms": 260400,
    "audio_latency_ms": 300,           // playback-device calibration
    "laser_lead_ms": 3900, "strobe_lead_ms": 6500,
    "preroll_fog_ms": 20000,           // fog fills the dark room pre-show
    "calibration": true                // OPTIONAL. true = this show measures
                                       // latency, so play.py must run it raw
                                       // and ignore lightshows/calibration.json
  },
  "cues":    [{"t0":..,"t1":..,"fx":"name","p":{..}}, ...],   // sorted, non-overlapping
  "accents": [[ms, strength], ...],    // single-frame white max-blend overlays
  "devices": {"fog":[[a,b],..], "laser":[[a,b],..], "strobe":[[a,b],..]}
}
"""
import json
import os

from .effects import EFFECTS

REQUIRED_META = ("bpm", "anchor_ms", "duration_ms")

def load(path):
    with open(path) as f:
        seq = json.load(f)
    validate(seq, path)
    return seq

def save(seq, path):
    validate(seq, path)
    cues = [{k: v for k, v in c.items() if not k.startswith("_")} for c in seq["cues"]]
    for c in cues:                                    # strip runtime caches from params
        c["p"] = {k: v for k, v in c.get("p", {}).items() if not k.startswith("_")}
    out = dict(seq, cues=cues)
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")

def validate(seq, path="<seq>"):
    if seq.get("version") != 1:
        raise ValueError(f"{path}: unsupported sequence version {seq.get('version')!r}")
    meta = seq.get("meta", {})
    for k in REQUIRED_META:
        if k not in meta:
            raise ValueError(f"{path}: meta.{k} missing")
    prev_end = -1e12
    for i, c in enumerate(seq.get("cues", [])):
        if c["fx"] not in EFFECTS:
            raise ValueError(f"{path}: cue {i} unknown effect {c['fx']!r}")
        if not (c["t0"] < c["t1"]):
            raise ValueError(f"{path}: cue {i} empty window {c['t0']}..{c['t1']}")
        if c["t0"] < prev_end:
            raise ValueError(f"{path}: cue {i} overlaps previous (t0={c['t0']} < {prev_end})")
        prev_end = c["t1"]
    for dev, wins in seq.get("devices", {}).items():
        if dev not in ("fog", "laser", "strobe"):
            raise ValueError(f"{path}: unknown device {dev!r}")
        for a, b in wins:
            if not a < b:
                raise ValueError(f"{path}: device {dev} empty window {a}..{b}")

def media_dir():
    """Where show media (audio + covers) lives. The default is deliberately
    OUTSIDE the checkout: shows/ is a tracked directory, so media sitting in it
    is one `git clean -fdx` from deletion. Writers must use this and only this;
    readers keep a shows/ fallback for hand-dropped files."""
    # ATLAS_LIGHTSHOW_MEDIA_DIR: override the media root (e.g. a NAS mount)
    d = os.environ.get("ATLAS_LIGHTSHOW_MEDIA_DIR", "").strip()
    return os.path.abspath(d or "/var/lib/atlas/lightshow-media")

def song_path(seq, seq_path):
    """Resolve meta.song_file: absolute as-is, else the media root, else
    next to the sequence file."""
    sf = seq["meta"].get("song_file")
    if not sf:
        return None
    if os.path.isabs(sf):
        return sf
    root = media_dir()
    cand = os.path.normpath(os.path.join(root, sf))
    # a song_file of "../x.mp3" must not escape the media root
    if cand.startswith(root + os.sep) and os.path.exists(cand):
        return cand
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(seq_path)), sf))
