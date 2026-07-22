"""Pack every thumbnail into 4096x4096 sprite atlases, in layout.json order.

64px cells -> 64x64 = 4096 sprites per atlas -> ~7 atlases for the full library.
One atlas = one GPU texture; the viewer draws 27k textured quads from these
instead of firing 27k HTTP requests.
"""
import json, os, time
from PIL import Image

CELL = 64
ATLAS = 4096
PER_ROW = ATLAS // CELL          # 64
PER_ATLAS = PER_ROW * PER_ROW    # 4096

THUMBS = "/photos/thumbs"
OUT = "/work/tiles"
os.makedirs(OUT, exist_ok=True)

layout = json.load(open("/work/layout.json"))
ids = layout["ids"]
n = len(ids)
n_atlas = (n + PER_ATLAS - 1) // PER_ATLAS
print(f"{n} Bilder -> {n_atlas} Atlanten ({CELL}px Zellen)", flush=True)

placeholder = Image.new("RGB", (CELL, CELL), (24, 24, 28))
t0 = time.time()
missing = 0

for a in range(n_atlas):
    sheet = Image.new("RGB", (ATLAS, ATLAS), (12, 12, 14))
    start = a * PER_ATLAS
    for k in range(PER_ATLAS):
        i = start + k
        if i >= n:
            break
        p = f"{THUMBS}/{ids[i]}.512.webp"
        try:
            im = Image.open(p).convert("RGB")
            # center-crop to square, then downscale — keeps faces/subjects centred
            w, h = im.size
            s = min(w, h)
            im = im.crop(((w - s) // 2, (h - s) // 2, (w + s) // 2, (h + s) // 2))
            im = im.resize((CELL, CELL), Image.LANCZOS)
        except Exception:
            im = placeholder
            missing += 1
        sheet.paste(im, ((k % PER_ROW) * CELL, (k // PER_ROW) * CELL))
    dst = f"{OUT}/atlas_{a}.webp"
    sheet.save(dst, "WEBP", quality=86, method=4)
    print(f"  atlas_{a}.webp  {os.path.getsize(dst)/2**20:.1f} MB  "
          f"({time.time()-t0:.0f}s)", flush=True)

json.dump({"n": n, "cell": CELL, "atlasSize": ATLAS, "perRow": PER_ROW,
           "perAtlas": PER_ATLAS, "atlases": n_atlas},
          open(f"{OUT}/meta.json", "w"))
print(f"fertig in {time.time()-t0:.0f}s, fehlende Thumbs: {missing}", flush=True)
