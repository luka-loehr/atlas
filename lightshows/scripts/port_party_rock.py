#!/usr/bin/env python3
"""Port the hand-built v6 Party Rock show into a .show.json sequence.

This is the reference show: tests/golden.py proves the modular player
renders it FRAME-IDENTICAL to the legacy hand-coded show.py.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from lslib import sequence

BEAT = 60000.0 / 130.0
BAR = 4 * BEAT
CH0 = 74000                      # chorus anchor
DRIFT = {"mode": "drift", "h0": 0.62, "span": 0.25, "domain": [181090, 196000]}

def cue(t0, t1, fx, **p):
    return {"t0": t0, "t1": t1, "fx": fx, "p": p}

SEQ = {
    "version": 1,
    "meta": {
        "song_file": "../music.mp3",
        "title": "Party Rock Anthem (v6 dark-gap, hand-designed)",
        "bpm": 130.0, "anchor_ms": 59700.0, "duration_ms": 260400,
        "audio_latency_ms": 300, "laser_lead_ms": 3900, "strobe_lead_ms": 6500,
        "preroll_fog_ms": 20000,
    },
    "cues": [
        cue(0, 5000, "solid", color="white"),
        cue(5000, 18200, "intro_gradient"),
        cue(18200, 40000, "circle_walk", hue0=0.63, hue_span=0.09,
            switch_ms=29000, lift_from=29000, lift_dur=11000),
        cue(40000, 49350, "rainbow_build"),
        cue(49350, 56200, "upulse", grid="eighth", decay=[100, 40],
            vmax=[0.45, 0.90], sat=[1.0, 0.3], hue={"mode": "beat_cycle", "step": 0.13}),
        cue(56200, 57100, "roll", p0=230, slope=140, ref_dur=900, pmin=80, width=40),
        cue(57100, 59700, "blip", at=59220, width=80, color=[0.63, 1.0, 0.08]),
        # DROP 1 — triple stutter, white/hot-pink per bar
        cue(59700, 72420, "stutter_pulse", hit=59700,
            windows=[[0, 40], [80, 120], [160, 200]],
            colors=["white", [0.95, 1.0, 1.0]], dark=[[66150, 66700]]),
        cue(72420, 74000, "dim_pulse", channels="regale", hue=0.87, v=0.10, decay=250),
        # CHORUS — strobe opener, then gated pulses escalating beat -> 8th
        cue(CH0, CH0 + BAR, "strobe", v=0.90),
        cue(CH0 + BAR, CH0 + 3 * BAR, "gated_pulse", bar_anchor=CH0, grid="beat",
            width=100, v=0.90, hues=[0.13, 0.87], white_slam=True),
        cue(CH0 + 3 * BAR, 87190, "gated_pulse", bar_anchor=CH0, grid="eighth",
            width=70, v=0.90, hues=[0.13, 0.87], white_slam=True),
        cue(87190, 88760, "dim_hold", channels="regale", color=[0.63, 1.0, 0.06]),
        cue(88760, 94580, "gated_pulse", bar_anchor=88760, grid="eighth",
            width=70, v=0.90, hues=[0.50, 0.87], white_slam=True),
        cue(94580, 101490, "gated_pulse", bar_anchor=94580, grid="beat",
            width=100, v=0.90, hues=[0.75, 0.50], white_slam=True),
        cue(101490, 102130, "fade", channels="regale", hue=0.63, v0=0.15, v1=0.0),
        # VERSE 2 — dark ticks escalate into unified red pulses
        cue(102130, 103510, "dim_hold", channels="regale", color=[0.0, 1.0, 0.06]),
        cue(103510, 112000, "circle_tick", hue=0.0, v=0.08, decay=120,
            decke=[0.08, 0.7, 0.10, 200]),
        cue(112000, 116300, "upulse", grid="beat", domain=[112000, 118300],
            decay=[120, 50], vmax=[0.10, 0.45], hue={"mode": "fixed", "h": 0.0}),
        cue(116300, 118300, "upulse", grid="eighth", decay=60, vmax=0.45,
            hue={"mode": "fixed", "h": 0.0}),
        # DROP 2 — cold per-8th strobe, magenta/cyan per pulse
        cue(118300, 131960, "gated_pulse", hit=118300, bar_anchor=118300,
            grid="eighth", width=60, v=1.0, hues=[0.87, 0.50], color_by="pulse",
            strobe_mod=[4, [3]], strobe={"v": 0.90, "ceiling": 0.20}),
        cue(131960, 132260, "fade", channels="regale", hue=0.63, v0=0.10, v1=0.0),
        cue(132260, 134870, "heartbeat", period=2000, decay=180, hue=0.0, v=0.06),
        cue(134870, 135860, "fade", channels="regale", hue=0.75, v0=0.0, v1=0.06),
        # (135860-136770: TRUE BLACK gap until the bass hits)
        # DROP REPRISE — fat 110ms slams, purple/cyan per bar
        cue(136770, 151090, "gated_pulse", hit=136770, bar_anchor=136770,
            grid="beat", width=110, v=1.0, hues=[0.75, 0.50],
            strobe_mod=[8, [4]], strobe={"v": 0.90}),
        cue(151090, 157150, "wind_down", bar_anchor=151539, hue=0.75, v=0.15, fade=0.85),
        # (157150-158920: the only clean silence -> blackout gap)
        # DROP 3 = TRACK PEAK — 10s hardware strobe SOLO (device cue owns it)
        cue(158920, 168920, "hit_black", hit=158920),
        cue(168920, 170400, "fade", channels="regale", hue=0.50, v0=0.0, v1=0.12),
        cue(170400, 173700, "bridge_crossfade", period=3000, v=0.12, hue=0.50,
            hint_hue=0.55, display=[0.75, 1.0, 0.13]),
        cue(173700, 181090, "chase", hue=0.62, v_head=0.50, v_trail=0.12,
            decay=220, floor=0.35),
        # FINAL BUILD — unified pulses accelerate beat -> 8th -> near-white
        cue(181090, 185250, "upulse", grid="beat", decay=220, vmax=0.45, hue=DRIFT,
            flash={"mod": 4, "idx": [3], "width": 40}),
        cue(185250, 189600, "upulse", grid="eighth", domain=[185250, 189600],
            decay=[100, 40], vmax=[0.50, 0.90], sat=[1.0, 0.6], hue=DRIFT),
        cue(189600, 193992, "upulse", grid="eighth", domain=[189600, 196000],
            decay=[90, 20], vmax=[0.35, 0.90], sat=[1.0, 0.3], hue=DRIFT),
        cue(193992, 196000, "strobe", v=0.90),
        # (196000-196280: measured bass-cut blackout gap)
        # FINAL HIGH — the climax strobes hardest; escalation at 217.8
        cue(196280, 217800, "gated_pulse", hit=196280, bar_anchor=195820,
            grid="beat", width=90, v=0.95, white_slam=True,
            hue_drift={"h0": 0.87, "per_ms": 1.0 / 30000.0, "from": 196280},
            strobe_mod=[8, [6, 7]], strobe={"v": 0.90}),
        cue(217800, 224700, "gated_pulse", bar_anchor=195820,
            grid="eighth", width=65, v=1.0, white_slam=True,
            hue_drift={"h0": 0.87, "per_ms": 1.0 / 30000.0, "from": 196280},
            strobe_mod=[8, [6, 7]], strobe={"v": 0.90}),
        # (224700-227200: hardware strobe ALONE — gap)
        cue(227200, 229060, "dim_hold", channels="regale", color=[0.63, 1.0, 0.06]),
        # FINALE 2 — warm palette pulses, burst bars, strobe farewell
        cue(229060, 243829, "gated_pulse", hit=229060, bar_anchor=229060,
            grid="beat", width=95, v=0.90, hues=[0.87, 0.0, 0.13, 0.95],
            white_slam=True, burst={"mod": [8, [7]], "grid": "eighth", "width": 65}),
        cue(243829, 245000, "strobe", v=0.90),
        cue(245000, 258650, "gated_pulse", bar_anchor=229060,
            grid="beat", width=95, v=0.90, hues=[0.87, 0.0, 0.13, 0.95],
            white_slam=True, burst={"mod": [8, [7]], "grid": "eighth", "width": 65}),
        cue(258650, 260400, "outro_fade", dur=1700),
    ],
    "accents": [[2910, .75], [4760, .75], [5460, .65], [6610, .75], [7300, .65],
                [11910, .65], [75840, .85], [78380, .85], [79530, .85],
                [87880, .85], [226070, 1.0],
                [232280, .95], [235970, .95], [250300, .95]],
    "devices": {
        "fog": [[0, 5000], [40000, 54000], [59700, 68000], [74000, 80000],
                [118300, 128000], [136770, 144000], [158920, 168920],
                [196300, 206000], [217800, 222000], [229500, 238000],
                [243829, 247000]],
        "laser": [[59700, 72420], [168920, 175000], [220700, 245000]],
        "strobe": [[59700, 72420], [118300, 151090], [158920, 168920],
                   [196280, 210000], [224700, 236000]],
    },
}

if __name__ == "__main__":
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "shows", "party-rock.show.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sequence.save(SEQ, out)
    print(f"wrote {os.path.normpath(out)}  ({len(SEQ['cues'])} cues)")
