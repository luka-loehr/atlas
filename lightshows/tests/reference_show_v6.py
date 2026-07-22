#!/usr/bin/env python3
"""Frozen legacy show engine v5 "EXTREME MODE" — the golden-test oracle.

tests/golden.py loads this module and compares its render(t) frame-by-frame
against the modular lslib Player. The render() half must stay FROZEN; the
old standalone Art-Net playback engine was removed (superseded by
lslib/player.py + play.py).

v5 = EXTREME: hardware strobe on EVERY drop (6.5s pre-power, windows merged
where a re-strike is physically impossible), ~2.3x more fog, triple white
kick flashes on drop 1, full-room 255 white slams on every beat in drops.
v4 = club-master teardown: peaks unclipped (drops -> 1.0 full white),
high-energy sections lifted 0.30-0.42 -> 0.80-0.90, builds actually build,
10s hardware-strobe SOLO at drop 3 (all Hue black).

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
"""
import colorsys, math

NCHAN = 21
SONG_END_S = 260.4
AUDIO_LATENCY_MS = 300          # AirPods (ear-calibrated via beat_cal.py)
LASER_LATENCY_MS = 3900         # TODO: re-measure WORST-case warm-up; any pre-flicker
STROBEPLUG_LATENCY_MS = 6500    # during charging would leak into the pre-drop blackouts

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

# CONVENTION (verified vs Beat This): true downbeats sit at beat_idx % 4 == 3;
# the big slams (59.70, 196.28, ...) land on beat_idx % 4 == 0 (beat-2 phase).
# All bi%4==0 / bi%8==0 accents therefore hit the slam phase ON PURPOSE.
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
# EXTREME: fog on every drop + builds (still lit phases only — disco globe rule)
FOG_CUES = [(0, 5000),           # white-slab opening (fog continues from the pre-roll)
            (40000, 54000),      # build 1 — thick haze into drop 1
            (59700, 68000),      # drop 1 (lit: kick flashes + pink bed)
            (74000, 80000),      # chorus opener
            (118300, 128000),    # drop 2
            (136770, 144000),    # drop reprise
            (158920, 168920),    # drop 3 — rides the 10s strobe solo (globe lit BY the strobe)
            (196300, 206000),    # final high
            (217800, 222000),    # escalation point
            (229500, 238000),    # finale 2
            (243829, 247000)]    # strobe farewell under laser
# laser runs continuously through climax->finale2: a real gap is impossible
# (3.9s warm-up can't re-strike in the 1.8s breakdown at 227.2-229.06)
# drop-3 laser strikes AT the end of the strobe solo (charges silently during it)
LASER_CUES = [(59700, 72420), (168920, 175000), (220700, 245000)]
# EXTREME: hardware strobe on EVERY drop. Windows merged where the 6.5s
# warm-up makes a re-strike between them physically impossible.
STROBEPLUG_CUES = [(59700, 72420),     # drop 1 — full length
                   (118300, 151090),   # drop 2 -> reprise (no re-strike possible between)
                   (158920, 168920),   # drop 3 = 10s SOLO
                   (196280, 210000),   # final-high opening burst
                   (224700, 236000)]   # climax -> bridged through breakdown -> finale drop

# strongest measured impacts -> single-frame white overlays (time_ms, strength)
ACCENTS = [(2910, .75), (4760, .75), (5460, .65), (6610, .75), (7300, .65),
           (11910, .65), (75840, .85), (78380, .85), (79530, .85),
           (87880, .85), (226070, 1.0),
           (232280, .95), (235970, .95), (250300, .95)]

# accelerating terminal-roll flash times (56.2-57.1s), precomputed because
# int(t // per) with a time-varying period aliases into irregular flicker
_ROLL = []
_x = 56200.0
while _x < 57100.0:
    _ROLL.append(_x)
    _x += max(80.0, 230.0 - 140.0 * (_x - 56200.0) / 900.0)

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
def tuned_strobe(dmx, t, v=0.90, chans=STROBE_CH, ceiling=0.0):
    """1 frame on / 3 off, white; swop: everything else black."""
    if int(t // 40) % 4 == 0:
        black(dmx)
        val = int(255 * v)
        for ch in chans:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

def drop_hit(dmx, t, t_hit, v=1.0):
    if t_hit <= t < t_hit + 120:                      # EXTREME: 3-frame full slam
        val = int(255 * v)
        for ch in ALL_LIGHTS:
            put(dmx, ch, (val, val, val))
        return True
    return False

def pulse(dmx, rgb):
    """DARK-GAP: everything ON together — colored fixtures + white ceiling.
    Between pulses the room is TRUE BLACK; that gap IS the effect."""
    for ch in ALL_LIGHTS:
        put(dmx, ch, rgb)
    put(dmx, DECKE, (255, 255, 255))

def upulse(dmx, t, grid, decay, vmax, hue, sat=1.0):
    """DARK-GAP build pulse: whole room breathes ON together on the grid,
    envelope decays to ~black in the gap. No fixture ever fills another's gap."""
    env = math.exp(-(bphase(t) % grid) / decay)
    rgb = hsv(hue, sat, vmax * env)
    for ch in ALL_LIGHTS:
        put(dmx, ch, rgb)

# ---- the SHOW (all boundaries = measured events) ------------------------
def render(t):
    dmx = bytearray(NCHAN)
    if t < 0:
        if t >= -20000 - AUDIO_LATENCY_MS:            # PRE-ROLL: pure fog, dark, silent
            dmx[FOG] = 255                            # (latency offset shifts t at the head)
        return bytes(dmx)

    # ===== 0 - 5: WHITE SLAB — blinding open through the fog ==============
    if t < 5000:
        for ch in ALL_LIGHTS:
            put(dmx, ch, (255, 255, 255))

    # ===== 5 - 18.2: gradient intro (slow — the calm before) =============
    elif t < 18200:
        frac = clamp((t - 5000) / 13200.0)
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
        lift = clamp((t - 29000) / 11000.0)           # room visibly fills toward the build
        put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, (0.35 + 0.10 * lift) * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.08 + 0.14 * lift))
        d = int(255 * (0.10 + 0.15 * lift) * beat_env(t, 200))
        put(dmx, DECKE, (d, d, d))

    # ===== 40 - 49.35: build p1 — capped rainbow pulse ===================
    elif t < 49350:
        sec = (t - 40000) / 9350.0                    # a build must BUILD
        env = beat_env(t, 250)
        bright = (0.15 + 0.30 * sec) + (0.25 + 0.30 * sec) * env
        bi = beat_idx(t)
        if bphase(t) < 40 and (bi % 4 == 3 if sec < 0.5 else bi % 2 == 1):
            for ch in ALL_LIGHTS:                     # unified white flash — density rises
                put(dmx, ch, (255, 255, 255))
        else:
            for i, ch in enumerate(ALL_LIGHTS):
                hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
                put(dmx, ch, hsv(hue, 1.0, bright))

    # ===== 49.35 - 56.2: build p2 — 8th roll from the acceleration point =
    elif t < 56200:
        ramp = (t - 49350) / 6850.0
        bi = beat_idx(t)
        upulse(dmx, t, EIGHTH, 100.0 - 60.0 * ramp, 0.45 + 0.45 * ramp,
               (bi * 0.13) % 1.0, 1.0 - 0.7 * ramp)   # unified 8th roll — gaps darken to black

    # ===== 56.2 - 57.1: terminal roll — full-room white out of black =====
    elif t < 57100:
        if any(ft <= t < ft + 40 for ft in _ROLL):
            for ch in ALL_LIGHTS:                     # riser apex: white flashes out of BLACK
                put(dmx, ch, (255, 255, 255))
        # else: TRUE BLACK — accelerating flash/black into the drop

    # ===== 57.1 - 59.7: BLACKOUT (bass gone) + dim pre-boom at 59.22 =====
    elif t < 59700:
        if 59220 <= t < 59300:
            for ch in ALL_LIGHTS:
                put(dmx, ch, hsv(0.63, 1.0, 0.08))

    # ===== 59.7: DROP 1 — slam + triple stutter; bass gap 66.15-66.70 dark
    elif t < 72420:
        if not drop_hit(dmx, t, 59700):
            if 66150 <= t < 66700:
                pass    # bass drops -43dB here (librosa detail run) = darkness accent
            else:
                p = bphase(t)
                if p < 40 or 80 <= p < 120 or 160 <= p < 200:   # signature triple stutter
                    rgb = (255, 255, 255) if sec_bar(t, 59700) % 2 == 0 else hsv(0.95, 1.0, 1.0)
                    pulse(dmx, rgb)                    # white / hot-pink alternating per bar
                # else: TRUE BLACK — the dark gap IS the strobe feeling

    # ===== 72.42 - 74.0: fill — dim magenta handoff ======================
    elif t < 74000:
        env = beat_env(t, 250)
        for ch in REGALE:
            put(dmx, ch, hsv(0.87, 1.0, 0.10 * env))

    # ===== 74.0 - 87.19: CHORUS — rhythmically densest music of the track
    elif t < 87190:
        bi = beat_idx(t)
        bar = sec_bar(t, 74000)
        if bar == 0:                                  # strobe opener, already dark-gap
            tuned_strobe(dmx, t, v=0.90)
        else:
            hue = 0.13 if bar % 2 == 0 else 0.87      # amber / magenta per bar
            gate = bphase(t) if bar <= 2 else bphase(t) % EIGHTH
            W = 100 if bar <= 2 else 70               # density escalates through the chorus
            if gate < W:
                if bi % 4 == 0 and bphase(t) < 60:    # slam-phase beat: WHITE
                    pulse(dmx, (255, 255, 255))
                else:
                    pulse(dmx, hsv(hue, 1.0, 0.90))
            # else: TRUE BLACK

    # ===== 87.19 - 88.76: dip (bass silent; snare accent handled below) ==
    elif t < 88760:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.06))

    # ===== 88.76 - 94.58: comet — 2nd loudest section, brightened ========
    elif t < 94580:
        bi = beat_idx(t)
        bar = sec_bar(t, 88760)
        hue = 0.50 if bar % 2 == 0 else 0.87          # cold/hot comet identity
        if bphase(t) % EIGHTH < 70:                   # densest cadence: 2nd loudest section
            if bi % 4 == 0 and bphase(t) < 60:
                pulse(dmx, (255, 255, 255))
            else:
                pulse(dmx, hsv(hue, 1.0, 0.90))
        # else: TRUE BLACK

    # ===== 94.58 - 101.49: chorus var C — STAYS at chorus energy =========
    elif t < 101490:
        bi = beat_idx(t)
        bar = sec_bar(t, 94580)
        hue = 0.75 if bar % 2 == 0 else 0.50          # purple / cyan per bar
        if bphase(t) < 100:                           # beat pulses (differentiates from comet)
            if bi % 4 == 0 and bphase(t) < 60:
                pulse(dmx, (255, 255, 255))
            else:
                pulse(dmx, hsv(hue, 1.0, 0.90))
        # else: TRUE BLACK

    # ===== 101.49 - 102.13: fill — fast fade =============================
    elif t < 102130:
        sec = (t - 101490) / 640.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.15 * (1 - sec)))

    # ===== 102.13 - 118.3: verse 2 — dark red ticks walk the room ========
    elif t < 118300:
        if t < 103510:                                # bass still out: hold still
            for ch in REGALE:
                put(dmx, ch, hsv(0.0, 1.0, 0.06))
        elif t < 112000:                              # calm dark-red walk (allowed: dim)
            bi = beat_idx(t)
            env = beat_env(t, 120)
            put_stop(dmx, CIRCLE[bi % 4], hsv(0.0, 1.0, 0.08 * env))
            put(dmx, DECKE, hsv(0.08, 0.7, 0.10 * beat_env(t, 200)))
        else:                                         # unified red pulses escalate into drop 2
            ramp = clamp((t - 112000) / 6300.0)
            if t < 116300:
                upulse(dmx, t, BEAT, 120.0 - 70.0 * ramp, 0.10 + 0.35 * ramp, 0.0)
            else:
                upulse(dmx, t, EIGHTH, 60.0, 0.45, 0.0)   # double rate: the room pants into the drop

    # ===== 118.3: DROP 2 — cold drop: sustained slams, sparse strobe =====
    elif t < 131960:
        if not drop_hit(dmx, t, 118300):
            bar = sec_bar(t, 118300)
            if bar % 4 == 3:                          # every 4th bar: tuned strobe
                tuned_strobe(dmx, t, v=0.90, ceiling=0.20)
            else:
                k = int((t - ANCHOR) // EIGHTH)       # cold per-8th strobe
                if bphase(t) % EIGHTH < 60:           # 60ms pulse on every 8th
                    pulse(dmx, hsv(0.87 if k % 2 == 0 else 0.50, 1.0, 1.0))
                # else: TRUE BLACK — magenta/cyan flicker out of darkness

    # ===== 131.96 - 132.26: collapse =====================================
    elif t < 132260:
        sec = (t - 131960) / 300.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.10 * (1 - sec)))

    # ===== 132.26 - 134.87: breakdown silence — heartbeat ================
    elif t < 134870:
        hb = math.exp(-((t - 132260) % 2000) / 180.0)     # NB: must not shadow pulse()
        put_stop(dmx, DISPLAY, hsv(0.0, 1.0, 0.06 * hb))

    # ===== 134.87 - 135.86: music creeps back ============================
    elif t < 135860:
        sec = (t - 134870) / 990.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.75, 1.0, 0.06 * sec))

    # ===== 135.86 - 151.09: DROP REPRISE (user: "grosser Drop ~2:18") ====
    # Same cluster as drop 1A per segmentation; bass slams back at 136.77.
    elif t < 151090:
        if t < 136770:
            pass                                      # TRUE BLACK until the bass actually hits
        elif not drop_hit(dmx, t, 136770):
            bar = sec_bar(t, 136770)
            if bar % 8 == 4:                          # strobe bar for punch
                tuned_strobe(dmx, t, v=0.90)
            else:
                if bphase(t) < 110:                   # one FAT 110ms slam per beat (heaviest drop)
                    pulse(dmx, hsv(0.75 if bar % 2 == 0 else 0.50, 1.0, 1.0))
                # else: TRUE BLACK — purple/cyan slams out of darkness

    # ===== 151.09 - 157.15: wind down ====================================
    elif t < 157150:
        sec = (t - 151090) / 6060.0
        gain = 1.0 - 0.85 * sec
        bar = sec_bar(t, 151539)                      # true downbeat (151090 is beat 4)
        put_stop(dmx, CIRCLE[bar % 4], hsv(0.75, 1.0, 0.15 * gain))

    # ===== 157.15 - 158.92: BLACKOUT (the only clean silence lives here) =
    elif t < 158920:
        pass

    # ===== 158.92: DROP 3 = TRACK PEAK — 10s HARDWARE STROBE SOLO ========
    elif t < 168920:
        drop_hit(dmx, t, 158920)                      # full-white entrance slam, then
        # ALL Hue + ceiling stay BLACK: the hardware strobe owns the room ALONE
        # (fog/disco rides the strobe's flashes; laser charges silently, strikes 168.92)

    # ===== 168.92 - 170.4: step-down fill ================================
    elif t < 170400:
        sec = (t - 168920) / 1480.0
        for ch in REGALE:
            put(dmx, ch, hsv(0.50, 1.0, 0.12 * sec))

    # ===== 170.4 - 173.7: kickless bridge — L/R cross-fade under laser ===
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
        put_stop(dmx, CIRCLE[bi % 4], hsv(0.62, 1.0, 0.50 * (0.35 + 0.65 * env)))
        put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(0.62, 1.0, 0.12))

    # ===== 181.09 - 196.0: FINAL BUILD — the track's biggest riser =======
    elif t < 196000:
        sec = (t - 181090) / (196000 - 181090)
        hue = 0.62 + 0.25 * sec
        if t < 185250:                                # p1: unified beat pulse
            bi = beat_idx(t)
            if bi % 4 == 3 and bphase(t) < 40:
                for ch in ALL_LIGHTS:                 # downbeat white flash
                    put(dmx, ch, (255, 255, 255))
            else:
                upulse(dmx, t, BEAT, 220.0, 0.45, hue)
        elif t < 189600:                              # p2: acceleration point — unified 8ths
            ramp = (t - 185250) / 4350.0
            upulse(dmx, t, EIGHTH, 100.0 - 60.0 * ramp, 0.50 + 0.40 * ramp,
                   hue, 1.0 - 0.4 * ramp)
        else:                                         # p3: noise-riser surge -> white
            if t >= 193992:                           # last full bar (true downbeat) pre-cut
                tuned_strobe(dmx, t, v=0.90)
            else:
                desat = clamp((t - 189600) / 6400.0)
                upulse(dmx, t, EIGHTH, 90.0 - 70.0 * desat, 0.35 + 0.55 * desat,
                       hue, 1.0 - 0.7 * desat)        # accelerating all-on/black to near-white

    # ===== 196.0 - 196.28: blackout (measured bass cut) ==================
    elif t < 196280:
        pass

    # ===== 196.28: FINAL HIGH -> 227.2 ===================================
    elif t < 227200:
        if drop_hit(dmx, t, 196280):
            pass
        elif t >= 224700:                             # climax: hardware strobe ALONE
            pass                                      # all Hue black — the plug owns it
        else:
            bar = sec_bar(t, 195820)                  # true downbeat (Beat This): hit is beat 2
            bi = beat_idx(t)
            hue = (0.87 + (t - 196280) / 30000.0) % 1.0
            if bar % 8 in (6, 7):
                tuned_strobe(dmx, t, v=0.90)
            else:
                if t >= 217800:                       # escalation point: 8ths, brighter
                    gate, W, v = bphase(t) % EIGHTH, 65, 1.0
                else:
                    gate, W, v = bphase(t), 90, 0.95
                if gate < W:
                    if bi % 4 == 0 and bphase(t) < 60:
                        pulse(dmx, (255, 255, 255))   # slam-phase WHITE
                    else:
                        pulse(dmx, hsv(hue, 1.0, v))
                # else: TRUE BLACK — the climax strobes hardest

    # ===== 227.2 - 229.06: breakdown fill (bass silent: hold still) ======
    elif t < 229060:
        for ch in REGALE:
            put(dmx, ch, hsv(0.63, 1.0, 0.06))

    # ===== 229.06: FINALE 2 — rank-2 rhythmic intensity, upgraded ========
    elif t < 258650:
        if drop_hit(dmx, t, 229060):
            pass
        elif 243829 <= t < 245000:                    # strobe farewell (bar-aligned) under laser
            tuned_strobe(dmx, t, v=0.90)
        else:
            bi = beat_idx(t)
            bar = sec_bar(t, 229060)
            palette = [0.87, 0.0, 0.13, 0.95]         # magenta/red/amber/hot-pink per bar
            hue = palette[bar % 4]
            if bar % 8 == 7:                          # dense burst bar (was the sweep)
                gate, W = bphase(t) % EIGHTH, 65
            else:
                gate, W = bphase(t), 95
            if gate < W:
                if bi % 4 == 0 and bphase(t) < 60:
                    pulse(dmx, (255, 255, 255))
                else:
                    pulse(dmx, hsv(hue, 1.0, 0.90))
            # else: TRUE BLACK

    # ===== 258.65 - end: outro fade, ceiling dies last ===================
    elif t < SONG_END_S * 1000:
        sec = clamp((t - 258650) / 1700.0)
        for ch in (*DISPLAY, *REGALE):
            put(dmx, ch, hsv(0.87, 1.0, 0.12 * (1 - sec)))
        put(dmx, DECKE, hsv(0.08, 0.5, 0.10 * (1 - sec) ** 0.5))

    # ---- measured-impact single-frame accents (max-blend: only brighten) -
    for imp, strength in ACCENTS:
        if imp <= t < imp + 40:
            v = int(255 * strength)
            for ch in STROBE_CH:
                dmx[ch] = max(dmx[ch], v)
                dmx[ch + 1] = max(dmx[ch + 1], v)
                dmx[ch + 2] = max(dmx[ch + 2], v)
            break

    # ---- device cues ----------------------------------------------------
    if any(s <= t < e for s, e in FOG_CUES):
        dmx[FOG] = 255
    if any((vs - LASER_LATENCY_MS) <= t < ve for vs, ve in LASER_CUES):
        dmx[LASER] = 255
    if any((vs - STROBEPLUG_LATENCY_MS) <= t < ve for vs, ve in STROBEPLUG_CUES):
        dmx[STROBE_PLUG] = 255
    return bytes(dmx)
