#!/usr/bin/env python3
"""Headless show engine v2 — RUNS ON THE MAC.

Plays the song locally (afplay/ffplay) AND streams Art-Net to the bridge on
atlas (Hue + fog + laser). Full-song show, rebuilt after a multi-agent audit
+ pro-lighting research pass:

  - energy distribution fixed: drops & finale are now the brightest moments,
    the build is capped (was inverted)
  - much more of the tuned strobe (1 frame on / 3 off): double-flash drops,
    strobe bars inside drop 2, strobe bursts + full-strobe climax in the
    finale, strobe accents in choruses
  - becalmed sine-breathing sections replaced with dark-but-moving patterns
  - the beloved 64.7s magenta chase style cloned across choruses
  - Display treated as ONE fixture (both Play bars sit together physically)
  - pro patterns: double-flash on the kick, swop (others black during a
    flash), complementary color pairs with beat-swap, accelerating build
    roll, white reserved for hits, 8-bar mutation rule
  - bug fixes: pre-roll clamp, absolute frame scheduling (no dropped
    flashes), single-frame accents actually single-frame, bisect beat scans

Sections follow the measured structure of music.mp3 (260.3s, ~136 BPM).
Fog: 42-52, 112-118, 151-159, 197-204. Laser: 59.7-72, 159.2-175, 222-245.

Usage:  python3 show.py [start_s] [end_s]
"""
import bisect, colorsys, math, re, shutil, socket, struct, subprocess, sys, time, os

BASE = os.path.dirname(os.path.abspath(__file__))
XSQ = os.path.join(BASE, "music.xsq")
MP3 = os.path.join(BASE, "music.mp3")
ARTNET_TARGET = ("192.168.1.100", 6454)
FPS = 25
NCHAN = 20
SONG_END_S = 260.4
AUDIO_LATENCY_MS = 160
LASER_LATENCY_MS = 3900

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH, FOG, LASER = 0, 3, 6, 9, 12, 15, 18, 19
DISPLAY = [DISPLAY1, DISPLAY2]          # one physical spot (both Play bars together)
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]
ALL_LIGHTS = [DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]
STROBE_CH = [DISPLAY1, DISPLAY2, REGAL_HINT, REGAL_LINK, REGAL_RECH]
CIRCLE = [[REGAL_HINT], [REGAL_LINK], DISPLAY, [REGAL_RECH]]

FOG_CUES = [(42000, 52000), (112000, 118000), (151000, 159000), (197000, 204000)]
LASER_CUES = [(59700, 72000), (159200, 175000), (222000, 245000)]

BEAT_MS = 441.0
EIGHTH = BEAT_MS / 2

# ---- timing tracks from xLights ----------------------------------------
def load_track(name):
    s = open(XSQ).read()
    m = re.search(r'<Element type="timing" name="' + name + r'">(.*?)</Element>', s, re.S)
    return sorted(set(int(x) for x in re.findall(r'startTime="(\d+)"', m.group(1)))) if m else []

BEATS = load_track("Beats")
BARS = load_track("Bars") or BEATS[::4]

def last_of(track, t):
    i = bisect.bisect_right(track, t)
    return track[i - 1] if i else None

def idx_of(track, t):
    return bisect.bisect_right(track, t)

def since_beat(t):
    b = last_of(BEATS, t)
    return (t - b) if b is not None else 1e9

def beat_env(t, decay=250.0):
    s = since_beat(t)
    return math.exp(-s / decay) if s < 1e8 else 0.0

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

def black(dmx):
    for ch in ALL_LIGHTS:
        put(dmx, ch, (0, 0, 0))

# ---- pro strobe building blocks ----------------------------------------
def tuned_strobe(dmx, t, v=0.22, chans=STROBE_CH, ceiling=0.0):
    """1 frame on / 3 off, white. Swop: everything else forced black."""
    if int(t // 40) % 4 == 0:
        black(dmx)
        val = int(255 * v)
        for ch in chans:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

def double_flash(dmx, t, v=0.25, chans=STROBE_CH, ceiling=0.15):
    """Pro kick pattern: flash at beat+0 and beat+80ms, long dark after."""
    s = since_beat(t)
    if s < 40 or 80 <= s < 120:
        black(dmx)
        val = int(255 * v)
        for ch in chans:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

def drop_hit(dmx, t, t_hit, v=0.32):
    """Full-rig white for the first 2 frames of a drop entrance."""
    if t_hit <= t < t_hit + 80:
        val = int(255 * v)
        for ch in ALL_LIGHTS:
            put(dmx, ch, (val, val, val))
        return True
    return False

# ---- the SHOW ----------------------------------------------------------
def render(t):
    dmx = bytearray(NCHAN)
    if t < 0:
        return bytes(dmx)                # pre-roll: stay dark (bug fix)

    # ============ 0 - 18.6s: intro ramp (approved) ======================
    if t < 18600:
        frac = clamp(t / 18600)
        bright = 0.50 * frac
        rgb = (int(255 * (1 - frac) * bright), int(255 * (1 - frac) * bright), int(255 * bright))
        for ch in REGALE:
            put(dmx, ch, rgb)
        s = since_beat(t)
        bump = 0.5 * (1 + math.cos(math.pi * s / 220.0)) if s < 220.0 else 0.0
        d = int(255 * 0.28 * bump)
        put(dmx, DECKE, (d, d, d))

    # ============ 18.6 - 40s: dark room circle (escalates at 30s) =======
    elif t < 40000:
        sec = (t - 18600) / (40000 - 18600)
        hue = 0.63 + 0.09 * sec
        track = BARS if t < 30000 else BEATS          # bar-step -> beat-step
        decay = 900.0 if t < 30000 else 300.0
        bi = idx_of(track, t)
        b = last_of(track, t)
        env = math.exp(-(t - b) / decay) if b is not None else 0.0
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.22 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.08))
        d = int(255 * 0.10 * beat_env(t, 200))
        put(dmx, DECKE, (d, d, d))

    # ============ 40 - 58s: build v2 — capped, accelerating =============
    elif t < 53000:                                    # phase 1: rainbow pulse (capped)
        env = beat_env(t, 250)
        bright = 0.16 + 0.24 * env                     # cap 0.40: drops must stay the peak
        bi = idx_of(BEATS, t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0, bright))
    elif t < 56500:                                    # phase 2: 8th-note roll, desaturating
        sub = since_beat(t) % EIGHTH
        env = math.exp(-sub / 100.0)
        ramp = (t - 53000) / 3500.0
        bi = idx_of(BEATS, t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0 - 0.3 * ramp, 0.42 * env))
    elif t < 58000:                                    # phase 3: narrow to ceiling, accelerating white
        p = (t - 56500) / 1500.0
        per = 220.0 - 140.0 * p                        # flash period 220 -> 80ms
        if int(t // per) % 2 == 0:
            d = int(255 * 0.35)
            put(dmx, DECKE, (d, d, d))
        fade = 0.12 * (1 - p)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 0.7, fade))

    # ============ 58 - 59.7s: BLACKOUT ==================================
    elif t < 59700:
        pass

    # ============ 59.7 - 64.7s: DROP 1 — hit + double-flash strobe ======
    elif t < 64700:
        if not drop_hit(dmx, t, 59700):
            double_flash(dmx, t, v=0.25, ceiling=0.15)

    # ============ 64.7 - 74.2s: the beloved magenta beat-chase ==========
    elif t < 74200:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 220)
        for k, stop in enumerate(CIRCLE):
            if k == bi % 4:
                put_stop(dmx, stop, hsv(0.87, 1.0, 0.30 * (0.3 + 0.7 * env)))
            else:
                put_stop(dmx, stop, hsv(0.63, 1.0, 0.05))

    # ============ 74.2 - 86.9s: chorus — true L/R ping-pong v2 ==========
    elif t < 86900:
        bi = idx_of(BEATS, t)
        bar = idx_of(BARS, t)
        if bar % 8 == 0:                               # strobe accent bar (1 of 8)
            tuned_strobe(dmx, t, v=0.24)
        else:
            env = beat_env(t, 260)
            s = since_beat(t)
            hue = 0.63 if bi % 4 < 2 else 0.87
            side = REGAL_LINK if bi % 2 == 0 else REGAL_RECH
            put(dmx, side, hsv(hue, 1.0, 0.32 * env))
            put(dmx, REGAL_HINT, hsv(hue, 1.0, 0.28 * env))      # full member now
            if 200 <= s < 320:                          # Display fires on the offbeat "and"
                put_stop(dmx, DISPLAY, hsv((hue + 0.5) % 1.0, 1.0, 0.26))
            if bi % 4 == 0:
                d = int(255 * 0.20 * env)
                put(dmx, DECKE, (d, d, d))

    # ============ 86.9 - 89s: dip =======================================
    elif t < 89000:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.08))

    # ============ 89 - 95s: comet, cyan/magenta alternating head ========
    elif t < 95000:
        bi = idx_of(BEATS, t)
        bar = idx_of(BARS, t)
        env = beat_env(t, 180)
        hue = 0.50 if bar % 2 == 0 else 0.87
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.32 * (0.4 + 0.6 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.10))

    # ============ 95 - 102s: wind down (musically motivated) ============
    elif t < 102000:
        sec = (t - 95000) / 7000.0
        put_stop(dmx, DISPLAY, hsv(0.75, 1.0, 0.15))
        fade = 0.15 * (1 - sec)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, fade))
        breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 8000.0))
        put(dmx, DECKE, hsv(0.08, 0.6, 0.10 * breathe))

    # ============ 102 - 110s: dark red ticks walking the room ===========
    elif t < 110000:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 120)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.0, 1.0, 0.08 * env))
        put(dmx, DECKE, hsv(0.08, 0.7, 0.10 * beat_env(t, 200)))

    # ============ 110 - 118s: rebuild, double-time at the end ===========
    elif t < 118000:
        sec = (t - 110000) / 8000.0
        if t < 114500:
            bi = idx_of(BEATS, t)
        else:                                          # double-time (8th steps)
            bi = int(t // EIGHTH)
        env = beat_env(t, 220)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.63, 1.0, (0.12 + 0.14 * sec) * (0.4 + 0.6 * env)))

    # ============ 118 - 118.4s: blackout — mark drop 2 ==================
    elif t < 118400:
        pass

    # ============ 118.4 - 131s: DROP 2 — slam bars + strobe bars ========
    elif t < 131000:
        if not drop_hit(dmx, t, 118400):
            bar = idx_of(BARS, t)
            if bar % 3 == 2:                           # every 3rd bar: tuned strobe
                tuned_strobe(dmx, t, v=0.24, ceiling=0.12)
            else:                                      # slam bars, color alternates per beat
                bi = idx_of(BEATS, t)
                env = beat_env(t, 150)
                hue = 0.87 if bi % 2 == 0 else 0.50
                for k, stop in enumerate(CIRCLE):
                    if k == bi % 4:
                        put_stop(dmx, stop, hsv(hue, 1.0, 0.38 * env))
                    else:
                        put_stop(dmx, stop, hsv(0.63, 1.0, 0.05))
                if bi % 8 == 0:
                    d = int(255 * 0.25 * env)
                    put(dmx, DECKE, (d, d, d))

    # ============ 131 - 132.3s: collapse ================================
    elif t < 132300:
        sec = (t - 131000) / 1300.0
        v = 0.10 * (1 - sec)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, v))

    # ============ 132.3 - 135.4s: QUIET — heartbeat =====================
    elif t < 135400:
        pulse = math.exp(-((t - 132300) % 2000) / 180.0)
        put_stop(dmx, DISPLAY, hsv(0.0, 1.0, 0.06 * pulse))

    # ============ 135.4 - 150s: bridge — mirrored crossing ==============
    elif t < 150000:
        bi = idx_of(BEATS, t)
        env = beat_env(t, 300)
        A, B = [REGAL_HINT, REGAL_RECH], [REGAL_LINK] + DISPLAY
        act, idle = (A, B) if bi % 2 == 0 else (B, A)
        hue_a, hue_b = 0.75, 0.50                      # purple x cyan crossing
        for ch in act:
            put(dmx, ch, hsv(hue_a if bi % 2 == 0 else hue_b, 1.0, 0.22 * (0.3 + 0.7 * env)))
        for ch in idle:
            put(dmx, ch, hsv(hue_b if bi % 2 == 0 else hue_a, 1.0, 0.06))
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

    # ============ 159.2 - 164.1s: DROP 3 — hit + ping-pong strobe =======
    elif t < 164100:
        if not drop_hit(dmx, t, 159200):
            frame = int(t // 40)
            if frame % 4 == 0:
                flash_i = frame // 4
                v = int(255 * 0.25)
                group = ([REGAL_LINK, REGAL_HINT] + DISPLAY if flash_i % 2 == 0
                         else [REGAL_RECH, REGAL_HINT] + DISPLAY)
                for ch in group:
                    put(dmx, ch, (v, v, v))
                d = int(255 * 0.12)
                put(dmx, DECKE, (d, d, d))

    # ============ 164.1 - 172s: afterglow — L/R cross-fade (moving) =====
    elif t < 172000:
        ph = 2 * math.pi * t / 3000.0
        lv = 0.12 * (0.5 + 0.5 * math.sin(ph))
        rv = 0.12 * (0.5 + 0.5 * math.sin(ph + math.pi))
        put(dmx, REGAL_LINK, hsv(0.50, 1.0, lv))
        put(dmx, REGAL_RECH, hsv(0.50, 1.0, rv))
        put(dmx, REGAL_HINT, hsv(0.55, 1.0, 0.5 * (lv + rv)))
        put_stop(dmx, DISPLAY, hsv(0.75, 1.0, 0.13))

    # ============ 172 - 196.5s: final build — 3 escalating phases =======
    elif t < 196500:
        sec = (t - 172000) / (196500 - 172000)
        hue = 0.60 + 0.27 * sec
        if t < 180000:                                 # p1: beat comet
            bi = idx_of(BEATS, t)
            env = beat_env(t, 220)
            put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.28 * (0.35 + 0.65 * env)))
            put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.10))
        elif t < 188000:                               # p2: + ceiling pops, brighter
            bi = idx_of(BEATS, t)
            env = beat_env(t, 200)
            put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.32 * (0.35 + 0.65 * env)))
            put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.12))
            if bi % 2 == 0:
                d = int(255 * 0.18 * env)
                put(dmx, DECKE, (d, d, d))
        else:                                          # p3: double-time + strobe pre-accents
            bar = idx_of(BARS, t)
            if bar % 2 == 0 and t >= 192000:
                tuned_strobe(dmx, t, v=0.22)
            else:
                bi = int(t // EIGHTH)
                sub = since_beat(t) % EIGHTH
                env = math.exp(-sub / 100.0)
                put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.34 * (0.4 + 0.6 * env)))
                put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.12))

    # ============ 196.5 - 196.7s: 3-frame blackout ======================
    elif t < 196700:
        pass

    # ============ 196.7 - 226.9s: FINAL HIGH — the actual peak ==========
    elif t < 226900:
        if drop_hit(dmx, t, 196700, v=0.35):
            pass
        elif t >= 222000:                              # climax: full strobe under the laser
            tuned_strobe(dmx, t, v=0.26, ceiling=0.15)
        else:
            bar = idx_of(BARS, t)
            bi = idx_of(BEATS, t)
            hue = (0.87 + (t - 196700) / 30000.0) % 1.0    # continuous from the build
            if bar % 8 in (6, 7):                      # 2 strobe bars every 8
                tuned_strobe(dmx, t, v=0.24)
            else:
                env = beat_env(t, 220)
                head, mid, tail = CIRCLE[bi % 4], CIRCLE[(bi - 1) % 4], CIRCLE[(bi - 2) % 4]
                put_stop(dmx, head, hsv(hue, 1.0, 0.38 * (0.4 + 0.6 * env)))
                put_stop(dmx, mid, hsv(hue + 0.05, 1.0, 0.15))
                put_stop(dmx, tail, hsv(hue + 0.10, 1.0, 0.06))
                if bi % 8 == 0 and since_beat(t) < 40:  # true single-frame all-flash
                    v = int(255 * 0.35)
                    for ch in ALL_LIGHTS:
                        put(dmx, ch, (v, v, v))
                breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 6000.0 + math.pi))
                put(dmx, DECKE, hsv(hue + 0.5, 0.4, 0.14 * breathe))

    # ============ 226.9 - 229.3s: dip ===================================
    elif t < 229300:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.10))

    # ============ 229.3 - 258.3s: final 2 — de-metronomed ===============
    elif t < 258300:
        bi = idx_of(BEATS, t)
        bar = idx_of(BARS, t)
        if 243000 <= t < 245000:                       # strobe farewell under laser tail
            tuned_strobe(dmx, t, v=0.24)
        elif bar % 8 == 7:                             # every 8th bar: full-circle sweep
            k = int(t // EIGHTH)
            put_stop(dmx, CIRCLE[k % 4], hsv(0.87, 1.0, 0.30))
            put_stop(dmx, CIRCLE[(k - 1) % 4], hsv(0.50, 1.0, 0.10))
        else:
            env = beat_env(t, 240)
            s = since_beat(t)
            palette = [0.87, 0.50, 0.62, 0.75]
            hue = palette[(bi // 3) % 4]               # hue decoupled from side
            side = REGAL_LINK if bi % 2 == 0 else REGAL_RECH
            put(dmx, side, hsv(hue, 1.0, 0.32 * env))
            if 200 <= s < 320:                         # front pivot on the offbeat
                put(dmx, REGAL_HINT, hsv((hue + 0.5) % 1.0, 1.0, 0.25))
            if bi % 4 == 0:
                put_stop(dmx, DISPLAY, hsv(hue, 1.0, 0.30 * env))
            b = last_of(BARS, t)
            if b is not None and t - b < 200:
                d = int(255 * 0.15)
                put(dmx, DECKE, (d, d, d))

    # ============ 258.3 - end: outro, ceiling dies last =================
    elif t < SONG_END_S * 1000:
        sec = clamp((t - 258300) / 2000.0)
        for ch in (*DISPLAY, *REGALE):
            put(dmx, ch, hsv(0.87, 1.0, 0.12 * (1 - sec)))
        put(dmx, DECKE, hsv(0.08, 0.5, 0.10 * (1 - sec) ** 0.5))

    # ---- fog / laser cues ----
    if any(s <= t < e for s, e in FOG_CUES):
        dmx[FOG] = 255
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
    next_t = t0
    try:
        while True:
            song_s = start_s + (time.monotonic() - t0)
            if song_s >= end_s:
                break
            song_ms = song_s * 1000.0 - (AUDIO_LATENCY_MS if play_audio else 0)
            seq = (seq + 1) & 0xff
            sock.sendto(artnet(render(song_ms), seq), ARTNET_TARGET)
            next_t += 1.0 / FPS                       # absolute schedule: no frame drift
            time.sleep(max(0.0, next_t - time.monotonic()))
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
