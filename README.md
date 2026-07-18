# lightshow

Human-designed, second-accurate light shows on Philips Hue — plus a fog machine
as a show cue. Designed in **xLights**, streamed live through a custom
**Art-Net → Hue Entertainment API** bridge running on `atlas` (home server).

No beat detection. Every cue is authored by hand on a timeline against the
song's waveform, then played back frame-accurately at 25 fps.

## Architecture

```
xLights (Mac)                      atlas                         Hue Bridge
┌─────────────┐   Art-Net/UDP   ┌──────────────┐   DTLS-PSK    ┌──────────┐   Zigbee
│  timeline,  │ ──────────────▶ │ hue_stream.py│ ─────────────▶│Entertain-│ ────────▶ bulbs
│  audio,     │    :6454        │ (bridge)     │  UDP :2100    │ment API  │  25 fps
│  effects    │                 └──────────────┘               └──────────┘
└─────────────┘                 ┌──────────────┐
                                │ Arduino Uno  │ ──▶ RF remote (button held,
                                │ fog/fog.ino  │     5V power switched by D8)
                                └──────────────┘ ──▶ fog machine 💨
```

Why a custom bridge: the Hue **Entertainment API** streams the whole light
group at up to 25 updates/sec over DTLS (the normal REST API manages ~10/sec,
one bulb at a time — useless for shows). The existing open-source
Art-Net bridges either use the slow API or ship broken DTLS stacks, so
`hue_stream.py` does it directly: Art-Net in, `openssl s_client -dtls1_2`
with PSK out. Zero exotic dependencies — Python stdlib + openssl.

## Files

| File | What |
|---|---|
| `hue_stream.py` | The bridge: listens for Art-Net DMX on `:6454`, maps channels to the Hue entertainment group `LightShow` (v1 group 201), streams via DTLS |
| `artnet_test.py` | Sends a 10 s rainbow chase as Art-Net to localhost — pipeline test without xLights |
| `fog/fog.ino` | Arduino Uno sketch: waits on serial, `<ms>\n` → powers the RF remote via D8 for that many ms (button is held mechanically) → fog burst |
| `fog/fog_trigger.py` | Fire fog from atlas: `python3 fog_trigger.py 800` |
| `credentials.example.json` | Shape of the required `credentials.json` (real one is gitignored) |

## DMX channel map (universe 0, 1-based)

| Channels | Light (v1 id) | Name |
|---|---|---|
| 1–3 | 17 | Deckenlampe (color bulb) |
| 4–6 | 13 | Display (Hue Play, was "Grün") |
| 7–9 | 20 | Regal-Strip |
| 10–12 | 16 | Schreibtisch-Strip |
| 13–15 | 12 | Display (Hue Play, was "Rot") |
| 16–18 | 23 | Regal-Strip |

Order = light order of entertainment group 201 (`LightShow`) on the bridge.

## Running

```bash
# on atlas
cd ~/projects/lightshow
python3 -u hue_stream.py          # enables streaming, DTLS handshake, listens on :6454
python3 artnet_test.py 10         # (other shell) 10s rainbow to verify

# fog burst (Arduino on /dev/ttyACM0)
python3 fog/fog_trigger.py 800    # 800 ms fog
```

Stop the bridge with Ctrl+C / SIGTERM — it disables streaming mode cleanly
(otherwise the lights stay under stream control for ~10 s until the bridge
side times out).

## xLights setup (Mac)

- Controller: **Art-Net**, unicast to atlas (`atlas.your-tailnet.ts.net` /
  `192.168.1.100`), universe **0**, 18 channels.
- Models: six 1-node RGB models on the channels above, grouped for the layout.
- Sequence at 40 ms frame time (25 fps) to match the Hue Entertainment rate.

## Pairing / credentials

`credentials.json` needs the **username + clientKey pair created together**
during a single press-the-bridge-button pairing (`generateclientkey: true`).
The clientKey is only revealed once at pairing and is the DTLS-PSK secret;
identity = username. Group is the v1 id of the entertainment group.

## Hardware notes

- Fog machine: cheap 500 W with 315 MHz RF remote (HS2260A-R4 encoder, 12 V
  battery). The remote runs fine at 5 V, so the Arduino powers it directly
  from a GPIO pin (~15 mA) — button fixed down mechanically, power = fog.
  Max burst capped at 10 s in the sketch.
- Hue white bulbs can't join Entertainment groups (color-capable only).
- 25 fps is smooth for fades/chases; hard strobes beyond ~12 Hz won't resolve.
