"""Bildqualitaets-Scan fuer die Aussortier-Runde.

Laeuft im pipeline-cpu-Container (PIL+numpy, /photos gemountet). Pro Foto:
  - blur   : Varianz des Laplace-Operators auf dem 512er-Thumb (niedrig = unscharf)
  - std    : Grauwert-Streuung (fast 0 = einfarbig/schwarz)
  - mean   : Helligkeit (fuer Schwarzbild-Erkennung)
Ergebnis: /photos/../triage/scores.json  {id: [blur, std, mean]}
"""
import json
import os
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

THUMBS = "/photos/thumbs"


def score(aid):
    try:
        p = os.path.join(THUMBS, f"{aid}.512.webp")
        g = np.asarray(Image.open(p).convert("L"), dtype=np.float32) / 255.0
        if g.shape[0] < 8 or g.shape[1] < 8:
            return aid, None
        lap = (-4 * g
               + np.roll(g, 1, 0) + np.roll(g, -1, 0)
               + np.roll(g, 1, 1) + np.roll(g, -1, 1))[1:-1, 1:-1]
        return aid, [float(lap.var()), float(g.std()), float(g.mean())]
    except Exception:
        return aid, None


if __name__ == "__main__":
    ids = [a["id"] for a in json.load(open(sys.argv[1]))]
    with Pool(16) as pool:
        out = dict(r for r in pool.imap_unordered(score, ids, chunksize=64))
    missing = sum(1 for v in out.values() if v is None)
    json.dump(out, open(sys.argv[2], "w"))
    print(f"{len(out)} gescort, {missing} ohne Thumb/Fehler")
