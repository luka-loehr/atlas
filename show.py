#!/usr/bin/env python3
"""Headless show engine — RUNS ON THE MAC.

Plays the song locally (afplay/ffplay -> Bluetooth speakers) AND streams
Art-Net over the LAN to the bridge on atlas (Hue + fog + laser).

FULL-SONG SHOW, designed from waveform analysis (analyze_audio.py) + the
xLights beat/bar tracks. Structure of music.mp3 (260.3s, ~136 BPM):

  0.0- 14.5  loud intro hook (bass)         -> approved ramp + ceiling beat fade
 14.5- 40.0  pre-melody, no bass            -> dark bar-stepped room circle
 40.0- 58.0  build (approved)               -> beat-stepping rainbow + pulse
 58.0- 59.7  dip                            -> BLACKOUT (calm before the drop)
 59.7- 64.7  DROP 1                         -> tuned strobe + laser
 64.7- 74.2  drop tail                      -> magenta beat-chase, laser tail
 74.2- 86.9  chorus high                    -> left/right ping-pong + ceiling pops
 86.9- 89.0  dip                            -> dim blue base
 89.0- 95.0  high 2                         -> fast cyan comet circle
 95.0-102.0  wind down (bass leaves)        -> fade, Display holds, ceiling breathes
102.0-110.0  verse 2                        -> CEILING ONLY, warm slow breathing
110.0-118.4  rebuild                        -> circle fades back in, rising
118.4-131.0  drop/chorus 2                  -> rotating single-fixture SLAMS (no strobe)
131.0-132.3  collapse                       -> fast fade to black
132.3-135.4  QUIET (near silence)           -> heartbeat: faint deep-red pulse on Display
135.4-150.0  bridge groove                  -> slow purple bar circle
150.0-157.5  wind down                      -> dim out
157.5-159.2  blackout
159.2-164.1  DROP 3                         -> left/right ping-pong STROBE + laser
164.1-172.0  bassless afterglow             -> calm cyan breathe under the laser
172.0-196.7  final build chorus             -> beat comet, hue drifting blue->magenta
196.7-226.9  FINAL HIGH (30s)               -> rotating comet, slow hue wheel, sparse all-flashes
226.9-229.3  dip                            -> dim blue
229.3-258.3  final 2                        -> ping-pong magenta/cyan + ceiling ticks
258.3-260.3  outro                          -> fade to black, ceiling dies last

Fog (needs lead time ~0 but bursts <=10s):   42-52, 112-118, 151-159, 197-204
Laser (visible windows; plug powers 3.9s earlier): 59.7-72, 159.2-175, 229.3-245

Usage:
    python3 show.py            # full song
    python3 show.py 55 70      # a section (audio seeks via ffplay)
"""
import colorsys, math, re, shutil, socket, struct, subprocess, sys, time, os

BASE = os.path.dirname(os.path.abspath(__file__))
XSQ = os.path.join(BASE, "music.xsq")
MP3 = os.path.join(BASE, "music.mp3")
ARTNET_TARGET = ("192.168.1.100", 6454)
FPS = 25
NCHAN = 20
SONG_END_S = 260.4
AUDIO_LATENCY_MS = 160      # Bluetooth delay; light lags to match the ear
LASER_LATENCY_MS = 3900     # measured: plug-on -> laser visible

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH, FOG, LASER = 0, 3, 6, 9, 12, 15, 18, 19
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]
ALL_LIGHTS = [DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]
# room circle (spatial): front wall -> back-left -> display (elevated) -> back-right
CIRCLE = [[REGAL_HINT], [REGAL_LINK], [DISPLAY1, DISPLAY2], [REGAL_RECH]]

FOG_CUES = [(42000, 52000), (112000, 118000), (151000, 159000), (197000, 204000)]
LASER_CUES = [(59700, 72000), (159200, 175000), (229300, 245000)]

# ---- timing tracks from xLights ----------------------------------------
def load_track(name):
    s = open(XSQ).read()
    m = re.search(r'<Element type="timing" name="' + name + r'">(.*?)</Element>', s, re.S)
    return sorted(set(int(x) for x in re.findall(r'startTime="(\d+)"', m.group(1)))) if m else []

BEATS = load_track("Beats")
BARS = load_track("Bars") or BEATS[::4]

def last_of(track, t):
    prev = [b for b in track if b <= t]
    return prev[-1] if prev else None

def idx_of(track, t):
    return sum(1 for b in track if b <= t)

def beat_env(t, decay=250.0):
    b = last_of(BEATS, t)
    return math.exp(-(t - b) / decay) if b is not None else 0.0

def nearest_beat(t):
    return min(BEATS, key=lambda b: abs(b - t)) if BEATS else t

def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))

def hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, clamp(v))
    return int(255 * r), int(255 * g), int(255 * b)

def put(dmx, ch, rgb):
    dmx[ch], dmx[ch + 1], dmx[ch + 2] = rgb

def put_stop(dmx, stop, rgb):
    for ch in stop:
        put(dmx, ch, rgb)

# ---- the SHOW ----------------------------------------------------------
def render(t):
    dmx = bytearray(NCHAN)
    frame = int(t // 40)                     # 25fps frame counter (frame-locked FX)

    # ============ 0 - 18.6s: approved intro ramp + ceiling beat fade ====
    if 0 <= t < 18600:
        frac = clamp(t / 18600)
        bright = 0.50 * frac
        rgb = (int(255 * (1 - frac) * bright), int(255 * (1 - frac) * bright), int(255 * bright))
        for ch in REGALE:
            put(dmx, ch, rgb)
        dt = abs(t - nearest_beat(t))
        bump = 0.5 * (1 + math.cos(math.pi * dt / 220.0)) if dt < 220.0 else 0.0
        d = int(255 * 0.20 * bump)
        put(dmx, DECKE, (d, d, d))

    # ============ 18.6 - 40s: dark bar-stepped room circle ==============
    elif t < 40000:
        sec = (t - 18600) / (40000 - 18600)
        hue = 0.63 + 0.09 * sec              # deep blue drifting to purple
        bi = idx_of(BARS, t)
        active = CIRCLE[bi % 4]
        b = last_of(BARS, t)
        env = math.exp(-(t - b) / 900.0) if b is not None else 0.0
        put_stop(dmx, active, hsv(hue, 1.0, 0.22 * (0.35 + 0.65 * env)))
        prev = CIRCLE[(bi - 1) % 4]          # soft tail on the previous stop
        put_stop(dmx, prev, hsv(hue, 1.0, 0.08))
        d = int(255 * 0.10 * beat_env(t, 200))
        put(dmx, DECKE, (d, d, d))

    # ============ 40 - 58s: approved rainbow beat build =================
    elif t < 58000:
        env = beat_env(t, 250)
        bright = 0.25 + 0.75 * env
        bi = idx_of(BEATS, t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0, bright))

    # ============ 58 - 59.7s: BLACKOUT ==================================
    elif t < 59700:
        pass

    # ============ 59.7 - 64.7s: DROP 1 — tuned strobe ===================
    elif t < 64700:
        if frame % 4 == 0:                   # 1 frame on, 3 off -> crisp 6.25Hz flash
            v = int(255 * 0.22)
            for ch in (DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH):
                put(dmx, ch, (v, v, v))

    # ============ 64.7 - 74.2s: drop tail — magenta beat-chase ==========
    elif t < 74200:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 220)
        for k, stop in enumerate(CIRCLE):
            if k == bi % 4:
                put_stop(dmx, stop, hsv(0.87, 1.0, 0.30 * (0.3 + 0.7 * env)))
            else:
                put_stop(dmx, stop, hsv(0.63, 1.0, 0.05))

    # ============ 74.2 - 86.9s: chorus — left/right ping-pong ===========
    elif t < 86900:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 260)
        left, right = [REGAL_LINK, DISPLAY1], [REGAL_RECH, DISPLAY2]
        side = left if bi % 2 == 0 else right
        hue = 0.63 if bi % 4 < 2 else 0.87
        for ch in side:
            put(dmx, ch, hsv(hue, 1.0, 0.30 * env))
        put(dmx, REGAL_HINT, hsv(hue, 1.0, 0.10 * env))
        if bi % 4 == 0:
            d = int(255 * 0.20 * env)
            put(dmx, DECKE, (d, d, d))

    # ============ 86.9 - 89s: dip =======================================
    elif t < 89000:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.08))

    # ============ 89 - 95s: fast cyan comet circle ======================
    elif t < 95000:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 180)
        head = CIRCLE[bi % 4]
        tail = CIRCLE[(bi - 1) % 4]
        put_stop(dmx, head, hsv(0.50, 1.0, 0.30 * (0.4 + 0.6 * env)))
        put_stop(dmx, tail, hsv(0.55, 1.0, 0.10))

    # ============ 95 - 102s: wind down ==================================
    elif t < 102000:
        sec = (t - 95000) / 7000.0
        put(dmx, DISPLAY1, hsv(0.75, 1.0, 0.15))
        put(dmx, DISPLAY2, hsv(0.75, 1.0, 0.15))
        fade = 0.15 * (1 - sec)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, fade))
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 8000.0))
        put(dmx, DECKE, hsv(0.08, 0.6, 0.12 * breathe))

    # ============ 102 - 110s: CEILING ONLY, warm breathing ==============
    elif t < 110000:
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 8000.0))
        put(dmx, DECKE, hsv(0.08, 0.6, 0.18 * breathe))

    # ============ 110 - 118.4s: rebuild =================================
    elif t < 118400:
        sec = (t - 110000) / 8400.0
        bi = idx_of(BEATS, t)
        env = beat_env(t, 220)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.63, 1.0, (0.12 + 0.10 * sec) * (0.4 + 0.6 * env)))
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 8000.0))
        put(dmx, DECKE, hsv(0.08, 0.6, 0.14 * breathe * (1 - sec)))

    # ============ 118.4 - 131s: drop 2 — rotating fixture SLAMS =========
    elif t < 131000:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 150)               # hard, short slam
        for k, stop in enumerate(CIRCLE):
            if k == bi % 4:
                put_stop(dmx, stop, hsv(0.87, 1.0, 0.35 * env))
            else:
                put_stop(dmx, stop, hsv(0.63, 1.0, 0.06))
        if bi % 8 == 0:
            d = int(255 * 0.25 * env)
            put(dmx, DECKE, (d, d, d))

    # ============ 131 - 132.3s: collapse ================================
    elif t < 132300:
        sec = (t - 131000) / 1300.0
        v = 0.10 * (1 - sec)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, v))

    # ============ 132.3 - 135.4s: QUIET — heartbeat on Display ==========
    elif t < 135400:
        pulse = math.exp(-((t - 132300) % 2000) / 180.0)
        put(dmx, DISPLAY1, hsv(0.0, 1.0, 0.06 * pulse))
        put(dmx, DISPLAY2, hsv(0.0, 1.0, 0.06 * pulse))

    # ============ 135.4 - 150s: bridge groove (purple bar circle) =======
    elif t < 150000:
        bi = idx_of(BARS, t)
        b = last_of(BARS, t)
        env = math.exp(-(t - b) / 900.0) if b is not None else 0.0
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.75, 1.0, 0.20 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(0.75, 1.0, 0.07))
        d = int(255 * 0.08 * beat_env(t, 200))
        put(dmx, DECKE, (d, d, d))

    # ============ 150 - 157.5s: wind down ===============================
    elif t < 157500:
        sec = (t - 150000) / 7500.0
        gain = 1.0 - 0.8 * sec
        bi = idx_of(BARS, t)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.75, 1.0, 0.15 * gain))

    # ============ 157.5 - 159.2s: blackout ==============================
    elif t < 159200:
        pass

    # ============ 159.2 - 164.1s: DROP 3 — ping-pong strobe =============
    elif t < 164100:
        if frame % 4 == 0:
            flash_i = frame // 4
            v = int(255 * 0.25)
            group = ([REGAL_LINK, DISPLAY1, REGAL_HINT] if flash_i % 2 == 0
                     else [REGAL_RECH, DISPLAY2, REGAL_HINT])
            for ch in group:
                put(dmx, ch, (v, v, v))

    # ============ 164.1 - 172s: bassless afterglow (under the laser) ====
    elif t < 172000:
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 4000.0))
        for ch in REGALE:
            put(dmx, ch, hsv(0.50, 1.0, 0.12 * breathe))
        put(dmx, DISPLAY1, hsv(0.75, 1.0, 0.15))
        put(dmx, DISPLAY2, hsv(0.75, 1.0, 0.15))

    # ============ 172 - 196.7s: final build — drifting beat comet =======
    elif t < 196700:
        sec = (t - 172000) / (196700 - 172000)
        hue = 0.60 + 0.27 * sec              # blue -> magenta drift
        bi = idx_of(BEATS, t)
        env = beat_env(t, 220)
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.28 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.10))
        if bi % 4 == 0:
            d = int(255 * 0.18 * env)
            put(dmx, DECKE, (d, d, d))

    # ============ 196.7 - 226.9s: FINAL HIGH — rotating comet wheel =====
    elif t < 226900:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 220)
        hue = (t / 30000.0) % 1.0            # slow full hue rotation
        head = CIRCLE[bi % 4]
        mid = CIRCLE[(bi - 1) % 4]
        tail = CIRCLE[(bi - 2) % 4]
        put_stop(dmx, head, hsv(hue, 1.0, 0.30 * (0.4 + 0.6 * env)))
        put_stop(dmx, mid, hsv(hue + 0.05, 1.0, 0.14))
        put_stop(dmx, tail, hsv(hue + 0.10, 1.0, 0.06))
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 6000.0 + math.pi))
        put(dmx, DECKE, hsv(hue + 0.5, 0.4, 0.15 * breathe))
        if bi % 16 == 0 and frame % 4 == 0:  # sparse all-flash accent
            v = int(255 * 0.32)
            for ch in ALL_LIGHTS:
                put(dmx, ch, (v, v, v))

    # ============ 226.9 - 229.3s: dip ===================================
    elif t < 229300:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.10))

    # ============ 229.3 - 258.3s: final 2 — ping-pong + ceiling ticks ===
    elif t < 258300:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 240)
        left, right = [REGAL_LINK, DISPLAY1], [REGAL_RECH, DISPLAY2]
        side = left if bi % 2 == 0 else right
        hue = 0.87 if bi % 2 == 0 else 0.50
        for ch in side:
            put(dmx, ch, hsv(hue, 1.0, 0.30 * env))
        put(dmx, REGAL_HINT, hsv(hue, 1.0, 0.12 * env))
        if bi % 2 == 0:
            d = int(255 * 0.12 * env)
            put(dmx, DECKE, (d, d, d))

    # ============ 258.3 - end: outro fade, ceiling dies last ============
    elif t < SONG_END_S * 1000:
        sec = clamp((t - 258300) / 2000.0)
        for ch in (DISPLAY1, DISPLAY2, *REGALE):
            put(dmx, ch, hsv(0.87, 1.0, 0.12 * (1 - sec)))
        put(dmx, DECKE, hsv(0.08, 0.5, 0.10 * (1 - sec) ** 0.5))

    # ---- fog cues ----
    if any(s <= t < e for s, e in FOG_CUES):
        dmx[FOG] = 255
    # ---- laser cues (plug powers LASER_LATENCY_MS before visibility) ----
    if any((vs - LASER_LATENCY_MS) <= t < ve for vs, ve in LASER_CUES):
        dmx[LASER] = 255
    return bytes(dmx)

# ---- engine ------------------------------------------------------------
def artnet(dmx, seq):
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

def main():
    start_s = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
    end_s = float(sys.argv[2]) if len(sys.argv) > 2 else SONG_END_S
    play_audio = os.path.exists(MP3)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    audio = None
    if play_audio:
        if start_s > 0 and shutil.which("ffplay"):
            audio = subprocess.Popen(["ffplay", "-nodisp", "-autoexit",
                                      "-loglevel", "quiet", "-ss", str(start_s), MP3])
        elif start_s == 0:
            audio = subprocess.Popen(["afplay", MP3])
        else:
            play_audio = False
    print(f"playing {start_s:.1f}s -> {end_s:.1f}s  |  audio={'yes' if play_audio else 'no'}  |  "
          f"{len(BEATS)} beats, {len(BARS)} bars", flush=True)

    seq = 0
    t0 = time.monotonic()
    try:
        while True:
            song_s = start_s + (time.monotonic() - t0)
            if song_s >= end_s:
                break
            song_ms = song_s * 1000.0 - (AUDIO_LATENCY_MS if play_audio else 0)
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(render(song_ms), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
    finally:
        for _ in range(3):
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(bytes(NCHAN), seq), ARTNET_TARGET)
            time.sleep(1.0 / FPS)
        if audio:
            audio.terminate()
    print("done", flush=True)

if __name__ == "__main__":
    main()
