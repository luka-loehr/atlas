# lightshow — beat-locked light shows for any song

[![Python](https://img.shields.io/badge/Python-3.12+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![Arduino](https://img.shields.io/badge/Arduino-Uno%20R3-00979D?style=flat&logo=arduino&logoColor=white)](https://www.arduino.cc)
[![Hue](https://img.shields.io/badge/Philips%20Hue-Entertainment%20API-0065D3?style=flat)](https://developers.meethue.com)

Give it an MP3 → it analyzes the song on a GPU server (**Beat This!** +
librosa), compiles a frame-accurate show from a hand-tuned design language,
and plays it at 25 fps: **Philips Hue Entertainment + fog machine (disco
globe) + laser + hardware strobe**. No beat-detection guessing at runtime —
every cue sits on a measured beat lattice.

```
song.mp3 ──► atlas (GPU): Beat This! + librosa ──► analysis.json (cached)
                                                        │
                            lslib/compiler (v6 rules)   ▼
play.py ◄──── shows/<name>.show.json ◄──────────── makeshow.py
   │
   ▼ Art-Net (UDP :6454, 25 fps, 21 ch)
atlas: bridge/hue_stream.py ──► Hue Entertainment (DTLS-PSK, :2100)
                             ├─► serial ──► Arduino ──► RF remote ──► fog 💨
                             ├─► Hue plug: laser   (3.9 s warm-up)
                             └─► Hue plug: strobe  (6.5 s warm-up)
```

## Quickstart

```bash
# one-time per session: the bridge must run on atlas
ssh atlas 'cd ~/projects/lightshow && python3 -u bridge/hue_stream.py'

# any song -> show (GPU analysis is cached after the first run)
python3 makeshow.py path/to/song.mp3
python3 play.py shows/<name>.show.json          # 20s fog pre-roll, then show
python3 play.py shows/<name>.show.json 54 62    # seek 54s-62s (no pre-roll)
```

The hand-designed reference: `python3 play.py shows/party-rock.show.json`

## The design language (v6 "dark-gap")

Ear-tested core insight: the strobe "high" only happens when **all fixtures
pulse ON together and OFF together** — true black between pulses. One lamp
filling another's gap keeps the room lit and kills the low-FPS effect.

| musical event | effect |
|---|---|
| show start | 20 s pure-fog pre-roll (dark, silent) → 5 s white slab → gradient |
| build | `upulse` escalation (beat → 8th, gaps darken) → accelerating roll |
| drop | dark-gap DNA, rotating: triple-stutter / per-8th flicker / fat slams |
| peak drop after silence | white hit → **10 s hardware-strobe SOLO**, all Hue black |
| high (chorus) | gated pulses + white slams on the slam phase |
| quiet / breakdown | heartbeat, dark textures |

Device physics is solved at compile time: strobe **6.5 s** / laser **3.9 s**
warm-up (pre-powered via cue leads, windows merged where a re-strike is
physically impossible), fog only in lit phases — the disco globe must never
spin in darkness.

## DMX channel map (universe 0)

| Channels | Fixture | Hue v1 id |
|---|---|---|
| 1–3 | Deckenlampe | 17 |
| 4–6 | Display · pixel 1 | 13 (Play bar) |
| 7–9 | Regal Hinten | 20 |
| 10–12 | Regal Links | 16 |
| 13–15 | Display · pixel 2 | 12 (Play bar) |
| 16–18 | Regal Rechts | 23 |
| 19 | Nebelmaschine (≥50 % = on) | – (Arduino) |
| 20 | Laser plug | 22 |
| 21 | Strobe plug | 25 |

Why a custom bridge: the Hue **Entertainment API** streams the whole group at
25 fps over DTLS (REST manages ~10/s, one bulb at a time). `hue_stream.py`
talks DTLS directly through `openssl s_client` with PSK — Python stdlib only —
and peak-holds Art-Net frames so single-frame flashes never get lost.

## Repo layout

```
lslib/            the production system
  rig.py          channel map + color helpers
  lattice.py      beat math (bpm + anchor -> phase/idx/env)
  effects.py      18 modular effects (pulse, gated_pulse, stutter, upulse, ...)
  sequence.py     .show.json format + validation
  player.py       generic 25 fps Art-Net renderer/player
  compiler.py     analysis.json -> show.json (archetypes + device solver)
analyze/          analyze_song.py — runs on atlas (GPU venv: analyze/.venv)
makeshow.py       CLI: mp3 -> atlas analysis (cached) -> compiled show
play.py           CLI: play a .show.json
shows/            compiled shows (party-rock.show.json = hand-designed v6)
analysis_cache/   cached per-song analyses
bridge/           hue_stream.py (atlas): Art-Net -> Hue DTLS + devices
scripts/          port_party_rock.py, export_fseq.py
tests/            golden.py + reference_show_v6.py (frame-parity proof)
tools/            beat_cal.py (latency), artnet_test.py, fog_trigger.py
hardware/         fog.ino (Arduino heartbeat fog trigger, fail-safe auto-off)
xlights/          xLights 3D room layout + legacy sequence (for previews)
```

## xLights preview

Every show is a sequence file — to watch one visually:

```bash
python3 scripts/export_fseq.py shows/<name>.show.json   # -> shows/<name>.fseq
```

Open the layout from `xlights/`, create a musical sequence with the song,
then *Sequence Settings → Data Layers →* import the `.fseq`
(21 channels, universe 0, 25 fps).

## Calibration, tests, analysis quality

```bash
python3 tools/beat_cal.py 300     # shelves flash on the beat at 300 ms latency
python3 tests/golden.py           # 7018-frame parity: player == v6 reference
```

- `audio_latency_ms` lives in each show's meta (300 = AirPods, ear-calibrated).
- Tempo: Beat This! beats → robust constant-lattice fit (longest clean run +
  outlier rejection). Reference track: **130.002 BPM, 8.4 ms residual**, all
  six known drops within 22 ms of the lattice.
- Drops: sub-bass jump + long-window contrast + pre-drop dip + silence bonus.
  Reference track: **6/6 known drops**, 1 musically defensible extra.
- Low-confidence tempo fits (>25 ms residual) produce a compiler warning —
  the lattice may drift on live/rubato recordings.
