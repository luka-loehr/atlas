#!/usr/bin/env python3
"""Song analysis — RUNS ON ATLAS (GPU venv: analyze/.venv).

    python analyze_song.py <audio> <out.analysis.json>

Produces everything the show compiler needs:
  - Beat This! beats + downbeats (SOTA transformer, GPU)
  - constant-tempo lattice fit (bpm, anchor candidates, residual)
  - energy curves (rms, sub-bass, onset strength)
  - drop candidates (sub-bass slam after a dip), quiet windows,
    energy-change segment boundaries, top onset impacts
"""
import json
import sys

import numpy as np

HOP = 512
DS = 8                       # downsample factor for stored curves


def smooth(x, n):
    n = max(1, int(n))
    k = np.ones(n) / n
    return np.convolve(x, k, mode="same")


def main():
    audio_path, out_path = sys.argv[1], sys.argv[2]
    import librosa

    y, sr = librosa.load(audio_path, sr=44100, mono=True)
    dur_ms = len(y) / sr * 1000.0
    hop_ms = HOP / sr * 1000.0

    # ---- Beat This! ----------------------------------------------------
    from beat_this.inference import File2Beats
    f2b = File2Beats(checkpoint_path="final0", device="cuda", dbn=False)
    beats_s, downbeats_s = f2b(audio_path)
    beats = np.asarray(beats_s) * 1000.0
    downs = np.asarray(downbeats_s) * 1000.0

    # ---- constant-tempo lattice fit ------------------------------------
    P = float(np.median(np.diff(beats)))
    A = float(beats[0])
    for _ in range(3):
        k = np.round((beats - A) / P)
        P, A = (float(c) for c in np.polyfit(k, beats, 1))
    resid = float(np.std(beats - (A + np.round((beats - A) / P) * P)))
    bpm = 60000.0 / P

    # ---- energy curves --------------------------------------------------
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    rms = librosa.feature.rms(S=S, hop_length=HOP)[0]
    sub = S[freqs < 100.0].sum(axis=0)
    onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=HOP)
    n = min(len(rms), len(sub), len(onset))
    rms, sub, onset = rms[:n], sub[:n], onset[:n]
    rms_n = rms / (rms.max() or 1.0)
    sub_n = sub / (sub.max() or 1.0)
    on_n = onset / (onset.max() or 1.0)
    t_ms = np.arange(n) * hop_ms

    win = int(round(250.0 / hop_ms))
    rms_s = smooth(rms_n, win * 4)                    # ~1s for structure
    sub_s = smooth(sub_n, win)

    # ---- drop candidates: sub-bass slam right after a dip ---------------
    def band_mean(x, a_ms, b_ms):
        a, b = int(a_ms / hop_ms), int(b_ms / hop_ms)
        a, b = max(0, a), min(n, b)
        return float(x[a:b].mean()) if b > a else 0.0

    cands = []
    for b_ms in beats:
        after = band_mean(sub_s, b_ms, b_ms + 1000)
        before = band_mean(sub_s, b_ms - 1500, b_ms - 250)
        dip = band_mean(rms_n, b_ms - 1200, b_ms - 100)
        score = (after - before) * (1.5 - dip)
        if after > 0.35 and score > 0.10:
            cands.append((float(b_ms), float(score)))
    cands.sort(key=lambda c: -c[1])
    drops = []
    for t, s in cands:
        if all(abs(t - d["t_ms"]) > 8000 for d in drops):
            drops.append({"t_ms": t, "score": round(s, 4)})
        if len(drops) >= 8:
            break
    drops.sort(key=lambda d: d["t_ms"])

    # ---- quiet windows ---------------------------------------------------
    quiet = []
    thr = 0.15
    in_q, q0 = False, 0.0
    for i in range(n):
        q = rms_n[i] < thr
        if q and not in_q:
            in_q, q0 = True, t_ms[i]
        elif not q and in_q:
            in_q = False
            if t_ms[i] - q0 >= 500:
                quiet.append([round(q0, 1), round(float(t_ms[i]), 1)])
    if in_q and dur_ms - q0 >= 500:
        quiet.append([round(q0, 1), round(dur_ms, 1)])

    # ---- energy-change segment boundaries -------------------------------
    d = np.abs(np.diff(rms_s))
    thr_d = d.mean() + 2.5 * d.std()
    bounds = [0.0]
    for i in range(1, len(d)):
        if d[i] > thr_d and t_ms[i] - bounds[-1] > 4000:
            bounds.append(float(t_ms[i]))
    for dr in drops:                                  # drops are always boundaries
        if all(abs(dr["t_ms"] - b) > 1500 for b in bounds):
            bounds.append(dr["t_ms"])
    bounds = sorted(set(bounds)) + [dur_ms]
    segments = []
    for a, b in zip(bounds, bounds[1:]):
        if b - a < 1000:
            continue
        segments.append({
            "start_ms": round(a, 1), "end_ms": round(b, 1),
            "rms": round(band_mean(rms_n, a, b), 4),
            "subbass": round(band_mean(sub_n, a, b), 4),
            "onset_density": round(band_mean(on_n, a, b), 4),
        })

    # ---- top onset impacts ----------------------------------------------
    peaks = librosa.util.peak_pick(onset, pre_max=20, post_max=20, pre_avg=40,
                                   post_avg=40, delta=0.35 * onset.max(), wait=40)
    impacts = sorted(
        ({"t_ms": round(float(p * hop_ms), 1), "strength": round(float(on_n[p]), 3)}
         for p in peaks), key=lambda x: -x["strength"])[:20]
    impacts.sort(key=lambda x: x["t_ms"])

    out = {
        "version": 1,
        "audio": audio_path.split("/")[-1],
        "duration_ms": round(dur_ms, 1),
        "tempo": {"bpm": round(bpm, 3), "fit_anchor_ms": round(A, 1),
                  "residual_ms": round(resid, 2),
                  "confident": bool(resid < 25.0)},
        "beats_ms": [round(float(b), 1) for b in beats],
        "downbeats_ms": [round(float(d), 1) for d in downs],
        "drops": drops,
        "quiet_windows": quiet,
        "segments": segments,
        "impacts": impacts,
        "curves": {"hop_ms": round(hop_ms * DS, 3),
                   "rms": [round(float(v), 3) for v in rms_n[::DS]],
                   "subbass": [round(float(v), 3) for v in sub_n[::DS]],
                   "onset": [round(float(v), 3) for v in on_n[::DS]]},
    }
    with open(out_path, "w") as f:
        json.dump(out, f)
    print(f"analysis ok: {bpm:.2f} bpm (residual {resid:.1f}ms, "
          f"confident={resid < 25.0}), {len(drops)} drops, "
          f"{len(segments)} segments, {len(quiet)} quiet windows")


if __name__ == "__main__":
    main()
