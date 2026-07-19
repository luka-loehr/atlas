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

DROP_DNA = ["stutter", "eighth", "fat"]               # rotating v6 signatures
HIGH_HUES = [[0.13, 0.87], [0.50, 0.87], [0.75, 0.50], [0.87, 0.0, 0.13, 0.95]]
MIN_CUE_MS = 400
BUILD_MS = 16000                                      # escalation ramp into a drop


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
    segs = analysis["segments"]
    quiet = analysis["quiet_windows"]
    warnings = []
    if not tempo.get("confident", True):
        warnings.append(f"tempo residual {tempo['residual_ms']}ms — lattice may drift")

    # ---- anchor: the downbeat closest to the strongest drop --------------
    downs = analysis["downbeats_ms"]
    drops = analysis["drops"]
    if drops and downs:
        main = max(drops, key=lambda d: d["score"])
        anchor = min(downs, key=lambda d: abs(d - main["t_ms"]))
    elif downs:
        anchor = downs[0]
    else:
        anchor = analysis["beats_ms"][0] if analysis["beats_ms"] else 0.0
        warnings.append("no downbeats — anchor on first beat")

    def snap(t):
        return anchor + round((t - anchor) / beat) * beat

    def snap_bar(t):
        return anchor + round((t - anchor) / bar) * bar

    # ---- drop windows -----------------------------------------------------
    drop_windows = []
    for i, d in enumerate(drops):
        t0 = snap(d["t_ms"])
        seg_end = next((s["end_ms"] for s in segs
                        if s["start_ms"] <= t0 < s["end_ms"]), t0 + 8 * bar)
        t1 = min(max(seg_end, t0 + 4 * bar), t0 + 8 * bar, dur)
        if i + 1 < len(drops):
            t1 = min(t1, snap(drops[i + 1]["t_ms"]))
        drop_windows.append([t0, t1, d["score"]])

    # peak drop that follows silence -> the 10s hardware strobe SOLO
    solo_idx = None
    for i, (t0, _, score) in enumerate(drop_windows):
        preceded = any(qa < t0 <= qb + 400 for qa, qb in quiet)
        if preceded and (solo_idx is None or score > drop_windows[solo_idx][2]):
            solo_idx = i
    if solo_idx is None and drop_windows:
        solo_idx = max(range(len(drop_windows)), key=lambda i: drop_windows[i][2])
        warnings.append("no quiet-preceded drop — strobe solo on peak drop anyway")

    # ---- non-drop regions: label + merge ---------------------------------
    rms_sorted = sorted(s["rms"] for s in segs) or [0.5]
    rms_hi = rms_sorted[int(len(rms_sorted) * 0.7)]

    def seg_kind(s):
        if s["rms"] >= rms_hi:
            return "high"
        if s["rms"] < 0.22:
            return "quiet"
        return "mid"

    def in_drop(t):
        return any(a <= t < b for a, b, _ in drop_windows)

    regions = []                                       # [t0, t1, kind]
    for s in segs:
        pieces = [[s["start_ms"], s["end_ms"]]]
        for a, b, _ in drop_windows:                   # cut out drop windows
            pieces = [[p0, min(p1, a)] if p0 < a < p1 else [p0, p1]
                      for p0, p1 in pieces if p1 > p0 and not (a <= p0 and p1 <= b)]
            pieces = [[max(p0, b), p1] if p0 < b <= p1 else [p0, p1]
                      for p0, p1 in pieces if p1 > p0]
        for p0, p1 in pieces:
            if p1 - p0 >= 250:
                regions.append([p0, p1, seg_kind(s)])
    regions.sort()
    merged = []
    for r in regions:                                  # merge neighbours, kill slivers
        if merged and (r[2] == merged[-1][2] or r[1] - r[0] < 2500) \
                and r[0] - merged[-1][1] < 500:
            merged[-1][1] = r[1]
        else:
            merged.append(list(r))
    regions = merged

    # ---- cue generation ----------------------------------------------------
    cues = []

    def cue(t0, t1, fx, **p):
        t0 = max(round(t0, 1), cues[-1]["t1"] if cues else 0.0)
        t1 = round(min(t1, dur), 1)
        if t1 - t0 >= MIN_CUE_MS:
            cues.append({"t0": t0, "t1": t1, "fx": fx, "p": p})

    def emit_drop(i):
        a, b, _ = drop_windows[i]
        dna = "solo" if i == solo_idx else DROP_DNA[emit_drop.rot % len(DROP_DNA)]
        emit_drop.rot += 1
        fog.append([a, min(a + 8000, b)])
        if dna == "solo":
            solo_end = min(a + 10000, b)
            strobe.append([a, solo_end])
            cue(a, solo_end, "hit_black", hit=a)
            if b - solo_end >= 2000:                   # solo tail: fat slams
                cue(solo_end, b, "gated_pulse", bar_anchor=a, grid="beat",
                    width=110, v=1.0, hues=[0.75, 0.50],
                    strobe_mod=[8, [4]], strobe={"v": 0.90})
            laser.append([solo_end, b + 4000])
        elif dna == "stutter":
            strobe.append([a, b])
            laser.append([a, b])
            cue(a, b, "stutter_pulse", hit=a,
                windows=[[0, 40], [80, 120], [160, 200]],
                colors=["white", [0.95, 1.0, 1.0]])
        elif dna == "eighth":
            strobe.append([a, b])
            cue(a, b, "gated_pulse", hit=a, bar_anchor=a, grid="eighth",
                width=60, v=1.0, hues=[0.87, 0.50], color_by="pulse",
                strobe_mod=[4, [3]], strobe={"v": 0.90, "ceiling": 0.20})
        else:                                          # fat
            strobe.append([a, b])
            cue(a, b, "gated_pulse", hit=a, bar_anchor=a, grid="beat",
                width=110, v=1.0, hues=[0.75, 0.50],
                strobe_mod=[8, [4]], strobe={"v": 0.90})
    emit_drop.rot = 0

    def emit_build(t0, t1):
        """Escalation into a drop: upulse beat -> 8th -> terminal roll."""
        fog.append([max(t0, t1 - 10000), t1])
        half = t0 + (t1 - t0) * 0.55
        roll0 = t1 - 900
        cue(t0, half, "upulse", grid="beat", domain=[t0, t1],
            decay=[140, 60], vmax=[0.20, 0.60],
            hue={"mode": "beat_cycle", "step": 0.13})
        cue(half, roll0, "upulse", grid="eighth", domain=[t0, t1],
            decay=[100, 40], vmax=[0.45, 0.90], sat=[1.0, 0.4],
            hue={"mode": "beat_cycle", "step": 0.13})
        cue(roll0, t1, "roll", p0=230, slope=140, ref_dur=900, pmin=80, width=40)

    def emit_region(t0, t1, kind):
        if kind == "high":
            hues = HIGH_HUES[emit_region.hi % len(HIGH_HUES)]
            emit_region.hi += 1
            a0 = snap_bar(t0)
            fog.append([t0, min(t0 + 6000, t1)])
            if t1 - t0 >= 10000:                       # escalate beat -> 8th
                split = t0 + (t1 - t0) * 0.45
                cue(t0, split, "gated_pulse", bar_anchor=a0, grid="beat",
                    width=100, v=0.90, hues=hues, white_slam=True)
                cue(split, t1, "gated_pulse", bar_anchor=a0, grid="eighth",
                    width=70, v=0.90, hues=hues, white_slam=True,
                    burst={"mod": [8, [7]], "grid": "eighth", "width": 65})
            else:
                cue(t0, t1, "gated_pulse", bar_anchor=a0, grid="beat",
                    width=100, v=0.90, hues=hues, white_slam=True)
        elif kind == "quiet":
            cue(t0, t1, "heartbeat", period=2000, decay=180, hue=0.0, v=0.06)
        else:                                          # mid
            if emit_region.mid % 2 == 0:
                cue(t0, t1, "circle_tick", hue=0.0, v=0.08, decay=120,
                    decke=[0.08, 0.7, 0.10, 200])
            else:
                cue(t0, t1, "chase", hue=0.62, v_head=0.45, v_trail=0.12, decay=220)
            emit_region.mid += 1
    emit_region.hi = 0
    emit_region.mid = 0

    fog, laser, strobe = [], [], []

    # intro: white slab through the fog, then gradient until the first region end
    first_drop = drop_windows[0][0] if drop_windows else dur
    slab_end = min(o["white_slab_ms"], first_drop)
    cue(0, slab_end, "solid", color="white")
    fog.append([0, slab_end])
    intro_end = min(next((r[1] for r in regions if r[0] < slab_end < r[1]),
                         slab_end + 13000), first_drop, slab_end + 15000)
    cue(slab_end, intro_end, "intro_gradient")

    # ---- walk the timeline -------------------------------------------------
    t = intro_end
    while t < dur - 500:
        di = next((i for i, (a, b, _) in enumerate(drop_windows) if a <= t < b), None)
        if di is not None:
            emit_drop(di)
            t = drop_windows[di][1]
            continue
        nxt_drop = next((a for a, _, _ in drop_windows if a > t), None)
        if nxt_drop is not None and nxt_drop - t <= BUILD_MS + 4000:
            b0 = max(t, nxt_drop - BUILD_MS)
            if b0 - t >= 3000:                         # calm chunk before the build
                r = next((r for r in regions if r[0] <= t < r[1]), None)
                emit_region(t, b0, r[2] if r else "mid")
            emit_build(max(t, b0), nxt_drop)
            t = nxt_drop
            continue
        r = next((r for r in regions if r[0] <= t < r[1]), None)
        end = r[1] if r else (nxt_drop or dur)
        if nxt_drop is not None:
            end = min(end, nxt_drop - BUILD_MS)        # leave room for the build
        end = min(end, dur)
        if end - t < MIN_CUE_MS:
            t = end if end > t else t + MIN_CUE_MS
            continue
        emit_region(t, end, r[2] if r else "mid")
        t = end

    # outro fade
    if cues and cues[-1]["t1"] > dur - 400 and cues[-1]["fx"] in ("gated_pulse", "chase", "circle_tick"):
        cues[-1]["t1"] = round(max(cues[-1]["t0"] + MIN_CUE_MS, dur - 1700), 1)
    if cues and dur - cues[-1]["t1"] >= MIN_CUE_MS:
        cues.append({"t0": cues[-1]["t1"], "t1": round(dur, 1),
                     "fx": "outro_fade", "p": {"dur": min(1700.0, dur - cues[-1]["t1"])}})

    # ---- devices: constraint solver ---------------------------------------
    devices = {
        "fog": _merge([[max(0, a), min(b, dur)] for a, b in fog], 1500),
        "laser": _merge([[max(0, a), min(b, dur)] for a, b in laser],
                        o["laser_lead_ms"] + 1000),
        "strobe": _merge([[max(o["strobe_lead_ms"], a), min(b, dur)]
                          for a, b in strobe], o["strobe_lead_ms"] + 500),
    }

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
