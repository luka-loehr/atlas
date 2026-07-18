#!/usr/bin/env python3
"""Audio structure analysis for the lightshow.

Decodes music.mp3 (via ffmpeg) and computes full-band + bass-band RMS
energy over time, then prints an ASCII structure map plus detected
drops (sharp bass rises after a dip) and quiet zones.
"""
import os, subprocess, sys
import numpy as np

BASE = os.path.dirname(os.path.abspath(__file__))
MP3 = os.path.join(BASE, "music.mp3")
SR = 8000
HOP = 0.1     # seconds per analysis window

raw = subprocess.run(
    ["ffmpeg", "-v", "quiet", "-i", MP3, "-ac", "1", "-ar", str(SR), "-f", "s16le", "-"],
    capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
dur = len(x) / SR

# bass band: one-pole low-pass at ~150 Hz
alpha = 1.0 - np.exp(-2 * np.pi * 150 / SR)
bass = np.empty_like(x)
acc = 0.0
# vectorized one-pole via lfilter-free cumulative trick is messy; use scipy-free loop in chunks
from numpy.lib.stride_tricks import sliding_window_view
try:
    from scipy.signal import lfilter          # if available, fast + exact
    bass = lfilter([alpha], [1, -(1 - alpha)], x).astype(np.float32)
except ImportError:                            # fallback: FFT band filter
    X = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1 / SR)
    X[freqs > 150] = 0
    bass = np.fft.irfft(X, n=len(x)).astype(np.float32)

win = int(SR * HOP)
n = len(x) // win
full_rms = np.sqrt(np.mean(x[:n*win].reshape(n, win) ** 2, axis=1))
bass_rms = np.sqrt(np.mean(bass[:n*win].reshape(n, win) ** 2, axis=1))

def norm(v):
    ref = np.percentile(v, 97)
    return np.clip(v / (ref + 1e-9), 0, 1.2)

full_n = norm(full_rms)
bass_n = norm(bass_rms)

def smooth(v, k):
    kernel = np.ones(k) / k
    return np.convolve(v, kernel, mode="same")

full_s = smooth(full_n, 10)   # 1s smoothing
bass_s = smooth(bass_n, 10)

# ---- structure map: one line per 2 seconds ----
print(f"duration: {dur:.1f}s   (each row = 2s; F=full energy, B=bass)")
print(f"{'time':>6}  {'full':<26} {'bass':<26}")
step = int(2 / HOP)
for i in range(0, n, step):
    t = i * HOP
    f = full_s[i:i+step].mean()
    b = bass_s[i:i+step].mean()
    print(f"{t:6.0f}  {'#' * int(f * 25):<26} {'=' * int(b * 25):<26}")

# ---- drop detection: bass jumps from low to high quickly ----
print("\n--- drop candidates (bass rise >0.45 within 0.6s, from below 0.35) ---")
drops = []
for i in range(6, n):
    before = bass_s[max(0, i-6):i-2].min() if i > 8 else 0
    now = bass_s[i]
    if now > 0.75 and before < 0.35 and (now - before) > 0.45:
        t = i * HOP
        if not drops or t - drops[-1] > 5:
            drops.append(t)
            print(f"  DROP @ {t:6.1f}s   (bass {before:.2f} -> {now:.2f})")

# ---- quiet zones (full energy < 0.25 for >= 1.5s) ----
print("\n--- quiet zones (full < 0.25, len >= 1.5s) ---")
qstart = None
for i in range(n + 1):
    low = i < n and full_s[i] < 0.25
    if low and qstart is None:
        qstart = i
    if not low and qstart is not None:
        if (i - qstart) * HOP >= 1.5:
            print(f"  quiet {qstart*HOP:6.1f}s -> {i*HOP:6.1f}s   ({(i-qstart)*HOP:.1f}s)")
        qstart = None

# ---- energy peaks / loudest sustained sections ----
print("\n--- sustained high energy (full > 0.75 for >= 4s) ---")
hstart = None
for i in range(n + 1):
    hi = i < n and full_s[i] > 0.75
    if hi and hstart is None:
        hstart = i
    if not hi and hstart is not None:
        if (i - hstart) * HOP >= 4:
            print(f"  high  {hstart*HOP:6.1f}s -> {i*HOP:6.1f}s   ({(i-hstart)*HOP:.1f}s)")
        hstart = None
