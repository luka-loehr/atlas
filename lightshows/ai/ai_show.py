"""AI show composer — Gemini LISTENS to the song, Claude COMPOSES the show.

Runs on atlas (needs ~/.config/atlas-ai/gemini.key + Claude Code auth).

    from ai.ai_show import compose
    seq, summary = compose(analysis, song_path, title)

Pipeline:
  1. Gemini (native audio understanding) hears the mp3 -> genre, mood,
     instruments, vocals/lyrics, sections with lighting hints, key moments.
  2. Claude (headless `claude -p`) gets the FULL design knowledge (effect
     catalog, v6 dark-gap rules, device physics) + the measured analysis +
     Gemini's musical context, and writes the .show.json cues + a summary.
  3. Device windows get lead/merge post-processing; the sequence is
     validated; on validation errors Claude gets one retry with the error.
"""
import base64
import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from lslib import sequence  # noqa: E402

GEMINI_KEY_FILE = os.path.expanduser("~/.config/atlas-ai/gemini.key")
GEMINI_MODEL = "gemini-flash-latest"   # resolves to gemini-3.5-flash (native audio)
CLAUDE = os.path.expanduser("~/.local/bin/claude")
LASER_LEAD = 3900
STROBE_LEAD = 6500

# ---------------------------------------------------------------- Gemini ----

GEMINI_PROMPT = """You are a club lighting director listening to a song.
Analyze THIS AUDIO and answer as compact JSON:
{
 "genre": "...", "mood": "...", "language": "...",
 "instruments": ["..."],
 "vocals": "none|male|female|mixed — one line about the vocal style",
 "lyrics_summary": "2-3 sentences, what the song is about (if vocals)",
 "sections": [{"start_s": 0.0, "end_s": 30.5, "label": "intro|build|drop|verse|chorus|breakdown|bridge|outro",
               "energy": 0.0-1.0, "description": "what happens musically",
               "lighting_hint": "one concrete idea for the lights"}],
 "key_moments": [{"t_s": 62.1, "what": "vocal shout 'let's go' right before the drop"}],
 "overall_arc": "2 sentences: the dramaturgy of the whole song"
}
Cover the ENTIRE song with sections (no gaps). Times in seconds, precise."""


def gemini_listen(song_path):
    """Up to 3 attempts — flash occasionally emits broken JSON even in
    JSON mode; a light repair pass catches truncated/trailing-comma output."""
    with open(GEMINI_KEY_FILE) as f:
        key = f.read().strip()
    with open(song_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    body = {
        "contents": [{"parts": [
            {"text": GEMINI_PROMPT},
            {"inline_data": {"mime_type": "audio/mpeg", "data": audio_b64}},
        ]}],
        "generationConfig": {"response_mime_type": "application/json",
                             "temperature": 0.3,
                             "maxOutputTokens": 8192},
    }
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent?key={key}",
                data=json.dumps(body).encode(), method="POST",
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=300) as r:
                resp = json.load(r)
            text = resp["candidates"][0]["content"]["parts"][0]["text"]
            try:
                return json.loads(text)
            except ValueError:
                return json.loads(_repair_json(text))
        except Exception as e:
            last = e
            print(f"gemini: Versuch {attempt+1} fehlgeschlagen ({type(e).__name__}: {e}) — Retry",
                  flush=True)
    raise RuntimeError(f"gemini FAILED nach 3 Versuchen: {last}")


def _repair_json(text):
    """Best-effort fixes: strip fences/prose, drop trailing commas, close
    unterminated brackets/strings from truncated output."""
    m = re.search(r"\{.*", text, re.DOTALL)
    if m:
        text = m.group(0)
    text = re.sub(r",\s*([}\]])", r"\1", text)          # trailing commas
    # balance quotes then brackets (truncation)
    if text.count('"') % 2 == 1:
        text += '"'
    stack = []
    in_str = False
    esc = False
    for c in text:
        if esc:
            esc = False
            continue
        if c == "\\":
            esc = True
        elif c == '"':
            in_str = not in_str
        elif not in_str:
            if c in "[{":
                stack.append("]" if c == "[" else "}")
            elif c in "]}" and stack:
                stack.pop()
    text += "".join(reversed(stack))
    return text

# ---------------------------------------------------------------- Claude ----

SYSTEM_PROMPT = """You are the lighting designer for Luka's room rig. You write
complete light-show sequence files (.show.json v1). Output ONLY valid JSON, no
markdown fences, no commentary.

# The rig
6 Hue color lamps: ceiling (bright, room-filling), 2 display pixels, 3 shelf
lamps arranged in a circle. Plus DEVICE channels: fog machine, laser (needs
3900ms warm-up), hardware strobe (needs 6500ms warm-up, VERY bright).

# The ear-approved v6 "dark-gap" design language (NEVER soften this)
- The strobe "high" only happens when ALL lamps pulse ON together and OFF
  together with TRUE BLACK between pulses. Never fill one lamp's gap with
  another lamp.
- Before every drop: a blackout gap (0.8-2.6s of absolute darkness) — the
  loaded gun. Then the drop slams in at full brightness.
- Drops use rotating DNA: stutter_pulse (multi-window stutter) /
  gated_pulse with eighth burst / fat white slams. Full v=0.9-1.0.
- Builds escalate: upulse on beat -> eighth grid, gaps darkening, ending in a
  `roll` (accelerating white flashes out of black) that lands EXACTLY at the
  blackout before the drop.
- Quiet parts: heartbeat, dim textures (v 0.05-0.2) — contrast is everything.
- The strongest drop after a silent dip may get a hardware-strobe SOLO
  (strobe device window + hit_black cue: all Hue black, only the strobe runs).
- Fog: 1-2 bursts of 8-15s in LIT, energetic phases only (a disco globe must
  never spin in darkness). Never in quiet/dark sections.

# Sequence format (JSON you must output)
{"version":1,
 "meta":{"song_file":"<given>","title":"<given>","bpm":<given>,
         "anchor_ms":<given>,"duration_ms":<given>,"audio_latency_ms":300,
         "laser_lead_ms":3900,"strobe_lead_ms":6500,"preroll_fog_ms":20000},
 "cues":[{"t0":ms,"t1":ms,"fx":"<effect>","p":{...}}, ...],
 "accents":[[ms,strength 0-1], ...],
 "devices":{"fog":[[a,b],...],"laser":[[a,b],...],"strobe":[[a,b],...]}}
RULES: cues sorted by t0, non-overlapping, t0<t1, cover the song from 0 to
duration (gaps ARE allowed and mean TRUE BLACK — use them deliberately,
especially right before drops). Align t0/t1 to beat times: beat_ms = 60000/bpm,
beat k = anchor_ms + k*beat_ms. Device windows are the times the device should
be VISIBLE; warm-up leads are handled downstream — do NOT subtract them.

# Effect catalog (fx -> params p)
- solid: constant color all lamps. p:{"color":[h,s,v]} h 0-1, v 0-1
- intro_gradient: slow hue drift, gentle. p:{"h0":0.6,"h1":0.9,"v":0.25}
- fade: linear fade. p:{"channels":"regale","hue":0.7,"sat":1.0,"v0":0.3,"v1":0.0}
- dim_hold: constant dim color. p:{"channels":"regale","color":[h,s,v]}
- dim_pulse: dim beat pulse. p:{"channels":"regale","hue":0.7,"sat":1.0,"v":0.15,"decay":250}
- heartbeat: breakdown heartbeat on displays. p:{"period":2000,"decay":180,"hue":0.0,"v":0.08}
- wind_down: bar-walking fade-out. p:{"bar_anchor":t0,"hue":0.75,"v":0.15,"fade":0.85}
- upulse: THE build effect, whole room breathes together, ramps over the cue.
  p:{"grid":"beat"|"eighth","decay":[220,90],"vmax":[0.35,0.85],"sat":[1.0,0.85],
     "hue":{"mode":"beat_cycle","step":0.13} | {"mode":"fixed","h":0.62}
         | {"mode":"drift","h0":0.6,"span":0.3,"domain":[t0,t1]},
     "flash":{"mod":4,"idx":[0],"width":40}}   ([a,b] = ramp start->end)
- roll: accelerating white flashes out of black (last 0.9-1.6s of a build).
  p:{"p0":230,"slope":140,"ref_dur":900,"pmin":80,"width":40}
- stutter_pulse: drop DNA, stutter windows per beat.
  p:{"hit":t0,"windows":[[0,70],[120,190],[240,310]],
     "colors":["white",[0.0,1,1],[0.62,1,1]],"dark":[[a,b],...] optional}
- gated_pulse: THE chorus/drop workhorse, gated pulses + true black.
  p:{"bar_anchor":t0,"grid":"beat"|"eighth","width":100,"v":0.95,
     "hues":[0.62,0.0,0.83,0.33],"color_by":"bar"|"pulse",
     "white_slam":true,"slam_width":60,
     "strobe_mod":[4,[3]] optional (hue-strobe bars),
     "burst":{"mod":[4,[3]],"grid":"eighth","width":65} optional,
     "hit":t0 optional (entrance slam)}
- strobe: hue tuned strobe block. p:{"v":0.9}
- hit_black: white slam then TRUE BLACK (pair with strobe device window).
  p:{"hit":t0}
- blip / circle_tick / circle_walk / chase / rainbow_build / bridge_crossfade /
  outro_fade: transitional/verse textures, use sparingly. blip p:{"hue":0.6,"v":0.3}
  outro_fade p:{} rainbow_build p:{"v0":0.2,"v1":0.6}

# Accents
Single-frame white overlays for key moments (vocal shouts, impacts):
[[ms, 0.6-1.0], ...] — use the analysis impacts + Gemini key_moments. 5-25 total.

# Output
ADDITIONALLY include a top-level key "summary": 4-8 German sentences —
the dramaturgy you designed, section by section, referencing song moments.
(The summary key is stripped before saving, it's for the human.)"""


def _claude_json(user_prompt, retry_error=None):
    """Run claude -p with streaming output: thinking/text deltas are echoed
    live as AI: lines (the app shows them as a ticker), the final result is
    parsed as JSON."""
    prompt = user_prompt
    if retry_error:
        prompt += ("\n\nYOUR PREVIOUS OUTPUT FAILED VALIDATION:\n" + retry_error +
                   "\nFix it and output the corrected COMPLETE JSON.")
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.local/bin") + ":" + env.get("PATH", "")
    proc = subprocess.Popen(
        [CLAUDE, "-p", "--model", "claude-sonnet-5",
         "--append-system-prompt", SYSTEM_PROMPT,
         "--output-format", "stream-json", "--verbose",
         "--include-partial-messages"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, env=env)
    proc.stdin.write(prompt)
    proc.stdin.close()

    final = None
    buf = ""          # accumulate deltas, flush as one-liner ticker lines
    def flush(force=False):
        nonlocal buf
        parts = buf.split("\n")
        buf = parts.pop()                      # keep the last partial line
        for line in parts:
            if line.strip():
                print(f"AI:{line.strip()[:160]}", flush=True)
        while len(buf) > 110:                  # long single line -> chunks
            print(f"AI:{buf[:110]}", flush=True)
            buf = buf[110:]
        if force and buf.strip():
            print(f"AI:{buf.strip()[:160]}", flush=True)
            buf = ""

    for raw in proc.stdout:
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        t = ev.get("type")
        if t == "stream_event":
            delta = ev.get("event", {}).get("delta", {})
            piece = delta.get("thinking") or delta.get("text") or ""
            if piece:
                buf += piece
                flush()
        elif t == "result":
            final = ev.get("result", "")
    flush(force=True)
    proc.wait(timeout=60)
    if proc.returncode != 0 or final is None:
        err = proc.stderr.read()[-400:] if proc.stderr else ""
        raise RuntimeError(f"claude failed: {err}")
    m = re.search(r"\{.*\}", final, re.DOTALL)   # tolerate stray prose/fences
    if not m:
        raise RuntimeError(f"claude returned no JSON: {final[:200]}")
    return json.loads(m.group(0))


def _merge(windows, min_gap):
    out = []
    for a, b in sorted((float(a), float(b)) for a, b in windows):
        if out and a - out[-1][1] < min_gap:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def _postprocess_devices(seq):
    """Apply warm-up leads + merge windows a re-strike can't survive."""
    dev = seq.get("devices", {})
    out = {}
    if dev.get("fog"):
        out["fog"] = _merge(dev["fog"], 2000)
    if dev.get("laser"):
        out["laser"] = [[max(0, a - LASER_LEAD), b]
                        for a, b in _merge(dev["laser"], LASER_LEAD + 1000)]
    if dev.get("strobe"):
        out["strobe"] = [[max(0, a - STROBE_LEAD), b]
                         for a, b in _merge(dev["strobe"], STROBE_LEAD + 500)]
    seq["devices"] = out


def _slim_analysis(analysis):
    """Compact the analysis for the prompt (drop the big arrays)."""
    a = dict(analysis)
    for k in ("curves", "beats_ms", "downbeats_ms", "audio"):
        a.pop(k, None)
    # keep a ~1/s energy outline
    c = analysis.get("curves", {})
    rms, hop = c.get("rms"), c.get("hop_ms", 100)
    if rms:
        step = max(1, round(1000 / hop))
        a["energy_per_s"] = [round(v, 2) for v in rms[::step]]
    return a


def compose(analysis, song_path, title, song_file):
    print("PHASE:gemini", flush=True)
    print("gemini: hoert den Song ...", flush=True)
    music = gemini_listen(song_path)
    print(f"gemini: {music.get('genre','?')} | {music.get('mood','?')} | "
          f"{len(music.get('sections',[]))} Sektionen", flush=True)

    print("PHASE:claude", flush=True)
    print("claude: komponiert die Show ...", flush=True)
    tempo = analysis["tempo"]
    user = json.dumps({
        "task": "Compose the complete show for this song. Think through the "
                "dramaturgy carefully IN GERMAN before writing the JSON — "
                "your thinking is streamed live to the user's phone.",
        "meta_you_must_use": {
            "song_file": song_file, "title": title,
            "bpm": tempo["bpm"], "anchor_ms": tempo["fit_anchor_ms"],
            "duration_ms": int(analysis["duration_ms"]),
        },
        "measured_analysis": _slim_analysis(analysis),
        "musical_context_from_listening": music,
    })
    err = None
    for attempt in range(3):
        data = _claude_json(user, retry_error=err)
        summary = data.pop("summary", "")
        _postprocess_devices(data)
        data.setdefault("version", 1)
        try:
            sequence.validate(data, "<ai>")
            print(f"claude: {len(data.get('cues',[]))} Cues, "
                  f"{len(data.get('accents',[]))} Accents, ok "
                  f"(Versuch {attempt+1})", flush=True)
            return data, summary, music
        except Exception as e:
            err = str(e)
            print(f"claude: Validierung fehlgeschlagen ({e}) — Retry", flush=True)
    raise RuntimeError(f"AI show failed validation 3x: {err}")
