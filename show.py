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
import colorsys, math, re, shutil, socket, struct, subprocess, sys, time, os

BASE = os.path.dirname(os.path.abspath(__file__))
XSQ = os.path.join(BASE, "music.xsq")
MP3 = os.path.join(BASE, "music.mp3")
ARTNET_TARGET = ("192.168.1.100", 6454)   # atlas on the LAN
FPS = 25
NCHAN = 20
AUDIO_LATENCY_MS = 160      # Bluetooth delays the sound; delay light to match. Tune me.
LASER_LATENCY_MS = 6600     # measured: plug-on -> laser pattern visible

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH, FOG, LASER = 0, 3, 6, 9, 12, 15, 18, 19
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]
ALL_LIGHTS = [DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]   # all 6 colour fixtures

# laser is a slow on/off cue: list of (visible_start_ms, visible_end_ms).
# The engine powers the plug LASER_LATENCY_MS earlier so it's lit on time.
LASER_CUES = [(59700, 64700)]     # laser during the drop strobe

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

def beat_count(t):
    return sum(1 for b in BEATS if b <= t)

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

    # --- build-up (40 - 58s): rainbow that steps on every beat + beat pulse ---
    if 40000 <= t < 58000:
        b = last_beat(t)
        env = math.exp(-(t - b) / 250.0) if b is not None else 0.0
        bright = 0.25 + 0.75 * env                   # pulses up on each beat
        bi = beat_count(t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0   # rainbow, advances per beat
            r, g, bl = (int(255 * bright * c) for c in colorsys.hsv_to_rgb(hue, 1.0, 1.0))
            dmx[ch], dmx[ch+1], dmx[ch+2] = r, g, bl

    # --- DROP at 59.7s: strobe @ 15%, 5s — Regale + Display only (not Deckenlampe) ---
    DROP_T = 59700
    STROBE_LIGHTS = [DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]
    if DROP_T <= t < DROP_T + 5000:
        strobe_on = (int(t // 200) % 2 == 0)         # slower still (~2.5 Hz)
        v = int(255 * 0.15) if strobe_on else 0
        for ch in STROBE_LIGHTS:
            dmx[ch] = dmx[ch+1] = dmx[ch+2] = v
    # (58.0s - DROP_T is left completely dark on purpose — calm before the drop)

    # --- fog: 10s continuous, 45s - 55s ---
    if 45000 <= t < 55000:
        dmx[FOG] = 255

    # --- laser cue (power the plug 6.6s before it should be visible) ---
    if any((vs - LASER_LATENCY_MS) <= t < ve for vs, ve in LASER_CUES):
        dmx[LASER] = 255
    return bytes(dmx)

def artnet(dmx, seq):
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

def main():
    start_s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
    end_s   = float(sys.argv[2]) if len(sys.argv) > 2 else PRE_DROP_END / 1000.0
    play_audio = os.path.exists(MP3)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    audio = None
    if play_audio:
        if start_s > 0 and shutil.which("ffplay"):        # seek with ffplay
            audio = subprocess.Popen(["ffplay", "-nodisp", "-autoexit",
                                      "-loglevel", "quiet", "-ss", str(start_s), MP3])
        elif start_s == 0:                                # afplay from the top
            audio = subprocess.Popen(["afplay", MP3])
        else:
            play_audio = False                            # no seek available
    print(f"playing {start_s:.1f}s -> {end_s:.1f}s  |  audio={'yes' if play_audio else 'no'}  |  {len(BEATS)} beats", flush=True)

    seq = 0
    t0 = time.monotonic()
    try:
        while True:
            song_s = start_s + (time.monotonic() - t0)
            if song_s >= end_s:
                break
            # light lags by the Bluetooth latency so it matches what you hear
            song_ms = song_s * 1000.0 - (AUDIO_LATENCY_MS if play_audio else 0)
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
