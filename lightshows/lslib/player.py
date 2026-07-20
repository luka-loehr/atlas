"""Generic sequence player — the one engine for every compiled show.

Renders a .show.json at 25fps to Art-Net: fog pre-roll, audio start,
cue timeline, accent overlays, device cues with warm-up pre-power.
"""
import bisect
import os
import shutil
import socket
import struct
import subprocess
import time

from .effects import EFFECTS
from .lattice import Lattice
from .rig import ARTNET_TARGET, FOG, FPS, LASER, NCHAN, STROBE_PLUG, STROBE_CH

def artnet(dmx, seq_no):
    if len(dmx) % 2:                                  # Art-Net requires even length
        dmx = bytes(dmx) + b"\x00"
    pkt = b"Art-Net\x00" + struct.pack("<H", 0x5000) + struct.pack(">H", 14)
    return pkt + bytes([seq_no & 0xff, 0]) + struct.pack("<H", 0) + struct.pack(">H", len(dmx)) + dmx

class Player:
    def __init__(self, seq):
        self.seq = seq
        self.meta = seq["meta"]
        self.lat = Lattice(self.meta["bpm"], self.meta["anchor_ms"])
        self.cues = seq.get("cues", [])
        self._starts = [c["t0"] for c in self.cues]
        self.accents = seq.get("accents", [])
        self.devices = seq.get("devices", {})
        self.laser_lead = self.meta.get("laser_lead_ms", 3900)
        self.strobe_lead = self.meta.get("strobe_lead_ms", 6500)
        self.preroll_ms = self.meta.get("preroll_fog_ms", 0)
        self.latency_ms = self.meta.get("audio_latency_ms", 0)

    # ---- pure frame renderer (also used by tests) -----------------------
    def render(self, t):
        dmx = bytearray(NCHAN)
        if t < 0:
            if self.preroll_ms and t >= -(self.preroll_ms + self.latency_ms):
                dmx[FOG] = 255                        # pre-roll: pure fog, dark, silent
            return bytes(dmx)

        i = bisect.bisect_right(self._starts, t) - 1
        if i >= 0 and t < self.cues[i]["t1"]:
            cue = self.cues[i]
            EFFECTS[cue["fx"]](dmx, t, cue, self.lat)

        for imp, strength in self.accents:            # single-frame max-blend overlays
            if imp <= t < imp + 40:
                v = int(255 * strength)
                for ch in STROBE_CH:
                    dmx[ch] = max(dmx[ch], v)
                    dmx[ch + 1] = max(dmx[ch + 1], v)
                    dmx[ch + 2] = max(dmx[ch + 2], v)
                break

        for a, b in self.devices.get("fog", []):
            if a <= t < b:
                dmx[FOG] = 255
        for a, b in self.devices.get("laser", []):
            if a - self.laser_lead <= t < b:
                dmx[LASER] = 255
        for a, b in self.devices.get("strobe", []):
            if a - self.strobe_lead <= t < b:
                dmx[STROBE_PLUG] = 255
        return bytes(dmx)

    # ---- live playback --------------------------------------------------
    def play(self, song_file, start_s=0.0, end_s=None, preroll=True):
        end_s = end_s if end_s is not None else self.meta["duration_ms"] / 1000.0
        play_audio = bool(song_file) and os.path.exists(song_file)
        preroll_s = (self.preroll_ms / 1000.0) if (preroll and start_s == 0) else 0.0

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        audio = None
        if play_audio and start_s > 0:
            if shutil.which("ffplay"):
                audio = subprocess.Popen(["ffplay", "-nodisp", "-autoexit",
                                          "-loglevel", "quiet", "-ss", str(start_s), song_file])
            else:
                play_audio = False
        if preroll_s:
            print(f"pre-roll: {preroll_s:.0f}s pure fog — dark & silent, the room fills ...",
                  flush=True)
        print(f"playing {start_s:.1f}s -> {end_s:.1f}s  |  audio={'yes' if play_audio else 'no'}"
              f"  |  {self.lat.bpm:.2f} BPM lattice (anchor {self.lat.anchor / 1000:.2f}s)",
              flush=True)

        seq_no = 0
        t0 = time.monotonic()
        next_t = t0
        try:
            while True:
                song_s = start_s + (time.monotonic() - t0) - preroll_s
                if song_s >= end_s:
                    break
                if play_audio and audio is None and song_s >= 0:
                    audio = subprocess.Popen(["afplay", song_file])
                song_ms = song_s * 1000.0 - (self.latency_ms if play_audio else 0)
                seq_no = (seq_no + 1) & 0xff
                try:
                    sock.sendto(artnet(self.render(song_ms), seq_no), ARTNET_TARGET)
                except OSError:
                    pass                              # network blip must not kill the show
                next_t += 1.0 / FPS
                time.sleep(max(0.0, next_t - time.monotonic()))
        finally:
            for _ in range(3):                        # guaranteed blackout + devices off
                seq_no = (seq_no + 1) & 0xff
                try:
                    sock.sendto(artnet(bytes(NCHAN), seq_no), ARTNET_TARGET)
                except OSError:
                    pass
                time.sleep(1.0 / FPS)
            if audio:
                audio.terminate()
        print("done", flush=True)
