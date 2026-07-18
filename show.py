#!/usr/bin/env python3
"""Headless show engine — RUNS ON THE MAC.

Plays the song locally (afplay -> your Bluetooth speakers) AND streams
Art-Net over the LAN to the bridge on atlas, which drives Hue + the fog
machine. Music and light share the Mac's clock, so they stay in sync.
No xLights needed for playback.

Effects are authored here as math over time, beat-synced to the real beats
from the xLights beat track in music.xsq.

Usage:
    python3 show.py            # pre-drop section, with music
    python3 show.py 30         # first 30s, with music
    python3 show.py 5 12       # 5s..12s, LIGHTS ONLY (no audio, for tuning)

Turn OFF "Output To Lights" in xLights first, or both fight over the bridge.
"""
import math, re, socket, struct, subprocess, sys, time, os

BASE = os.path.dirname(os.path.abspath(__file__))
XSQ = os.path.join(BASE, "music.xsq")
MP3 = os.path.join(BASE, "music.mp3")
ARTNET_TARGET = ("192.168.1.100", 6454)   # atlas on the LAN
FPS = 25
NCHAN = 19
AUDIO_LATENCY_MS = 160     # Bluetooth delays the sound; delay light to match. Tune me.

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH, FOG = 0, 3, 6, 9, 12, 15, 18
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]

# ---- real beats from the xLights beat track ----------------------------
def load_beats():
    s = open(XSQ).read()
    m = re.search(r'<Element type="timing" name="Beats">(.*?)</Element>', s, re.S)
    return sorted(set(int(x) for x in re.findall(r'startTime="(\d+)"', m.group(1)))) if m else []

BEATS = load_beats()
PRE_DROP_END = 18600   # ms — end of the pre-melody section

def last_beat(t):
    prev = [b for b in BEATS if b <= t]
    return prev[-1] if prev else None

def nearest_beat(t):
    return min(BEATS, key=lambda b: abs(b - t)) if BEATS else t

def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))

# ---- the SHOW: 19 DMX bytes for song-time t (ms) -----------------------
def render(t):
    dmx = bytearray(NCHAN)
    if 0 <= t <= PRE_DROP_END:
        # Regale: NO beat pulse — slowly ramp dark -> 50% over the section,
        # colour drifting white -> blue
        frac = clamp(t / PRE_DROP_END)
        bright = 0.50 * frac
        r = int(255 * (1 - frac) * bright)
        g = int(255 * (1 - frac) * bright)
        bl = int(255 * bright)
        for ch in REGALE:
            dmx[ch], dmx[ch+1], dmx[ch+2] = r, g, bl
        # Deckenlampe: smooth fade in/out to the beat, max 20%
        dt = abs(t - nearest_beat(t))
        half = 220.0
        bump = 0.5 * (1 + math.cos(math.pi * dt / half)) if dt < half else 0.0
        d = int(255 * 0.20 * bump)
        dmx[DECKE], dmx[DECKE+1], dmx[DECKE+2] = d, d, d
    return bytes(dmx)

def artnet(dmx, seq):
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

def main():
    start_s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
    end_s   = float(sys.argv[2]) if len(sys.argv) > 2 else PRE_DROP_END / 1000.0
    play_audio = (start_s == 0.0 and os.path.exists(MP3))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    audio = None
    print(f"playing {start_s:.1f}s -> {end_s:.1f}s  |  audio={'yes' if play_audio else 'no'}  |  {len(BEATS)} beats", flush=True)

    seq = 0
    t0 = time.monotonic() - start_s
    if play_audio:
        audio = subprocess.Popen(["afplay", MP3])   # song starts at 0
        t0 = time.monotonic()                        # resync clock to audio start
    try:
        while True:
            t = time.monotonic() - t0
            if t >= end_s:
                break
            # light lags by the Bluetooth latency so it matches what you hear
            song_ms = t * 1000.0 - (AUDIO_LATENCY_MS if play_audio else 0)
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(render(song_ms), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
    finally:
        for _ in range(3):                            # fade to black
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(NCHAN), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
        if audio:
            audio.terminate()
    print("done", flush=True)

if __name__ == "__main__":
    main()
