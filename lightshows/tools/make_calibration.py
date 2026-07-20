#!/usr/bin/env python3
"""Generate the calibration assets: shows/calibration.wav (click track) +
shows/calibration.show.json (white full-room flash exactly on every click).

The app plays the audio on the phone (like any show), the lights flash via
atlas, and the phone camera measures flash-vs-click offset = audio latency.
"""
import json
import math
import os
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOWS = os.path.join(ROOT, "shows")

SR = 44100
CLICKS_S = [1 + 2 * i for i in range(10)]      # 1,3,5,...,19s
DUR_S = 21
CLICK_MS = 30
FLASH_MS = 120


def main():
    os.makedirs(SHOWS, exist_ok=True)

    # --- click track: 1 kHz bursts with a fast decay, silence elsewhere
    n = SR * DUR_S
    samples = [0.0] * n
    for t in CLICKS_S:
        start = int(t * SR)
        for i in range(int(SR * CLICK_MS / 1000)):
            env = math.exp(-i / (SR * 0.004))
            samples[start + i] = 0.9 * env * math.sin(2 * math.pi * 1000 * i / SR)
    wav_path = os.path.join(SHOWS, "calibration.wav")
    with wave.open(wav_path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))

    # --- the show: white flash on every click, black between
    seq = {
        "version": 1,
        "meta": {
            "song_file": "calibration.wav",
            "title": "Kalibrierung",
            "bpm": 60.0,
            "anchor_ms": 0.0,
            "duration_ms": DUR_S * 1000,
            "audio_latency_ms": 0,        # measuring — no correction applied
            "calibration": True,
        },
        "cues": [
            {"t0": t * 1000, "t1": t * 1000 + FLASH_MS,
             "fx": "solid", "p": {"color": [0.0, 0.0, 1.0]}}
            for t in CLICKS_S
        ],
        "accents": [],
        "devices": {},
    }
    json_path = os.path.join(SHOWS, "calibration.show.json")
    with open(json_path, "w") as f:
        json.dump(seq, f, indent=1)
        f.write("\n")
    print(f"wrote {wav_path}\nwrote {json_path}")


if __name__ == "__main__":
    main()
