# vecmap — the embedding map

Renders the whole photo library as a 3D point cloud of real thumbnails:
every Qwen3-VL embedding (photos *and* videos) is reduced to 3D with UMAP
and drawn as a textured quad in WebGL. The generated bundle is a static
directory served at `/map` by the
[atlas-photos server](../../apps/atlas-photos/server/) — without a bundle
in place, those routes simply 404.

## Components

| File | Does what |
|---|---|
| `reduce.py` | loads all `qwen3vl` embeddings + named persons from Postgres, PCA(50) → normalize, appends a weighted person one-hot, UMAP → 3D, writes `layout.json` (`ids`, `x/y/z`, `type`, `tag`, `year`, `persons`) |
| `atlas_build.py` | packs every 512 px thumbnail (center-cropped to 64 px cells) into 4096×4096 WebP sprite atlases, in `layout.json` order; writes `tiles/atlas_N.webp` + `tiles/meta.json` |
| `map.html` | viewer 1: dependency-free WebGL point cloud (WebGL2 with WebGL1 fallback) — drag to orbit, scroll to zoom, shift-drag to pan, hover tooltips, person/tag search with a camera flight, click to enlarge |
| `kosmos.html` | viewer 2, "Memory Field": cinematic three.js viewer (WebGL2 required) with flight choreography, bloom/film post FX, an HD texture layer for nearby photos, and a lightbox; reachable at `/map/kosmos.html` |

## Building the bundle

Runs on the server and needs the atlas-photos stack: Postgres with
embeddings, thumbnails on disk, and the `atlas-pipeline-cpu` image (ships
PIL, numpy and psycopg; see [the pipeline](../../apps/atlas-photos/pipeline/)).
Copy `reduce.py` and `atlas_build.py` into a work directory first — the
container reads them from `/work`.

```bash
# 0) work dir with the two scripts and the two viewers
mkdir -p /home/atlas/vecmap
cp reduce.py atlas_build.py map.html kosmos.html /home/atlas/vecmap/

# 1) vectors + persons -> PCA(50) -> UMAP(3D) -> layout.json
docker run --rm --network host -v /home/atlas/vecmap:/work \
  -v /home/atlas/atlas/backend/docker/.env:/secrets/.env:ro \
  --entrypoint bash atlas-pipeline-cpu -c \
  "pip install --quiet umap-learn scikit-learn; python3 /work/reduce.py"

# 2) pack all thumbnails into sprite atlases (64 px cells)
docker run --rm -v /home/atlas/vecmap:/work \
  -v /home/atlas/photos:/photos:ro \
  --entrypoint bash atlas-pipeline-cpu -c "python3 /work/atlas_build.py"

# 3) deploy into the photo root the server serves from
cd /home/atlas/vecmap
sudo mkdir -p /home/atlas/photos/vecmap
sudo cp -r layout.json tiles map.html kosmos.html /home/atlas/photos/vecmap/
```

Container conventions: `/work` is the vecmap work dir, `/photos` is the
photo library root (the directory containing `thumbs/`), and
`/secrets/.env` is the backend's `.env` — `reduce.py` reads
`POSTGRES_PASSWORD` from it and connects to Postgres on `127.0.0.1` (hence
`--network host`).

The deploy target is `{PHOTOS_DIR}/vecmap/` of the photos server (default
`~/photos`); it serves `map.html` at `/map` and every other bundle file at
`/map/<path>` with a short cache window, so redeploying is just overwriting
the files.

### kosmos.html extras

`kosmos.html` imports three.js from `/map/vendor/` via an import map:
`vendor/three.module.js` and `vendor/jsm/` (the `postprocessing/` addons
`EffectComposer`, `RenderPass`, `UnrealBloomPass`, `ShaderPass`,
`OutputPass`). These vendor files are **not in the repo** — download a
three.js release and place them in `{PHOTOS_DIR}/vecmap/vendor/` yourself.
When regenerating the bundle, bump the `BUILD` constant in `kosmos.html`;
it cache-busts the atlas textures. URL parameters: `?embed=ios` (chromeless
embed for the iOS app), `?motion=full` (override
`prefers-reduced-motion`).

## Two invariants that are expensive to break

**Order.** `reduce.py` selects with a fixed `ORDER BY e.owner_id`, and
`atlas_build.py` reads the IDs from `layout.json`: index *i* in the layout
is sprite *i* in the atlases. Without the fixed `ORDER BY`, Postgres may
return rows in any order and every photo sits on the wrong point. Whoever
regenerates the layout must regenerate the atlases with it.

**Persons.** Image embeddings describe image *content*, not identity —
without help, photos of the same person scatter across the whole cloud.
`reduce.py` therefore appends a weighted person one-hot to each vector
(`PERSON_WEIGHT`, cosine metric). Measured at w=0.75: photos of one person
clustered 11.7× tighter than random pairs, others 5.9× and 3.6× — but the
most-photographed person only 1.5×, because thousands of photos in every
imaginable context pull the other way. Higher weight = tighter person
clusters, flatter semantics.

## Memory budget

64 px sprites in 4096×4096 atlases (4096 sprites each): at library scale
(tens of thousands of photos) that is a handful of atlases, roughly 30 MB
download and ~400 MB of GPU texture memory — deliberately sized for a
desktop browser. For a phone you would drop to 32 px cells.
