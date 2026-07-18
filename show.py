#!/usr/bin/env python3
"""Headless show engine v3 — RUNS ON THE MAC.

Plays the song locally AND streams Art-Net to the bridge on atlas
(Hue + fog/disco + laser + hardware strobe).

v3 = full MIR rebuild (two librosa agents + own kick-lattice verification):
  - TRUE tempo 130.00 BPM. Beat lattice anchored on the measured drop-1
    groove kick at 59.700s hits every other drop <25ms (118.30 / 158.92 /
    196.28 / 229.06). The old xLights beat track (136 BPM, irregular) is gone.
  - All section boundaries moved to measured musical events.
  - Drop 3 (158.92) is the TRACK PEAK (max RMS + max sub-bass) right after
    the only clean silence -> hardware strobe solo (the money cue).
  - Chorus 74.0-87.2 is the rhythmically densest music (rank 1 onsets)
    and Finale2 229.1+ is rank 2 -> both upgraded.
  - Single-frame accents on the strongest measured impacts.
  - Fog (disco globe!) only in lit phases; laser + hardware strobe with
    warm-up pre-power (3.9s / 6.5s).

Usage:  python3 show.py [start_s] [end_s]
"""
import colorsys, math, os, shutil, socket, struct, subprocess, sys, time

BASE = os.path.dirname(os.path.abspath(__file__))
MP3 = os.path.join(BASE, "music.mp3")
ARTNET_TARGET = ("192.168.1.100", 6454)
FPS = 25
NCHAN = 21
SONG_END_S = 260.4
AUDIO_LATENCY_MS = 160          # Bluetooth; validated by ear against drop 1
LASER_LATENCY_MS = 3900
STROBEPLUG_LATENCY_MS = 6500

# ---- channel map (0-based DMX index) -----------------------------------
DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH, FOG, LASER, STROBE_PLUG = 0, 3, 6, 9, 12, 15, 18, 19, 20
DISPLAY = [DISPLAY1, DISPLAY2]
REGALE = [REGAL_HINT, REGAL_LINK, REGAL_RECH]
ALL_LIGHTS = [DECKE, DISPLAY1, REGAL_HINT, REGAL_LINK, DISPLAY2, REGAL_RECH]
STROBE_CH = [DISPLAY1, DISPLAY2, REGAL_HINT, REGAL_LINK, REGAL_RECH]
CIRCLE = [[REGAL_HINT], [REGAL_LINK], DISPLAY, [REGAL_RECH]]

# ---- the 130.00 BPM lattice (measured; anchor = drop-1 groove kick) ----
BEAT = 60000.0 / 130.0          # 461.538 ms
EIGHTH = BEAT / 2
ANCHOR = 59700.0                # ms

def bphase(t):                  # ms since the last lattice beat
    return (t - ANCHOR) % BEAT

def beat_idx(t):
    return int((t - ANCHOR) // BEAT)

def beat_env(t, decay=250.0):
    return math.exp(-bphase(t) / decay)

def near_beat_dt(t):            # distance to the NEAREST beat (for cos bumps)
    p = bphase(t)
    return min(p, BEAT - p)

def sec_bar(t, anchor):         # section-local bar index (bar = 4 beats)
    return int((t - anchor) // (4 * BEAT))

# ---- cues ---------------------------------------------------------------
# fog carries a DISCO GLOBE -> only in lit phases, never in darkness
FOG_CUES = [(42000, 52000),      # build 1 (lit) — haze for the drop-1 laser
            (118300, 124300),    # drop 2 (bright slams)
            (158920, 165000),    # drop 3 — hardware strobe lights the globe
            (196300, 203300),    # final high (lit)
            (229500, 234000)]    # finale 2 (lit, densest sub groove)
LASER_CUES = [(59700, 72420), (158920, 175000), (220700, 245000)]
STROBEPLUG_CUES = [(158920, 164400), (224700, 227200)]

# strongest measured impacts -> single-frame white overlays (time_ms, strength)
ACCENTS = [(2910, .26), (4760, .26), (5460, .22), (6610, .26), (7300, .22),
           (11910, .22), (75840, .30), (78380, .30), (79530, .30),
           (87880, .30), (136770, .28), (226070, .40),
           (232280, .35), (235970, .35), (250300, .35)]

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

# ---- pro strobe blocks --------------------------------------------------
def tuned_strobe(dmx, t, v=0.22, chans=STROBE_CH, ceiling=0.0):
    """1 frame on / 3 off, white; swop: everything else black."""
    if int(t // 40) % 4 == 0:
        black(dmx)
        val = int(255 * v)
        for ch in chans:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

def double_flash(dmx, t, v=0.25, ceiling=0.15):
    """Kick pattern: flash at beat+0 and beat+80ms, long dark after."""
    p = bphase(t)
    if p < 40 or 80 <= p < 120:
        black(dmx)
        val = int(255 * v)
        for ch in STROBE_CH:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

def drop_hit(dmx, t, t_hit, v=0.42):
    if t_hit <= t < t_hit + 80:
        val = int(255 * v)
        for ch in ALL_LIGHTS:
            put(dmx, ch, (val, val, val))
        return True
    return False

# ---- the SHOW (all boundaries = measured events) ------------------------
def render(t):
    dmx = bytearray(NCHAN)
    if t < 0:
        return bytes(dmx)

    # ===== 0 - 18.2: intro ramp (approved) — sharpest transients get accents
    if t < 18200:
        frac = clamp(t / 18200)
        bright = 0.50 * frac
        rgb = (int(255 * (1 - frac) * bright), int(255 * (1 - frac) * bright), int(255 * bright))
        for ch in REGALE:
            put(dmx, ch, rgb)
        dt = near_beat_dt(t)
        bump = 0.5 * (1 + math.cos(math.pi * dt / 220.0)) if dt < 220.0 else 0.0
        d = int(255 * 0.28 * bump)
        put(dmx, DECKE, (d, d, d))

    # ===== 18.2 - 40: dark room circle (escalates at 29) =================
    elif t < 40000:
        sec = (t - 18200) / (40000 - 18200)
        hue = 0.63 + 0.09 * sec
        if t < 29000:
            bi = sec_bar(t, 18200)
            env = math.exp(-((t - 18200) % (4 * BEAT)) / 900.0)
        else:
            bi = beat_idx(t)
            env = beat_env(t, 300)
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.22 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.08))
        d = int(255 * 0.10 * beat_env(t, 200))
        put(dmx, DECKE, (d, d, d))

    # ===== 40 - 49.35: build p1 — capped rainbow pulse ===================
    elif t < 49350:
        env = beat_env(t, 250)
        bright = 0.16 + 0.24 * env
        bi = beat_idx(t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0, bright))

    # ===== 49.35 - 56.2: build p2 — 8th roll from the acceleration point =
    elif t < 56200:
        sub = bphase(t) % EIGHTH
        env = math.exp(-sub / 100.0)
        ramp = (t - 49350) / 6850.0
        bi = beat_idx(t)
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0 - 0.3 * ramp, 0.40 * env))

    # ===== 56.2 - 57.1: terminal roll — ceiling only, riser dies at 57.1 =
    elif t < 57100:
        p = (t - 56200) / 900.0
        per = 230.0 - 140.0 * p
        if int(t // per) % 2 == 0:
            d = int(255 * 0.35)
            put(dmx, DECKE, (d, d, d))
        fade = 0.10 * (1 - p)
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 0.7, fade))

    # ===== 57.1 - 59.7: BLACKOUT (bass gone) + dim pre-boom at 59.22 =====
    elif t < 59700:
        if 59220 <= t < 59300:
            for ch in ALL_LIGHTS:
                put(dmx, ch, hsv(0.63, 1.0, 0.08))

    # ===== 59.7: DROP 1 — hit + double-flash; bass gap 66.15-66.70 dark ==
    elif t < 72420:
        if not drop_hit(dmx, t, 59700):
            if 66150 <= t < 66700:
                pass                                  # measured bass gap = darkness accent
            else:
                double_flash(dmx, t, v=0.25, ceiling=0.15)

    # ===== 72.42 - 74.0: fill — dim magenta handoff ======================
    elif t < 74000:
        env = beat_env(t, 250)
        for ch in REGALE:
            put(dmx, ch, hsv(0.87, 1.0, 0.10 * env))

    # ===== 74.0 - 87.19: CHORUS — rhythmically densest music of the track
    elif t < 87190:
        bi = beat_idx(t)
        bar = sec_bar(t, 74000)
        if bar % 8 == 0:
            tuned_strobe(dmx, t, v=0.24)
        else:
            env = beat_env(t, 260)
            p = bphase(t)
            hue = 0.63 if bi % 4 < 2 else 0.87
            side = REGAL_LINK if bi % 2 == 0 else REGAL_RECH
            put(dmx, side, hsv(hue, 1.0, 0.34 * env))
            put(dmx, REGAL_HINT, hsv(hue, 1.0, 0.30 * env))
            if 200 <= p < 320:
                put_stop(dmx, DISPLAY, hsv((hue + 0.5) % 1.0, 1.0, 0.28))
            if bi % 4 == 0:
                d = int(255 * 0.20 * env)
                put(dmx, DECKE, (d, d, d))

    # ===== 87.19 - 88.76: dip (bass silent; snare accent handled below) ==
    elif t < 88760:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.06))

    # ===== 88.76 - 94.58: comet — 2nd loudest section, brightened ========
    elif t < 94580:
        bi = beat_idx(t)
        bar = sec_bar(t, 88760)
        env = beat_env(t, 180)
        hue = 0.50 if bar % 2 == 0 else 0.87
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.36 * (0.4 + 0.6 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.12))

    # ===== 94.58 - 101.49: chorus var C — STAYS at chorus energy =========
    elif t < 101490:
        bi = beat_idx(t)
        env = beat_env(t, 260)
        hue = 0.75 if bi % 4 < 2 else 0.50
        side = REGAL_LINK if bi % 2 == 0 else REGAL_RECH
        put(dmx, side, hsv(hue, 1.0, 0.30 * env))
        put(dmx, REGAL_HINT, hsv(hue, 1.0, 0.24 * env))
        p = bphase(t)
        if 200 <= p < 320:
            put_stop(dmx, DISPLAY, hsv((hue + 0.5) % 1.0, 1.0, 0.22))

    # ===== 101.49 - 102.13: fill — fast fade =============================
    elif t < 102130:
        sec = (t - 101490) / 640.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.15 * (1 - sec)))

    # ===== 102.13 - 118.3: verse 2 — dark red ticks walk the room ========
    elif t < 118300:
        bi = beat_idx(t)
        env = beat_env(t, 120)
        ramp = clamp((t - 112000) / 6300.0) if t > 112000 else 0.0
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.0, 1.0, (0.08 + 0.06 * ramp) * env))
        put(dmx, DECKE, hsv(0.08, 0.7, 0.10 * beat_env(t, 200)))

    # ===== 118.3: DROP 2 — cold drop: sustained slams, sparse strobe =====
    elif t < 131960:
        if not drop_hit(dmx, t, 118300):
            bar = sec_bar(t, 118300)
            if bar % 4 == 3:                          # every 4th bar: tuned strobe
                tuned_strobe(dmx, t, v=0.24, ceiling=0.12)
            else:
                bi = beat_idx(t)
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

    # ===== 131.96 - 132.26: collapse =====================================
    elif t < 132260:
        sec = (t - 131960) / 300.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.10 * (1 - sec)))

    # ===== 132.26 - 134.87: breakdown silence — heartbeat ================
    elif t < 134870:
        pulse = math.exp(-((t - 132260) % 2000) / 180.0)
        put_stop(dmx, DISPLAY, hsv(0.0, 1.0, 0.06 * pulse))

    # ===== 134.87 - 135.86: music creeps back ============================
    elif t < 135860:
        sec = (t - 134870) / 990.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.75, 1.0, 0.06 * sec))

    # ===== 135.86 - 151.09: DROP REPRISE (user: "grosser Drop ~2:18") ====
    # Same cluster as drop 1A per segmentation; bass slams back at 136.77.
    elif t < 151090:
        if not drop_hit(dmx, t, 136770, v=0.38):
            bi = beat_idx(t)
            bar = sec_bar(t, 136770)
            env = beat_env(t, 220)
            if bar % 8 == 4:                          # strobe bar for punch
                tuned_strobe(dmx, t, v=0.22)
            else:
                A, B = [REGAL_HINT, REGAL_RECH], [REGAL_LINK] + DISPLAY
                act, idle = (A, B) if bi % 2 == 0 else (B, A)
                for ch in act:
                    put(dmx, ch, hsv(0.75 if bi % 2 == 0 else 0.50, 1.0, 0.32 * (0.3 + 0.7 * env)))
                for ch in idle:
                    put(dmx, ch, hsv(0.50 if bi % 2 == 0 else 0.75, 1.0, 0.08))
                if bi % 4 == 0:
                    d = int(255 * 0.18 * env)
                    put(dmx, DECKE, (d, d, d))

    # ===== 151.09 - 157.15: wind down ====================================
    elif t < 157150:
        sec = (t - 151090) / 6060.0
        gain = 1.0 - 0.85 * sec
        bar = sec_bar(t, 151090)
        put_stop(dmx, CIRCLE[bar % 4], hsv(0.75, 1.0, 0.15 * gain))

    # ===== 157.15 - 158.92: BLACKOUT (the only clean silence lives here) =
    elif t < 158920:
        pass

    # ===== 158.92: DROP 3 = TRACK PEAK — HARDWARE STROBE SOLO ============
    elif t < 164400:
        drop_hit(dmx, t, 158920)                      # 2-frame hit, then the room
        # belongs to the hardware strobe (ch21) + fog/disco

    # ===== 164.4 - 166.39: step-down fill ================================
    elif t < 166390:
        sec = (t - 164400) / 1990.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.50, 1.0, 0.10 * sec))

    # ===== 166.39 - 173.7: kickless bridge — L/R cross-fade under laser ==
    elif t < 173700:
        ph = 2 * math.pi * t / 3000.0
        lv = 0.12 * (0.5 + 0.5 * math.sin(ph))
        rv = 0.12 * (0.5 + 0.5 * math.sin(ph + math.pi))
        put(dmx, REGAL_LINK, hsv(0.50, 1.0, lv))
        put(dmx, REGAL_RECH, hsv(0.50, 1.0, rv))
        put(dmx, REGAL_HINT, hsv(0.55, 1.0, 0.5 * (lv + rv)))
        put_stop(dmx, DISPLAY, hsv(0.75, 1.0, 0.13))

    # ===== 173.7 - 181.09: groove reprise (bass re-entry accent below) ===
    elif t < 181090:
        bi = beat_idx(t)
        env = beat_env(t, 220)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.62, 1.0, 0.28 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(0.62, 1.0, 0.10))

    # ===== 181.09 - 196.0: FINAL BUILD — the track's biggest riser =======
    elif t < 196000:
        sec = (t - 181090) / (196000 - 181090)
        hue = 0.62 + 0.25 * sec
        if t < 185250:                                # p1: beat comet
            bi = beat_idx(t)
            env = beat_env(t, 220)
            put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.28 * (0.35 + 0.65 * env)))
            put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.10))
        elif t < 189600:                              # p2: acceleration point
            bi = int((t - ANCHOR) // EIGHTH)
            sub = bphase(t) % EIGHTH
            env = math.exp(-sub / 100.0)
            put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, 0.30 * (0.4 + 0.6 * env)))
            if beat_idx(t) % 2 == 0:
                d = int(255 * 0.16 * beat_env(t, 180))
                put(dmx, DECKE, (d, d, d))
        else:                                         # p3: noise-riser surge -> white
            bar = sec_bar(t, 189600)
            if t >= 193200 and bar % 2 == 1:
                tuned_strobe(dmx, t, v=0.22)
            else:
                bi = int((t - ANCHOR) // EIGHTH)
                sub = bphase(t) % EIGHTH
                env = math.exp(-sub / 90.0)
                desat = clamp((t - 189600) / 6400.0)
                floor = 0.15 + 0.15 * desat
                put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0 - 0.6 * desat, floor + 0.20 * env))
                put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0 - 0.6 * desat, 0.12))

    # ===== 196.0 - 196.28: blackout (measured bass cut) ==================
    elif t < 196280:
        pass

    # ===== 196.28: FINAL HIGH -> 227.2 ===================================
    elif t < 227200:
        if drop_hit(dmx, t, 196280):
            pass
        elif t >= 224700:                             # climax: Hue + hardware strobe
            tuned_strobe(dmx, t, v=0.26, ceiling=0.15)
        else:
            bar = sec_bar(t, 195820)                  # true downbeat (Beat This): hit is beat 2
            bi = beat_idx(t)
            hue = (0.87 + (t - 196280) / 30000.0) % 1.0
            boost = 1.2 if t >= 217800 else 1.0       # measured escalation point
            if bar % 8 in (6, 7):
                tuned_strobe(dmx, t, v=0.24)
            else:
                env = beat_env(t, 220)
                step = int((t - ANCHOR) // (EIGHTH if t >= 217800 else BEAT))
                head, mid, tail = CIRCLE[step % 4], CIRCLE[(step - 1) % 4], CIRCLE[(step - 2) % 4]
                put_stop(dmx, head, hsv(hue, 1.0, 0.38 * boost * (0.4 + 0.6 * env)))
                put_stop(dmx, mid, hsv(hue + 0.05, 1.0, 0.15 * boost))
                put_stop(dmx, tail, hsv(hue + 0.10, 1.0, 0.06))
                if bi % 8 == 0 and bphase(t) < 40:
                    v = int(255 * 0.35)
                    for ch in ALL_LIGHTS:
                        put(dmx, ch, (v, v, v))
                breathe = 0.5 * (1 + math.sin(2 * math.pi * t / 6000.0 + math.pi))
                put(dmx, DECKE, hsv(hue + 0.5, 0.4, 0.14 * breathe))

    # ===== 227.2 - 229.06: breakdown fill (bass silent) ==================
    elif t < 229060:
        bi = beat_idx(t)
        env = beat_env(t, 150)
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.63, 1.0, 0.07 * env))

    # ===== 229.06: FINALE 2 — rank-2 rhythmic intensity, upgraded ========
    elif t < 258650:
        if drop_hit(dmx, t, 229060):
            pass
        elif 243000 <= t < 245000:                    # strobe farewell under laser
            tuned_strobe(dmx, t, v=0.24)
        else:
            bi = beat_idx(t)
            bar = sec_bar(t, 229060)
            if bar % 8 == 7:                          # full-circle sweep bar
                k = int((t - ANCHOR) // EIGHTH)
                put_stop(dmx, CIRCLE[k % 4], hsv(0.87, 1.0, 0.32))
                put_stop(dmx, CIRCLE[(k - 1) % 4], hsv(0.50, 1.0, 0.10))
            else:
                env = beat_env(t, 240)
                p = bphase(t)
                palette = [0.87, 0.50, 0.62, 0.75]
                hue = palette[(bi // 3) % 4]
                side = REGAL_LINK if bi % 2 == 0 else REGAL_RECH
                put(dmx, side, hsv(hue, 1.0, 0.34 * env))
                if 200 <= p < 320:
                    put(dmx, REGAL_HINT, hsv((hue + 0.5) % 1.0, 1.0, 0.26))
                if bi % 4 == 0:
                    put_stop(dmx, DISPLAY, hsv(hue, 1.0, 0.32 * env))
                if bphase(t) < 200 and sec_bar(t, 229060) != sec_bar(t - 4 * BEAT, 229060):
                    pass
                b0 = (t - 229060) % (4 * BEAT)
                if b0 < 200:
                    d = int(255 * 0.15)
                    put(dmx, DECKE, (d, d, d))

    # ===== 258.65 - end: outro fade, ceiling dies last ===================
    elif t < SONG_END_S * 1000:
        sec = clamp((t - 258650) / 1700.0)
        for ch in (*DISPLAY, *REGALE):
            put(dmx, ch, hsv(0.87, 1.0, 0.12 * (1 - sec)))
        put(dmx, DECKE, hsv(0.08, 0.5, 0.10 * (1 - sec) ** 0.5))

    # ---- measured-impact single-frame accents ---------------------------
    for imp, strength in ACCENTS:
        if imp <= t < imp + 40:
            v = int(255 * strength)
            for ch in STROBE_CH:
                put(dmx, ch, (v, v, v))
            break

    # ---- device cues ----------------------------------------------------
    if any(s <= t < e for s, e in FOG_CUES):
        dmx[FOG] = 255
    if any((vs - LASER_LATENCY_MS) <= t < ve for vs, ve in LASER_CUES):
        dmx[LASER] = 255
    if any((vs - STROBEPLUG_LATENCY_MS) <= t < ve for vs, ve in STROBEPLUG_CUES):
        dmx[STROBE_PLUG] = 255
    return bytes(dmx)

# ---- engine -------------------------------------------------------------
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
          f"130.00 BPM lattice (anchor {ANCHOR/1000:.2f}s)", flush=True)

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
            next_t += 1.0 / FPS
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
