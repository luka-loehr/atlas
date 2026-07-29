# lightshows — beat-locked light shows for any song

Give it an MP3 (or a YouTube URL) and it produces and plays a complete light
show: the song is analyzed once on a GPU host (**Beat This!** transformer +
librosa), a rules engine compiles the analysis into a frame-accurate 25 fps
sequence built on a hand-tuned design language, and a player streams it over
Art-Net to a custom bridge that drives six Philips Hue color lights via the
Entertainment API (DTLS) plus physical hardware: a fog machine (Arduino +
RF remote), a laser and a hardware strobe on Hue smart plugs.

There is no beat detection at runtime. Analysis fits a constant-tempo beat
lattice to the whole song; every cue sits on that grid. Device physics
(strobe/laser warm-up, fog only in lit phases) is solved at compile time.

```
song.mp3 / URL ──► GPU host: Beat This! + librosa ──► analysis.json (cached)
                                                          │
                              engine/compiler (v6 rules)   ▼
play.py ◄──── shows/<name>.show.json ◄─────────────── makeshow.py
   │
   ▼ Art-Net (UDP :6454, universe 0, 21 ch, 25 fps)
bridge host: bridge/hue_stream.py ──► Hue Entertainment (DTLS-PSK, :2100)
                                  ├─► serial ──► Arduino ──► RF remote ──► fog
                                  ├─► Hue plug: laser  (3.9 s warm-up)
                                  └─► Hue plug: strobe (6.5 s warm-up)
```

An optional AI path (`--ai`) replaces the rules engine: Gemini listens to the
audio and describes the music, then a headless Claude Code session composes
the full show JSON from the measured analysis plus that context.

## The design language (v6 "dark-gap")

Ear-tested core insight: the strobe "high" only happens when **all fixtures
pulse ON together and OFF together** — true black between pulses. One lamp
filling another's gap keeps the room lit and kills the low-FPS strobe effect.

| musical event | compiled effect |
|---|---|
| show start | 20 s pure-fog pre-roll (dark, silent) → 5 s white slab → gradient |
| build into a drop | `upulse` escalation (beat → 8th grid, gaps darken) → accelerating `roll` → 0.8–2.6 s true-black gap |
| drop | rotating DNA: triple stutter / per-8th flicker / fat beat slams |
| peak drop after silence | white hit → 10 s hardware-strobe SOLO, all Hue black |
| high (chorus) | `gated_pulse` + white slams, occasional 8th bursts |
| quiet / breakdown | heartbeat, dim textures |

`engine/effects.py` implements 20 registered effects; `engine/compiler.py`
encodes the rules and the device constraint solver: strobe **6.5 s** / laser
**3.9 s** warm-up (pre-powered via window leads, windows merged where a
re-strike is physically impossible), fog only in lit phases — the disco globe
must never spin in darkness.

## DMX channel map (universe 0)

| Channels | Fixture |
|---|---|
| 1–3 | ceiling lamp (`DECKE`) |
| 4–6 | display pixel 1 (Hue Play bar) |
| 7–9 | shelf back (`REGAL_HINT`) |
| 10–12 | shelf left (`REGAL_LINK`) |
| 13–15 | display pixel 2 (Hue Play bar) |
| 16–18 | shelf right (`REGAL_RECH`) |
| 19 | fog machine (≥ 50 % = on, via Arduino serial heartbeat) |
| 20 | laser (Hue smart plug) |
| 21 | hardware strobe (Hue smart plug) |

Why a custom bridge: the Hue Entertainment API streams the whole group at
25 fps over DTLS (the REST API manages ~10 requests/s, one bulb at a time).
`bridge/hue_stream.py` talks DTLS directly through an `openssl s_client`
subprocess with PSK — Python stdlib only — and peak-holds Art-Net frames
per output tick so single-frame flashes never get lost between the two
independent 25 fps clocks.

## Repository layout

```
engine/           the production system (stdlib only)
  rig.py          channel map, Art-Net target, color helpers
  lattice.py      beat math (bpm + anchor -> phase/index/envelope)
  effects.py      20 modular effects (gated_pulse, stutter_pulse, upulse, roll, ...)
  sequence.py     .show.json format + validation
  player.py       generic 25 fps Art-Net renderer/player
  compiler.py     analysis.json -> show.json (rules + device solver)
analyze/          analyze_song.py + requirements.txt — run on the GPU host
                  (the venv at analyze/.venv is not in the repo)
ai/               ai_show.py — optional Gemini + Claude composer (--ai)
makeshow.py       CLI: song/URL -> analysis (cached) -> compiled show
play.py           CLI: play a .show.json
bridge/           hue_stream.py (bridge host): Art-Net -> Hue DTLS + devices,
                  credentials.example.json, lightshow-bridge.service
hardware/         fog.ino — Arduino heartbeat fog trigger, fail-safe auto-off
shows/            one .show.json per show, plus a .summary.md for --ai runs
analyses/         one measured analysis per analysed song, keyed by show slug
scripts/          port_party_rock.py — regenerates the reference show JSON
tests/            golden.py + reference_show_v6.py (frame-parity proof)
tools/            artnet_test.py, fog_trigger.py, beat_cal.py, make_calibration.py
```

`analyses/` is tracked on purpose and is not scratch: re-deriving one file
needs the original audio *and* a CUDA host, so these are the only surviving
copy of each measurement. `makeshow.py` short-circuits on a present analysis
rather than re-running the GPU stage. It writes `shows/<slug>.show.json` and
`analyses/<slug>.analysis.json` from the same slug — `slug()` lowercases
`--title` (or the audio filename) and maps every non-alphanumeric character
to `-` — so the two stems must stay byte-identical or the short-circuit
stops finding the cache and silently re-runs the GPU stage.

### What is in `shows/`

Nine shows are tracked. Only the seven that went through the analyzer have an
entry in `analyses/`; the other two are generated, not measured.

| show | produced by | analysis | `meta.song_file` |
|---|---|---|---|
| `party-rock` | `scripts/port_party_rock.py` — the hand-designed v6 reference | — | `music.mp3` |
| `party-rock-anthem-auto` | `makeshow.py` on the same track, rules engine | yes | `music.mp3` |
| `calibration` | `tools/make_calibration.py` — synthetic click track | — | `calibration.wav` |
| `darude-sandstorm` | `makeshow.py` | yes | `darude-sandstorm.mp3` |
| `dj-snake-selena-gomez-ozuna-cardi-b-taki-taki-letra-lyrics` | `makeshow.py` | yes | same stem `.mp3` |
| `james-hype-miggy-dela-rosa-ferrari-lyric-video` | `makeshow.py --ai` (ships the `.summary.md`) | yes | same stem `.mp3` |
| `lmfao-party-rock-anthem-ft` | `makeshow.py` | yes | same stem `.mp3` |
| `travis-scott-fe-n-ft` | `makeshow.py` | yes | `travis-scott-fe-n-ft.mp3` |
| `fein-final` | `makeshow.py` on the same track, second cut | yes | `fein-final.mp3` |

Two pairs share a track and are **not** duplicates of each other:

- `party-rock` and `party-rock-anthem-auto` are the hand-designed reference
  and the compiled one, which is the whole point of the golden test.
- `travis-scott-fe-n-ft` and `fein-final` are two choreographies of FE!N.
  Both carry 29 cues, but 17 of them differ, and `fein-final` drives eleven
  fog windows where the other drives seven. Their analyses are byte-identical
  because the analyzer is deterministic and the input audio is the same file —
  that is the measurement being reused, not a duplicated show.

Audio is not part of the repo. It lives in the **media root** —
`ATLAS_LIGHTSHOW_MEDIA_DIR`, default `/var/lib/atlas/lightshow-media` — which
is deliberately outside the checkout, so `git clean -fdx` cannot delete it.
`shows/` holds only the tracked `.show.json` / `.summary.md`.

`meta.song_file` is a bare basename resolved against the media root (an
absolute path is used as-is) — it is the source of truth, so a show whose
audio is shared with another one names that file rather than its own slug.
Supply your own audio by dropping it in there under the name the show asks
for: `party-rock` and `party-rock-anthem-auto` both expect `music.mp3`.
Readers still fall back to `shows/` for legacy files, but nothing writes
there — `makeshow.py` copies new audio and covers straight to the media root.
See `docs/SETUP.md` section 9.

## Setup

OS-level setup of the GPU/bridge machine (Ubuntu, CUDA, Docker, SSH/Wake-on-LAN)
is covered in [docs/SETUP.md](../docs/SETUP.md). Subsystem-specific steps:

1. **Deploy the repo on the GPU/bridge host.** `makeshow.py` hardcodes one
   thing: the SSH alias `atlas` (constant `ATLAS` at the top of the file) —
   create a matching `~/.ssh/config` alias or edit the constant. The remote
   checkout path is configurable: `LIGHTSHOW_REMOTE_DIR`, default
   `~/atlas/lightshows`. Only `analyze/` is used there — the song is scp'd
   in, analysed and deleted again; nothing is synced back but the JSON.
2. **Analysis venv on the GPU host** at `analyze/.venv`, from
   `analyze/requirements.txt` (`numpy`, `librosa`, `beat_this` — install
   CUDA-enabled PyTorch first). The Beat This! checkpoint `final0` is
   fetched by the library on first use.
3. **Hue pairing.** Copy `bridge/credentials.example.json` to
   `bridge/credentials.json` (gitignored) and fill in: the bridge IP, a
   whitelist username created with `generateclientkey:true` (the response
   also returns the DTLS `clientKey`), and the v1 id of an Entertainment
   group containing the six color lights.
4. **Adapt the rig constants** at the top of `bridge/hue_stream.py`:
   `LIGHT_ORDER` (six Hue v1 light ids in DMX channel order), `LASER_V1` and
   `STROBEPLUG_V1` (smart-plug v1 ids), `FOG_PORT` (default `/dev/ttyACM0`).
   The bridge host needs the `openssl` CLI with DTLS 1.2 +
   `PSK-AES128-GCM-SHA256` support; `pyserial` is optional (fog is disabled
   gracefully without it).
5. **Fog hardware** (optional): flash `hardware/fog.ino` onto an Arduino Uno;
   pin D8 switches the power of the fog machine's RF remote (button held
   down mechanically). The serial heartbeat (`'1'` = on, auto-off after
   1500 ms without refresh; `'0'` = off) makes fog fail-safe if the bridge
   dies mid-show.
6. **Control machine:** Python 3 only for compiling and playing
   (`engine` is stdlib-only). URL ingestion needs `yt-dlp` + `ffmpeg`.
   Audio playback uses `afplay` (macOS) from show start and `ffplay` for
   seeks — on Linux, seek playback works, full playback needs `--no-audio`
   or `afplay`-equivalent tweaks.
7. **Point the player at the bridge:** set `ATLAS_ARTNET_HOST` or write the
   bridge host's IP into `lightshows/artnet_host.local` (gitignored,
   single line).

## Running

```bash
# on the bridge host — must be running during playback
python3 -u bridge/hue_stream.py

# on the control machine, in lightshows/
python3 makeshow.py path/to/song.mp3                  # analyze (cached) + compile
python3 makeshow.py "https://youtube.com/watch?v=..." # yt-dlp -> downloads/ -> show
python3 makeshow.py song.mp3 --bpm 128 --extreme      # densified lattice, more strobe/fog
python3 makeshow.py song.mp3 --ai                     # Gemini listens + Claude composes
python3 play.py shows/<name>.show.json                # 20 s fog pre-roll, then show
python3 play.py shows/<name>.show.json 54 62          # seek 54–62 s (no pre-roll)
python3 play.py shows/<name>.show.json --no-audio     # lights only
```

`makeshow.py` flags:

| flag | effect |
|---|---|
| `--force` | re-run the GPU analysis, ignore the cache |
| `--title "..."` | override the title (and the output slug) |
| `--bpm N` | official BPM: densify the fitted lattice by an integer factor (accepted if within 5 %) |
| `--extreme` | denser strobes, full brightness, more fog |
| `--local` | run the analysis on this machine (use when running on the GPU host itself) |
| `--ai` | AI composer instead of the rules engine (see below) |

`play.py` accepts optional `start_s end_s` positionals plus `--no-preroll`
(skip the fog pre-roll) and `--no-audio` (lights only, audio plays
elsewhere). If the song file is missing, it warns and plays lights only.

The hand-designed reference show: `python3 play.py shows/party-rock.show.json`.

### AI mode (`--ai`)

Runs on the machine executing `makeshow.py` and needs two things: a Gemini
API key (`GEMINI_API_KEY`, or a key file — see configuration) and an
authenticated Claude Code CLI at `~/.local/bin/claude`. Gemini
(`gemini-flash-latest`, native audio) receives the base64-encoded MP3 and
returns genre/mood/sections/key moments as JSON; Claude (headless
`claude -p --model claude-sonnet-5`) gets the full design-language system
prompt, the slimmed measured analysis and Gemini's context, streams its
thinking as `AI:` ticker lines, and outputs the complete show JSON
(validated, up to 3 attempts; device windows get warm-up/merge
post-processing). A German prose summary is written to
`shows/<name>.summary.md`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_ARTNET_HOST` | `artnet_host.local` file, else `192.168.1.100` | Host running `bridge/hue_stream.py`; Art-Net UDP target of player and tools |
| `ATLAS_LIGHTSHOW_MEDIA_DIR` | `/var/lib/atlas/lightshow-media` | Media root: where audio and covers are read and written (outside the checkout) |
| `LIGHTSHOW_REMOTE_DIR` | `~/atlas/lightshows` | `makeshow.py`: the checkout path on the GPU host it scp/ssh's the analysis into |
| `ATLAS_AUTOPUSH` | unset (off) | `1` = auto `git commit` + `push` each newly compiled show (off by default: downloaded audio/thumbnails may not be redistributable) |
| `GEMINI_API_KEY` | unset | Gemini API key for `--ai` (takes precedence over the key file) |
| `ATLAS_GEMINI_KEY_FILE` | `~/.config/atlas-ai/gemini.key` | Fallback key-file path for `--ai` |
| `ARTNET_BIND` | `0.0.0.0` | `bridge/hue_stream.py`: interface the Art-Net listener binds |
| `ARTNET_IDLE_TIMEOUT` | `180` | `bridge/hue_stream.py`: seconds without a frame before it releases the group and returns to IDLE |

File-based configuration:

- `artnet_host.local` (repo root of this subsystem, gitignored) — single
  line with the bridge host IP/hostname; alternative to `ATLAS_ARTNET_HOST`.
- `bridge/credentials.json` (gitignored) — Hue bridge host, whitelist
  username, DTLS `clientKey`, Entertainment group id.
- `calibration.json` (gitignored) — `{"audio_latency_ms": N}`; when present,
  overrides the latency baked into every show's meta (see calibration).

> On atlas all three are **symlinks**; the real files live in `/etc/atlas`
> and `/var/lib/atlas` so that `git clean -fdx` in the checkout deletes a
> link rather than the credentials the running `lightshow-bridge.service`
> loads at startup. Mapping and rationale: [docs/SETUP.md section 9](../docs/SETUP.md).
> Edit the file through the symlink as usual — reads and writes both follow it.
- Constants in code: `ATLAS` in `makeshow.py` (the SSH alias),
  `LIGHT_ORDER`/`LASER_V1`/`STROBEPLUG_V1`/`FOG_PORT` in
  `bridge/hue_stream.py`, `~/.local/bin/claude` + `claude-sonnet-5` in
  `ai/ai_show.py`.

### Show file format (`.show.json`, version 1)

```jsonc
{
 "version": 1,
 "meta": {
   "song_file": "music.mp3",        // basename, resolved in the media root
   "title": "...", "bpm": 130.0, "anchor_ms": 59700.0, "duration_ms": 260400,
   "audio_latency_ms": 300,         // playback-device calibration
   "laser_lead_ms": 3900, "strobe_lead_ms": 6500,
   "preroll_fog_ms": 20000,
   "calibration": true              // optional: this show MEASURES latency,
                                    // so play.py runs it raw and ignores
                                    // lightshows/calibration.json
 },
 "cues":    [{"t0": 0, "t1": 5000, "fx": "solid", "p": {"color": "white"}}],
 "accents": [[75840, 0.85]],        // single-frame white max-blend overlays
 "devices": {"fog": [[0, 5000]], "laser": [], "strobe": []}
}
```

Cues must be sorted and non-overlapping; gaps mean true black. Device
windows are visibility times — the player pre-powers laser/strobe by their
warm-up leads automatically.

## Calibration and tests

**Latency calibration.** Every show carries `audio_latency_ms` (default
300). Two ways to measure your own value:

- Camera flow: `python3 tools/make_calibration.py` regenerates
  `shows/calibration.show.json` (tracked) plus `calibration.wav` in the
  **media root** (1 kHz clicks, white flash on each click) — the `.wav` is
  not in the repo, so run this once before using the calibration show. Play
  it, measure the flash-vs-click offset (the companion iOS app does this
  with the phone camera) and write the result to
  `lightshows/calibration.json` — it then overrides every show except ones
  flagged `meta.calibration`.
- Ear flow: `python3 tools/beat_cal.py 300 [secs]` flashes the shelves on a
  fixed 130 BPM lattice while playing `tools/music.mp3`. Note: you must
  supply that file yourself, and the hardcoded lattice matches the reference
  track only — it is a rough tool.

**Tests.**

```bash
python3 tests/golden.py    # 7018-frame parity: modular player == frozen v6 engine
```

The golden test renders every 40 ms frame from −20.3 s to 260.4 s through
both the frozen legacy engine (`tests/reference_show_v6.py`) and the modular
`Player`, and requires byte-identical output. Pure `render()` — no network,
no audio. `scripts/port_party_rock.py` regenerates the hand-designed
reference sequence it runs against.

**Bridge smoke test** (on the bridge host — `artnet_test.py` sends Art-Net
to `127.0.0.1:6454`, `fog_trigger.py` drives the Arduino serial port
directly):

```bash
python3 tools/artnet_test.py [secs]     # 10 s rainbow chase by default
python3 tools/fog_trigger.py 800        # fog burst; only while hue_stream.py is NOT running
```

A show is verified either by rendering it — `tests/golden.py`, pure
`render()`, no network and no audio — or by playing it against the bridge.

## Operational notes

- **Analysis quality:** Beat This! (checkpoint `final0`, CUDA) beats +
  downbeats → robust constant-tempo fit (longest clean run + outlier
  rejection). Fits with > 25 ms residual are flagged and produce a compiler
  warning — the lattice may drift on live/rubato recordings. Drop detection
  scores sub-bass jump + long-window contrast + pre-drop dip, with a bonus
  for slams out of true silence.
- **Progress protocol:** `makeshow.py` and the AI composer emit
  machine-readable stdout markers for a companion UI: `PHASE:<stage>`
  (`download`/`analyze`/`gemini`/`claude`/`commit`/`done`), `TITLE:`,
  `THUMB:`, `SUMMARY:`, `AI:` (composer ticker) and `FAILED:` on errors,
  interleaved with yt-dlp progress lines.
- **Network exposure:** the bridge binds `0.0.0.0:6454` and accepts
  unauthenticated Art-Net from anyone who can reach it — and it drives
  physical hardware (fog, strobe, laser). Run it on a trusted/firewalled
  network only. The Hue DTLS PSK appears on the `openssl` command line
  (visible in local process listings), and Hue REST calls disable TLS
  verification (self-signed bridge certificate).
- **Fail-safes:** the Arduino auto-stops fog 1.5 s after the last heartbeat;
  the player ends every run with a guaranteed 3-frame blackout; the bridge
  switches laser/strobe plugs off synchronously on shutdown.
- **`--ai` uploads the full song audio** to the Gemini API — keep that in
  mind for material you are not allowed to share.

## A note on audio

The repo intentionally contains **no audio files** — shows ship as `.show.json`
choreography plus derived analysis data only. Use the YouTube/URL ingestion
only with content you have the rights to use.
