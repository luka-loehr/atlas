"""Show compiler: analysis.json -> .show.json sequence.

Encodes the v6 design language as rules:
  intro -> white slab + gradient      build -> upulse escalation + roll
  drop  -> DARK-GAP pulse DNA         peak drop after silence -> strobe SOLO
  high  -> gated pulses + white slams breakdown/quiet -> dark textures
plus the device constraint solver (fog lit-only, laser 3.9s / strobe 6.5s
warm-up pre-power, window merging where a re-strike is impossible).
"""

DEFAULTS = {
    "audio_latency_ms": 300,
    "laser_lead_ms": 3900,
    "strobe_lead_ms": 6500,
    "preroll_fog_ms": 20000,
    "white_slab_ms": 5000,
}

# rotating drop DNA (the three v6 signatures)
DROP_DNA = ["stutter", "eighth", "fat"]
HIGH_HUES = [[0.13, 0.87], [0.50, 0.87], [0.75, 0.50], [0.87, 0.0, 0.13, 0.95]]


def _merge(windows, min_gap):
    """Merge windows whose gap is too short for a device re-strike."""
    out = []
    for a, b in sorted(windows):
        if out and a - out[-1][1] < min_gap:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [[round(a, 1), round(b, 1)] for a, b in out]


def compile_show(analysis, song_file, title=None, opts=None):
    o = dict(DEFAULTS, **(opts or {}))
    dur = analysis["duration_ms"]
    tempo = analysis["tempo"]
    bpm = tempo["bpm"]
    beat = 60000.0 / bpm
    bar = 4 * beat
    drops = [d for d in analysis["drops"]]
    segs = analysis["segments"]
    quiet = analysis["quiet_windows"]
    warnings = []
    if not tempo.get("confident", True):
        warnings.append(f"tempo residual {tempo['residual_ms']}ms — lattice may drift")

    # ---- anchor: the downbeat closest to the strongest drop --------------
    downs = analysis["downbeats_ms"]
    if drops and downs:
        main = max(drops, key=lambda d: d["score"])
        anchor = min(downs, key=lambda d: abs(d - main["t_ms"]))
    elif downs:
        anchor = downs[0]
    else:
        anchor = analysis["beats_ms"][0] if analysis["beats_ms"] else 0.0
        warnings.append("no downbeats — anchor on first beat")

    def snap(t):                                       # snap a time onto the lattice
        return anchor + round((t - anchor) / beat) * beat

    def snap_bar(t):
        return anchor + round((t - anchor) / bar) * bar

    # ---- classify the timeline into regions ------------------------------
    # drop regions: from each (snapped) drop to the next segment boundary
    regions = []                                       # (t0, t1, kind, extra)
    drop_windows = []
    for i, d in enumerate(drops):
        t0 = snap(d["t_ms"])
        nxt = min((s["end_ms"] for s in segs
                   if s["start_ms"] <= t0 < s["end_ms"]), default=t0 + 8 * bar)
        t1 = min(max(nxt, t0 + 4 * bar), t0 + 8 * bar, dur)
        if i + 1 < len(drops):
            t1 = min(t1, snap(drops[i + 1]["t_ms"]))
        drop_windows.append([t0, t1, d["score"]])

    # peak drop = highest score that follows a quiet window -> strobe SOLO
    solo_idx = None
    for i, (t0, t1, score) in enumerate(drop_windows):
        preceded = any(qb - 300 <= t0 and qa < t0 for qa, qb in quiet)
        if preceded and (solo_idx is None or score > drop_windows[solo_idx][2]):
            solo_idx = i
    if solo_idx is None and drop_windows:
        solo_idx = max(range(len(drop_windows)), key=lambda i: drop_windows[i][2])
        warnings.append("no quiet-preceded drop — strobe solo on peak drop anyway")

    rms_hi = sorted(s["rms"] for s in segs)[int(len(segs) * 0.7)] if segs else 0.5

    def seg_kind(s):
        if s["rms"] >= rms_hi:
            return "high"
        if s["rms"] < 0.22:
            return "quietseg"
        return "mid"

    # ---- cue generation ---------------------------------------------------
    cues = []

    def cue(t0, t1, fx, **p):
        t0, t1 = round(t0, 1), round(min(t1, dur), 1)
        if t1 - t0 >= 40 and (not cues or t0 >= cues[-1]["t1"] - 0.01):
            if cues and t0 < cues[-1]["t1"]:
                t0 = cues[-1]["t1"]
            cues.append({"t0": t0, "t1": t1, "fx": fx, "p": p})

    def in_drop(t):
        return any(a <= t < b for a, b, _ in drop_windows)

    # intro: white slab through the fog, then gradient
    first_drop = drop_windows[0][0] if drop_windows else dur
    slab_end = min(o["white_slab_ms"], first_drop)
    cue(0, slab_end, "solid", color="white")
    intro_end = min(next((s["end_ms"] for s in segs if s["start_ms"] < slab_end),
                         slab_end + 13000), first_drop)
    if intro_end > slab_end + 1500:
        cue(slab_end, intro_end, "intro_gradient")

    # walk the timeline
    t = intro_end
    drop_i = 0
    fog, laser, strobe = [[0, slab_end]], [], []
    high_i = 0
    while t < dur - 500:
        # inside a drop window?
        dw = next(((i, a, b) for i, (a, b, _) in enumerate(drop_windows)
                   if a <= t < b), None)
        if dw:
            i, a, b = dw
            dna = "solo" if i == solo_idx else DROP_DNA[drop_i % len(DROP_DNA)]
            drop_i += 1
            strobe.append([a, min(a + 10000, b)] if dna == "solo" else [a, b])
            fog.append([a, min(a + 8000, b)])
            if dna == "solo":
                cue(a, min(a + 10000, b), "hit_black", hit=a)
                if b > a + 10000:                      # solo tail: fat slams
                    cue(a + 10000, b, "gated_pulse", bar_anchor=a, grid="beat",
                        width=110, v=1.0, hues=[0.75, 0.50],
                        strobe_mod=[8, [4]], strobe={"v": 0.90})
                laser.append([a + 10000, b + 4000])
            elif dna == "stutter":
                cue(a, b, "stutter_pulse", hit=a,
                    windows=[[0, 40], [80, 120], [160, 200]],
                    colors=["white", [0.95, 1.0, 1.0]])
                laser.append([a, b])
            elif dna == "eighth":
                cue(a, b, "gated_pulse", hit=a, bar_anchor=a, grid="eighth",
                    width=60, v=1.0, hues=[0.87, 0.50], color_by="pulse",
                    strobe_mod=[4, [3]], strobe={"v": 0.90, "ceiling": 0.20})
            else:                                      # fat
                cue(a, b, "gated_pulse", hit=a, bar_anchor=a, grid="beat",
                    width=110, v=1.0, hues=[0.75, 0.50],
                    strobe_mod=[8, [4]], strobe={"v": 0.90})
            t = b
            continue

        # otherwise: the segment we're in
        s = next((s for s in segs if s["start_ms"] <= t < s["end_ms"]), None)
        seg_end = s["end_ms"] if s else dur
        # cut the segment at the next drop start
        nxt_drop = next((a for a, _, _ in drop_windows if a > t), dur)
        end = min(seg_end, nxt_drop, dur)
        kind = seg_kind(s) if s else "mid"

        # build detection: the stretch right before a drop escalates
        if nxt_drop < dur and end >= nxt_drop - 100 and nxt_drop - t > 3000:
            b0 = max(t, nxt_drop - 16000)
            if b0 > t + 1000:
                cue(t, b0, "chase" if kind != "quietseg" else "dim_hold",
                    **({"hue": 0.62, "v_head": 0.40, "v_trail": 0.10, "decay": 220}
                       if kind != "quietseg" else
                       {"channels": "regale", "color": [0.63, 1.0, 0.06]}))
            half = b0 + (nxt_drop - b0) * 0.55
            roll0 = nxt_drop - 900
            cue(b0, half, "upulse", grid="beat", domain=[b0, nxt_drop],
                decay=[140, 60], vmax=[0.20, 0.60],
                hue={"mode": "beat_cycle", "step": 0.13})
            cue(half, roll0, "upulse", grid="eighth", domain=[b0, nxt_drop],
                decay=[100, 40], vmax=[0.45, 0.90], sat=[1.0, 0.4],
                hue={"mode": "beat_cycle", "step": 0.13})
            cue(roll0, nxt_drop, "roll", p0=230, slope=140, ref_dur=900,
                pmin=80, width=40)
            fog.append([max(t, nxt_drop - 10000), nxt_drop])
            t = nxt_drop
            continue

        if kind == "high":
            hues = HIGH_HUES[high_i % len(HIGH_HUES)]
            high_i += 1
            a0 = snap_bar(t)
            split = t + (end - t) * 0.45
            cue(t, split, "gated_pulse", bar_anchor=a0, grid="beat", width=100,
                v=0.90, hues=hues, white_slam=True)
            cue(split, end, "gated_pulse", bar_anchor=a0, grid="eighth", width=70,
                v=0.90, hues=hues, white_slam=True,
                burst={"mod": [8, [7]], "grid": "eighth", "width": 65})
            fog.append([t, min(t + 6000, end)])
        elif kind == "quietseg":
            cue(t, end, "heartbeat", period=2000, decay=180, hue=0.0, v=0.06)
        else:                                          # mid
            if (high_i + drop_i) % 2 == 0:
                cue(t, end, "circle_tick", hue=0.0, v=0.08, decay=120,
                    decke=[0.08, 0.7, 0.10, 200])
            else:
                cue(t, end, "chase", hue=0.62, v_head=0.45, v_trail=0.12, decay=220)
        t = end

    # outro fade over the last cue-free tail
    if cues and cues[-1]["t1"] < dur - 300:
        cue(cues[-1]["t1"], dur, "outro_fade", dur=min(1700, dur - cues[-1]["t1"]))
    elif cues:
        last = cues[-1]
        if last["t1"] > dur - 300 and last["fx"] in ("gated_pulse", "chase"):
            last["t1"] = round(dur - 1700, 1)
            cues.append({"t0": last["t1"], "t1": dur, "fx": "outro_fade",
                         "p": {"dur": 1700}})

    # ---- devices: solver ---------------------------------------------------
    laser.append([max(0, dur - 30000), dur - 12000])   # laser rides the last high
    devices = {
        "fog": _merge([[max(0, a), min(b, dur)] for a, b in fog], 1500),
        "laser": _merge([[max(0, a), min(b, dur)] for a, b in laser],
                        o["laser_lead_ms"] + 1000),
        "strobe": _merge([[max(o["strobe_lead_ms"], a), min(b, dur)]
                          for a, b in strobe], o["strobe_lead_ms"] + 500),
    }

    # accents: strongest measured impacts outside drop windows
    accents = [[i["t_ms"], round(0.6 + 0.4 * i["strength"], 2)]
               for i in analysis["impacts"] if not in_drop(i["t_ms"])][:14]

    seq = {
        "version": 1,
        "meta": {
            "song_file": song_file, "title": title or song_file,
            "bpm": round(bpm, 3), "anchor_ms": round(anchor, 1),
            "duration_ms": round(dur, 1),
            "audio_latency_ms": o["audio_latency_ms"],
            "laser_lead_ms": o["laser_lead_ms"],
            "strobe_lead_ms": o["strobe_lead_ms"],
            "preroll_fog_ms": o["preroll_fog_ms"],
        },
        "cues": cues, "accents": accents, "devices": devices,
    }
    return seq, warnings
