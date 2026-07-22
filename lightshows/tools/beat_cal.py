#!/usr/bin/env python3
"""Latency calibration — all shelves flash ON on every beat for the first ~12s.

Play with a latency value and adjust until the flash lands exactly on the beat
you HEAR (through your AirPods). Then tell me the number for AUDIO_LATENCY_MS.

    python3 beat_cal.py 300      # try 300 ms
    python3 beat_cal.py 350      # try 350 ms
    python3 beat_cal.py 300 20   # latency 300, run 20s

Rule of thumb:
    flash comes BEFORE the beat you hear  -> latency TOO LOW,  raise it
    flash comes AFTER  the beat you hear  -> latency TOO HIGH, lower it
"""
import os, socket, struct, subprocess, sys, time

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BASE))
from lslib.rig import ARTNET_TARGET   # env ATLAS_ARTNET_HOST / artnet_host.local

MP3 = os.path.join(BASE, "music.mp3")
FPS = 25
NCHAN = 21

# 130.00 BPM lattice (same as the show), phase-anchored on the drop-1 kick
BEAT = 60000.0 / 130.0          # 461.538 ms
ANCHOR = 59700.0
ON_MS = 150.0                   # how long each flash stays on

# shelves = REGAL_HINT(6-8) REGAL_LINK(9-11) REGAL_RECH(15-17)
SHELVES = [6, 9, 15]

def artnet(dmx, seq):
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

def main():
    latency = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
    print(f"LATENZ = {latency:.0f} ms  |  Regale blitzen auf den Takt, {dur:.0f}s")
    print("  Blitz VOR dem Beat -> Latenz erhoehen | Blitz NACH dem Beat -> Latenz senken")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    audio = subprocess.Popen(["afplay", MP3])
    t0 = time.monotonic()
    seq = 0
    next_t = t0
    try:
        while time.monotonic() - t0 < dur:
            song_ms = (time.monotonic() - t0) * 1000.0 - latency
            phase = (song_ms - ANCHOR) % BEAT
            on = phase < ON_MS
            dmx = bytearray(NCHAN)
            if on and song_ms >= 0:
                for ch in SHELVES:
                    dmx[ch] = dmx[ch + 1] = dmx[ch + 2] = 200   # bright white flash
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(dmx), seq), ARTNET_TARGET)
            next_t += 1.0 / FPS
            time.sleep(max(0.0, next_t - time.monotonic()))
    finally:
        for _ in range(3):
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(NCHAN), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
        audio.terminate()
    print("fertig.")

if __name__ == "__main__":
    main()
