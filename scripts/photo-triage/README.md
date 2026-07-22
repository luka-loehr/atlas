# photo-triage — junk-photo review

A one-shot tool for cleaning the photo library: two scoring scripts find
delete candidates (screenshots, blurry shots, black/empty frames, paper
documents), and a local web UI shows them one at a time — image left,
category/reasons/file info right. **Backspace** = trash, **Enter** = keep,
**U** = undo. Trashing is reversible: it only sets `trashed_at` via the
photos API; photos are gone for good only when the trash is emptied in the
app.

Progress is stored server-side in `decided.json` and merged with the real
trash on the photos server at load time, so a reload or a different browser
never shows an already-decided photo again.

## Components

| File | Runs where | Does what |
|---|---|---|
| `triage_score.py` | inside the `pipeline-cpu` container (PIL + numpy, `/photos` mounted) | per photo, from the 512 px thumb: Laplacian variance (blur), grayscale std (monochrome), mean (black frame); writes `{id: [blur, std, mean]}` |
| `triage_sem.py` | on the server host (stdlib only) | embeds four "junk concept" texts via the embed API, then takes the top 1500 nearest photos per concept from pgvector; writes `sem.json` |
| `serve.py` | on the client | loopback HTTP server for the UI: serves the page, owns `decided.json`, proxies decisions to the photos API |
| `index.html` | browser | the review UI; loads `candidates.json` + `/state`, fetches thumbnails directly from the photos server |

## Generating candidates

Steps 1 and 4 were ad hoc (a Postgres export query and a threshold merge)
and are not committed — the committed scripts cover the scoring stages:

```bash
# 1) export visible photo metadata from Postgres to assets.json
#    (a JSON list of objects with at least an "id" field)

# 2) blur / monochrome / black-frame scores over the 512 px thumbs
#    (container name assumes the default compose project "atlas-pipeline"):
docker cp triage_score.py atlas-pipeline-pipeline-cpu-1:/tmp/
docker cp assets.json     atlas-pipeline-pipeline-cpu-1:/tmp/
docker exec atlas-pipeline-pipeline-cpu-1 \
  python3 /tmp/triage_score.py /tmp/assets.json /tmp/scores.json
docker cp atlas-pipeline-pipeline-cpu-1:/tmp/scores.json .

# 3) semantic junk concepts via Qwen text embeddings (on the server host):
python3 triage_sem.py            # -> ~/triage/sem.json

# 4) merge scores + concepts + filename heuristics into candidates.json
```

`candidates.json` is what the UI consumes: a JSON list of
`{id, cat, reasons, name, day, w, h}` where `cat` is one of
`screenshot | dark | blurry | doc` and `reasons` is a list of short strings
shown as chips.

## Running the UI

```bash
python3 serve.py                 # -> http://localhost:8890
```

`candidates.json` must sit next to `serve.py`. The server binds
`127.0.0.1:8890` only. `GET /state` returns the decision map (merged with
`GET /api/trash` on the photos server) plus the photos-server base URL, so
the page never hardcodes it. `POST /decide` forwards to
`POST /api/mutate/trash` / `POST /api/mutate/restore`; thumbnails come
straight from `GET /api/assets/{id}/thumb/{512|2048}`.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_PHOTOS_URL` | `http://atlas.your-tailnet.ts.net:8788` | base URL of the atlas-photos server (`serve.py`) |
| `ATLAS_TRIAGE_OUT` | `~/triage/sem.json` | output path of `triage_sem.py` |

Fixed assumptions: `triage_sem.py` expects the embed API on
`127.0.0.1:8093` (see [the pipeline](../../apps/atlas-photos/pipeline/))
and Postgres in the `atlas-postgres` container (`psql -U atlas -d atlas`
via `docker exec`). See [docs/SETUP.md](../../docs/SETUP.md) for the stack.

## Operational notes

- Mutating requests require the `X-Triage` header and, if the browser sends
  an `Origin`, a localhost origin — a minimal CSRF guard for the loopback
  server.
- `serve.py` does not send a bearer token, so the photos server must run in
  tailnet-only mode (no `ATLAS_PHOTOS_TOKEN`).
- Everything in this directory is browsable through `serve.py` (it extends
  `SimpleHTTPRequestHandler`), including `decided.json` — harmless while
  loopback-only, but don't park secrets here.
