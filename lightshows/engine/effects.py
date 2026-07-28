"""Effect library — every v6 element as a parameterized, reusable module.

Signature: fx(dmx, t, cue, lat)
  dmx  bytearray(NCHAN) for this frame (zeros = TRUE BLACK)
  t    song time in ms
  cue  {"t0": ms, "t1": ms, "fx": name, "p": {params}}
  lat  Lattice (beat math)

DARK-GAP philosophy (the v6 insight): in intense effects ALL fixtures go ON
together and OFF together — true black between pulses. One lamp filling
another's gap keeps the room lit and kills the low-FPS strobe feeling.
"""
import math

from .rig import (ALL_LIGHTS, CIRCLE, DECKE, DISPLAY, GROUPS, REGALE,
                  STROBE_CH, black, clamp, hsv, put, put_stop)

EFFECTS = {}

def effect(name):
    def deco(fn):
        EFFECTS[name] = fn
        return fn
    return deco

# ---- shared helpers -----------------------------------------------------
def _pulse(dmx, rgb):
    """Everything ON together — colored fixtures + white ceiling."""
    for ch in ALL_LIGHTS:
        put(dmx, ch, rgb)
    put(dmx, DECKE, (255, 255, 255))

def _white(dmx):
    for ch in ALL_LIGHTS:
        put(dmx, ch, (255, 255, 255))

def _lerp(p, pair):
    if isinstance(pair, (int, float)):
        return float(pair)
    return pair[0] + (pair[1] - pair[0]) * p

def _u(t, cue, p):
    """Ramp position 0..1 over p['domain'] (default: the cue window)."""
    d0, d1 = p.get("domain", (cue["t0"], cue["t1"]))
    return clamp((t - d0) / (d1 - d0)) if d1 > d0 else 0.0

def _drop_hit(dmx, t, t_hit, width=120):
    """3-frame full-white entrance slam."""
    if t_hit <= t < t_hit + width:
        _white(dmx)
        return True
    return False

def _tuned_strobe(dmx, t, v=0.90, ceiling=0.0):
    """1 frame on / 3 off, white; swop: everything else black."""
    if int(t // 40) % 4 == 0:
        black(dmx)
        val = int(255 * v)
        for ch in STROBE_CH:
            put(dmx, ch, (val, val, val))
        if ceiling > 0:
            d = int(255 * ceiling)
            put(dmx, DECKE, (d, d, d))

# ---- calm / ambient effects --------------------------------------------
@effect("solid")
def fx_solid(dmx, t, cue, lat):
    """Constant color on all fixtures. p: color ("white" | [h,s,v])."""
    c = cue["p"].get("color", "white")
    rgb = (255, 255, 255) if c == "white" else hsv(*c)
    for ch in ALL_LIGHTS:
        put(dmx, ch, rgb)

@effect("intro_gradient")
def fx_intro_gradient(dmx, t, cue, lat):
    """Slow blue-white ramp on shelves + ceiling cos-bump on the beat."""
    frac = _u(t, cue, cue["p"])
    bright = 0.50 * frac
    rgb = (int(255 * (1 - frac) * bright), int(255 * (1 - frac) * bright),
           int(255 * bright))
    for ch in REGALE:
        put(dmx, ch, rgb)
    dt = lat.near_dt(t)
    bump = 0.5 * (1 + math.cos(math.pi * dt / 220.0)) if dt < 220.0 else 0.0
    d = int(255 * 0.28 * bump)
    put(dmx, DECKE, (d, d, d))

@effect("circle_walk")
def fx_circle_walk(dmx, t, cue, lat):
    """Calm dim chase around the room with a slow lift toward the build.
    p: hue0, hue_span, switch_ms (bar-walk -> beat-walk), lift_from, lift_dur."""
    p = cue["p"]
    t0, t1 = cue["t0"], cue["t1"]
    sec = (t - t0) / (t1 - t0)
    hue = p.get("hue0", 0.63) + p.get("hue_span", 0.09) * sec
    if t < p.get("switch_ms", t0):
        bi = lat.bar(t, t0)
        env = math.exp(-((t - t0) % (4 * lat.beat)) / 900.0)
    else:
        bi = lat.beat_idx(t)
        env = lat.env(t, 300)
    lift = clamp((t - p.get("lift_from", t1)) / p.get("lift_dur", 1))
    put_stop(dmx, CIRCLE[bi % 4], hsv(hue, 1.0, (0.35 + 0.10 * lift) * (0.35 + 0.65 * env)))
    put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(hue, 1.0, 0.08 + 0.14 * lift))
    d = int(255 * (0.10 + 0.15 * lift) * lat.env(t, 200))
    put(dmx, DECKE, (d, d, d))

@effect("chase")
def fx_chase(dmx, t, cue, lat):
    """Calm head+trail circle chase (NOT for intense sections — dark-gap!).
    p: hue, v_head, v_trail, decay, floor(0.35)."""
    p = cue["p"]
    bi = lat.beat_idx(t)
    env = lat.env(t, p.get("decay", 220))
    fl = p.get("floor", 0.35)
    put_stop(dmx, CIRCLE[bi % 4],
             hsv(p["hue"], 1.0, p["v_head"] * (fl + (1 - fl) * env)))
    put_stop(dmx, CIRCLE[(bi - 1) % 4], hsv(p["hue"], 1.0, p.get("v_trail", 0.12)))

@effect("circle_tick")
def fx_circle_tick(dmx, t, cue, lat):
    """Sparse dark ticks walking the room (verse texture).
    p: hue, v, decay, decke [h,s,v,decay]."""
    p = cue["p"]
    bi = lat.beat_idx(t)
    env = lat.env(t, p.get("decay", 120))
    put_stop(dmx, CIRCLE[bi % 4], hsv(p.get("hue", 0.0), 1.0, p.get("v", 0.08) * env))
    dk = p.get("decke")
    if dk:
        put(dmx, DECKE, hsv(dk[0], dk[1], dk[2] * lat.env(t, dk[3])))

@effect("dim_hold")
def fx_dim_hold(dmx, t, cue, lat):
    """Constant dim color. p: channels(group), color [h,s,v]."""
    p = cue["p"]
    put_stop(dmx, GROUPS[p.get("channels", "regale")], hsv(*p["color"]))

@effect("dim_pulse")
def fx_dim_pulse(dmx, t, cue, lat):
    """Dim beat-pulsing color. p: channels, hue, sat, v, decay."""
    p = cue["p"]
    env = lat.env(t, p.get("decay", 250))
    put_stop(dmx, GROUPS[p.get("channels", "regale")],
             hsv(p["hue"], p.get("sat", 1.0), p["v"] * env))

@effect("fade")
def fx_fade(dmx, t, cue, lat):
    """Linear fade v0 -> v1 over the cue. p: channels, hue, sat, v0, v1."""
    p = cue["p"]
    sec = (t - cue["t0"]) / (cue["t1"] - cue["t0"])
    v = p["v0"] + (p["v1"] - p["v0"]) * sec
    put_stop(dmx, GROUPS[p.get("channels", "regale")],
             hsv(p["hue"], p.get("sat", 1.0), v))

@effect("heartbeat")
def fx_heartbeat(dmx, t, cue, lat):
    """Breakdown heartbeat on the displays. p: period, decay, hue, v."""
    p = cue["p"]
    hb = math.exp(-((t - cue["t0"]) % p.get("period", 2000)) / p.get("decay", 180))
    put_stop(dmx, DISPLAY, hsv(p.get("hue", 0.0), 1.0, p.get("v", 0.06) * hb))

@effect("wind_down")
def fx_wind_down(dmx, t, cue, lat):
    """Bar-walking fade-out. p: bar_anchor, hue, v, fade(0.85)."""
    p = cue["p"]
    sec = (t - cue["t0"]) / (cue["t1"] - cue["t0"])
    gain = 1.0 - p.get("fade", 0.85) * sec
    bar = lat.bar(t, p.get("bar_anchor", cue["t0"]))
    put_stop(dmx, CIRCLE[bar % 4], hsv(p.get("hue", 0.75), 1.0, p.get("v", 0.15) * gain))

@effect("bridge_crossfade")
def fx_bridge_crossfade(dmx, t, cue, lat):
    """Kickless bridge: L/R sine cross-fade under the laser.
    p: period, v, hue, hint_hue, display [h,s,v]."""
    p = cue["p"]
    ph = 2 * math.pi * t / p.get("period", 3000)
    v = p.get("v", 0.12)
    lv = v * (0.5 + 0.5 * math.sin(ph))
    rv = v * (0.5 + 0.5 * math.sin(ph + math.pi))
    from .rig import REGAL_HINT, REGAL_LINK, REGAL_RECH
    put(dmx, REGAL_LINK, hsv(p.get("hue", 0.50), 1.0, lv))
    put(dmx, REGAL_RECH, hsv(p.get("hue", 0.50), 1.0, rv))
    put(dmx, REGAL_HINT, hsv(p.get("hint_hue", 0.55), 1.0, 0.5 * (lv + rv)))
    put_stop(dmx, DISPLAY, hsv(*p.get("display", (0.75, 1.0, 0.13))))

@effect("outro_fade")
def fx_outro_fade(dmx, t, cue, lat):
    """Outro: color dies on displays+shelves, warm ceiling dies last."""
    sec = clamp((t - cue["t0"]) / cue["p"].get("dur", 1700))
    for ch in (*DISPLAY, *REGALE):
        put(dmx, ch, hsv(0.87, 1.0, 0.12 * (1 - sec)))
    put(dmx, DECKE, hsv(0.08, 0.5, 0.10 * (1 - sec) ** 0.5))

@effect("blip")
def fx_blip(dmx, t, cue, lat):
    """Blackout except one dim blip window (pre-boom). p: at, width, color."""
    p = cue["p"]
    if p["at"] <= t < p["at"] + p.get("width", 80):
        for ch in ALL_LIGHTS:
            put(dmx, ch, hsv(*p["color"]))

# ---- build / escalation effects ----------------------------------------
@effect("rainbow_build")
def fx_rainbow_build(dmx, t, cue, lat):
    """Rainbow bed that BUILDS + unified white flashes with rising density."""
    sec = _u(t, cue, cue["p"])
    env = lat.env(t, 250)
    bright = (0.15 + 0.30 * sec) + (0.25 + 0.30 * sec) * env
    bi = lat.beat_idx(t)
    if lat.bphase(t) < 40 and (bi % 4 == 3 if sec < 0.5 else bi % 2 == 1):
        _white(dmx)                                   # unified flash — density rises
    else:
        for i, ch in enumerate(ALL_LIGHTS):
            hue = ((bi * 0.13) + i / len(ALL_LIGHTS)) % 1.0
            put(dmx, ch, hsv(hue, 1.0, bright))

@effect("upulse")
def fx_upulse(dmx, t, cue, lat):
    """DARK-GAP build pulse: whole room breathes ON together on the grid.
    p: grid("beat"|"eighth"), decay [a,b]|x, vmax [a,b]|x, sat [a,b]|x,
       hue {"mode":"fixed","h":..} | {"mode":"beat_cycle","step":..}
           | {"mode":"drift","h0":..,"span":..,"domain":[a,b]},
       domain [a,b] (ramp reference, default cue window),
       flash {"mod":m,"idx":[..],"width":40} (optional unified white flash)."""
    p = cue["p"]
    u = _u(t, cue, p)
    hp = p.get("hue", {"mode": "fixed", "h": 0.0})
    if hp["mode"] == "fixed":
        hue = hp["h"]
    elif hp["mode"] == "beat_cycle":
        hue = (lat.beat_idx(t) * hp.get("step", 0.13)) % 1.0
    else:                                             # drift
        d0, d1 = hp["domain"]
        hue = hp["h0"] + hp["span"] * clamp((t - d0) / (d1 - d0))
    fl = p.get("flash")
    if fl and lat.beat_idx(t) % fl["mod"] in fl["idx"] and lat.bphase(t) < fl.get("width", 40):
        _white(dmx)
        return
    grid = lat.grid_ms(p.get("grid", "beat"))
    env = math.exp(-(lat.bphase(t) % grid) / _lerp(u, p.get("decay", 100.0)))
    rgb = hsv(hue, _lerp(u, p.get("sat", 1.0)), _lerp(u, p.get("vmax", 0.5)) * env)
    for ch in ALL_LIGHTS:
        put(dmx, ch, rgb)

@effect("roll")
def fx_roll(dmx, t, cue, lat):
    """Accelerating full-room white flashes out of BLACK (terminal riser).
    p: p0(230), slope(140), ref_dur(900), pmin(80), width(40)."""
    p = cue["p"]
    times = p.get("_times")
    if times is None:                                 # precompute once per cue
        times, x = [], float(cue["t0"])
        while x < cue["t1"]:
            times.append(x)
            x += max(p.get("pmin", 80.0),
                     p.get("p0", 230.0) - p.get("slope", 140.0) * (x - cue["t0"]) / p.get("ref_dur", 900.0))
        p["_times"] = times
    if any(ft <= t < ft + p.get("width", 40) for ft in times):
        _white(dmx)
    # else: TRUE BLACK — accelerating flash/black into the drop

# ---- drop / intense effects (DARK-GAP core) ----------------------------
@effect("stutter_pulse")
def fx_stutter_pulse(dmx, t, cue, lat):
    """Drop DNA 1: multi-window stutter per beat, colors alternate per bar.
    p: hit, windows [[a,b],..] (ms within beat), colors ["white"|[h,s,v],..],
       dark [[a,b],..] (absolute darkness accents)."""
    p = cue["p"]
    if _drop_hit(dmx, t, p.get("hit", cue["t0"])):
        return
    for a, b in p.get("dark", []):
        if a <= t < b:
            return                                    # measured darkness accent
    ph = lat.bphase(t)
    if any(a <= ph < b for a, b in p["windows"]):
        c = p["colors"][lat.bar(t, p.get("hit", cue["t0"])) % len(p["colors"])]
        _pulse(dmx, (255, 255, 255) if c == "white" else hsv(*c))
    # else: TRUE BLACK — the dark gap IS the strobe feeling

@effect("gated_pulse")
def fx_gated_pulse(dmx, t, cue, lat):
    """The v6 workhorse: whole-room gated pulses with TRUE BLACK between.
    p: bar_anchor, grid, width, v, hues [h,..] (bar-indexed) | hue_drift
       {"h0":..,"per_ms":..,"from":..}, color_by ("bar"|"pulse"),
       white_slam (bool, white on beat_idx%4==0 & bphase<slam_width),
       slam_width(60), strobe_bars [..] | strobe_mod [m,[..]] (+ strobe
       {"v":..,"ceiling":..}), burst {"mod":[m,[..]],"grid":..,"width":..},
       hit (entrance slam ms)."""
    p = cue["p"]
    if "hit" in p and _drop_hit(dmx, t, p["hit"]):
        return
    anchor = p.get("bar_anchor", cue["t0"])
    bar = lat.bar(t, anchor)
    sb = p.get("strobe", {})
    if bar in p.get("strobe_bars", []) or (
            "strobe_mod" in p and bar % p["strobe_mod"][0] in p["strobe_mod"][1]):
        _tuned_strobe(dmx, t, sb.get("v", 0.90), sb.get("ceiling", 0.0))
        return
    grid_name, width = p.get("grid", "beat"), p.get("width", 100)
    bu = p.get("burst")
    if bu and bar % bu["mod"][0] in bu["mod"][1]:
        grid_name, width = bu.get("grid", "eighth"), bu.get("width", 65)
    gate = lat.bphase(t) % lat.grid_ms(grid_name) if grid_name == "eighth" else lat.bphase(t)
    if gate < width:
        if p.get("white_slam") and lat.beat_idx(t) % 4 == 0 and lat.bphase(t) < p.get("slam_width", 60):
            _pulse(dmx, (255, 255, 255))
        elif "hue_drift" in p:
            hd = p["hue_drift"]
            hue = (hd["h0"] + (t - hd["from"]) * hd["per_ms"]) % 1.0
            _pulse(dmx, hsv(hue, 1.0, p.get("v", 0.90)))
        else:
            idx = lat.eighth_idx(t) if p.get("color_by") == "pulse" else bar
            _pulse(dmx, hsv(p["hues"][idx % len(p["hues"])], 1.0, p.get("v", 0.90)))
    # else: TRUE BLACK

@effect("strobe")
def fx_strobe(dmx, t, cue, lat):
    """Hue tuned strobe block. p: v, ceiling."""
    _tuned_strobe(dmx, t, cue["p"].get("v", 0.90), cue["p"].get("ceiling", 0.0))

@effect("hit_black")
def fx_hit_black(dmx, t, cue, lat):
    """Full-white entrance slam, then TRUE BLACK — the hardware strobe
    (device cue) owns the room alone. p: hit."""
    _drop_hit(dmx, t, cue["p"].get("hit", cue["t0"]))
