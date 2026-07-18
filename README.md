# lightshow – Hand-crafted Hue light shows, frame by frame

[![Python](https://img.shields.io/badge/Python-3.12+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![Arduino](https://img.shields.io/badge/Arduino-Uno%20R3-00979D?style=flat&logo=arduino&logoColor=white)](https://www.arduino.cc)
[![xLights](https://img.shields.io/badge/xLights-2024.02-purple?style=flat)](https://xlights.org)
[![Hue](https://img.shields.io/badge/Philips%20Hue-Entertainment%20API-0065D3?style=flat)](https://developers.meethue.com)

**lightshow** turns a Philips Hue setup into a stage rig: shows are designed
second-accurately on an audio timeline in **xLights**, then streamed live at
25 fps through a custom **Art-Net → Hue Entertainment** bridge running on
`atlas` (home server) — including a **fog machine** fired as a timeline cue
via an Arduino. No beat detection, every cue is authored by hand.

---

## Architecture

```
xLights (Mac)                      atlas                          Hue Bridge
┌─────────────┐   Art-Net/UDP   ┌─────────────────┐   DTLS-PSK   ┌──────────┐  Zigbee
│  timeline,  │ ──────────────▶ │ bridge/         │ ────────────▶│Entertain-│ ───────▶ 6 lights
│  audio,     │    :6454        │ hue_stream.py   │  UDP :2100   │ment API  │  25 fps
│  effects    │   (19 ch)       │                 │              └──────────┘
└─────────────┘                 │   ch 19 ──▶ serial ──▶ Arduino ──▶ RF remote ──▶ fog 💨
                                └─────────────────┘
```

Why a custom bridge: the Hue **Entertainment API** streams the whole light
group at 25 updates/sec over DTLS (the REST API manages ~10/sec, one bulb at
a time). Existing open-source Art-Net bridges either use the slow API or ship
broken DTLS stacks — `hue_stream.py` talks DTLS directly through
`openssl s_client` with PSK. Python stdlib only.

---

## Repository layout

| Path | What |
|---|---|
| `bridge/hue_stream.py` | The bridge: Art-Net in (`:6454`), Hue Entertainment + fog out |
| `bridge/artnet_test.py` | 10 s rainbow chase — pipeline test without xLights |
| `bridge/credentials.example.json` | Shape of the gitignored `bridge/credentials.json` |
| `fog/fog.ino` | Arduino Uno sketch (heartbeat protocol, fail-safe auto-off) |
| `fog/fog_trigger.py` | Standalone fog burst: `python3 fog_trigger.py 800` |
| `xlights_networks.xml` | xLights controller: Art-Net unicast → atlas, universe 0, 19 ch |
| `xlights_rgbeffects.xml` | xLights models, groups (`ALLE`, `REGALE`) and layout |

The repo root **is** the xLights show directory — sequences (`.xsq`) and
songs live here too. xLights backups and render output are gitignored.

---

## DMX channel map (universe 0)

| Channels | Fixture | Hue light (v1 id) |
|---|---|---|
| 1–3 | Deckenlampe | 17 |
| 4–6 | Display · pixel 1 | 13 (Play bar) |
| 7–9 | Regal Hinten | 20 |
| 10–12 | Regal Links | 16 |
| 13–15 | Display · pixel 2 | 12 (Play bar) |
| 16–18 | Regal Rechts | 23 |
| 19 | **Nebelmaschine** — value ≥ 50 % = fog on | – |

Both Hue Play bars are merged into one 2-pixel xLights model **Display**.
Channel order = light order of entertainment group 201 (`LightShow`).

---

## Running a show

```bash
# 1. start the bridge on atlas
ssh atlas
cd ~/projects/lightshow && python3 -u bridge/hue_stream.py

# 2. in xLights (Mac): open the sequence, enable "Output To Lights", press play
```

Stop the bridge with `Ctrl+C` — it turns fog off and disables streaming
cleanly. While the bridge runs, the lights are under stream control.

Quick test without xLights: `python3 bridge/artnet_test.py 10` (rainbow).

---

## Fog machine

Cheap 500 W fog machine with a 315 MHz RF remote (HS2260A encoder). The
remote runs on 5 V from the Arduino instead of its 12 V battery, its fog
button is fixed down mechanically, and Arduino pin **D8 switches the
remote's power** — power on = transmitting = fog.

Serial protocol (9600 baud): `1` = fog on (auto-off after 1.5 s without
refresh — fail-safe if the bridge dies), `0` = fog off. The bridge
heartbeats `1` every 200 ms while DMX channel 19 ≥ 128.

Flash the sketch (one-time, from atlas):
```bash
arduino-cli compile --fqbn arduino:avr:uno ~/projects/lightshow/fog
arduino-cli upload -p /dev/ttyACM0 --fqbn arduino:avr:uno ~/projects/lightshow/fog
```

---

## Pairing / credentials

`bridge/credentials.json` needs a **username + clientKey created together**
in one press-the-bridge-button pairing (`generateclientkey: true`). The
clientKey is shown exactly once and is the DTLS-PSK secret; identity =
username; `group` = v1 id of the entertainment group.

---

## Notes

- Only **color-capable** Hue lights can join Entertainment groups.
- 25 fps is smooth for fades and chases; strobes beyond ~12 Hz won't resolve.
- Sequence frame time: **40 ms (25 fps)** to match the Hue streaming rate.

---

Developed by [Luka Löhr](https://github.com/luka-loehr)
