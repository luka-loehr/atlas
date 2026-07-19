#!/usr/bin/env python3
"""Export a .show.json to xLights-compatible FSEQ for visual preview.

    python3 scripts/export_fseq.py shows/<name>.show.json [out.fseq]

View in xLights: open the layout in xlights/, create a musical sequence
with the song, then Sequence Settings -> Data Layers -> Import the .fseq.
The 21 channels match the rig's Art-Net universe 0 map (see lslib/rig.py).
"""
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from lslib import sequence
from lslib.player import Player
from lslib.rig import NCHAN

STEP_MS = 40                                          # 25 fps


def write_fseq(path, frames, nchan, step_ms):
    hdr = b"PSEQ"
    hdr += struct.pack("<H", 28)                      # offset to channel data
    hdr += bytes([0, 1])                              # version 1.0
    hdr += struct.pack("<H", 28)                      # fixed header length
    hdr += struct.pack("<I", nchan)                   # channels per frame
    hdr += struct.pack("<I", len(frames))             # number of frames
    hdr += bytes([step_ms, 0])                        # step time, flags
    hdr += struct.pack("<HH", 0, 0)                   # universes (unused)
    hdr += bytes([1, 2])                              # gamma, color encoding
    hdr += struct.pack("<H", 0)                       # reserved
    assert len(hdr) == 28
    with open(path, "wb") as f:
        f.write(hdr)
        for fr in frames:
            f.write(fr)


def main():
    show = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(show)[0] + ".fseq"
    if out.endswith(".show.fseq"):
        out = out.replace(".show.fseq", ".fseq")
    seq = sequence.load(show)
    player = Player(seq)
    dur = int(seq["meta"]["duration_ms"])
    frames = [player.render(float(t)) for t in range(0, dur, STEP_MS)]
    write_fseq(out, frames, NCHAN, STEP_MS)
    print(f"wrote {out}: {len(frames)} frames x {NCHAN} channels @ {STEP_MS}ms "
          f"({len(frames) * STEP_MS / 1000:.1f}s)")


if __name__ == "__main__":
    main()
