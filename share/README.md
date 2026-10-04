# atlas-share — share links

A Cloudflare Worker with one R2 bucket that serves the links the app makes
under Share → Link. atlas-server renders a thumbnail, a view (WebP, or H.264
MP4 for videos) and, when downloads are allowed, the original of every
shared item, uploads them to the Worker and writes a manifest last. The
Worker serves the gallery page and the files from R2 and never talks back to
atlas, so links keep working while the server is off. A password is
optional; the Worker keeps only a PBKDF2 digest of it.

**Every link expires after at most 7 days.** atlas-server limits the
duration, the Worker refuses later expiries and answers `410` once a link has
expired, a daily cron deletes expired shares, and an R2 lifecycle rule
deletes anything under `s/` 8 days after upload as the backstop.

The interfaces (admin API, R2 layout, cookie, expiry rules) are in
[CONTRACT.md](CONTRACT.md).

```
src/index.ts      routing, the daily cron
src/admin.ts      admin API for atlas-server (bearer SHARE_TOKEN)
src/public.ts     share page, password gate, files (Range, ETag)
src/html.ts       the pages: gallery (mosaic, viewer), gate, being created, notices
src/layout.ts     the justified-rows mosaic (embedded in the page as is)
src/zip.ts        streaming ZIP writer for "Download all"
src/crypto.ts     token compare, PBKDF2, session cookie
src/store.ts      R2: manifest, prefix delete, sweep
```

## The page

The gallery is a justified mosaic (every item at its aspect ratio, rows
filling the width, laid out in the page from the manifest's `w`/`h`) with
lazy thumbnails. A tap opens a full-screen viewer: swipe with the finger,
flick, swipe down to close, double tap or pinch to zoom, arrow keys and
Escape on a computer; videos play the `v/` MP4. With `allow_download`, each
item has a download button and "Download all" fetches `/s/<id>/zip`, a ZIP
of the originals built while it streams. No framework and no build step:
server-rendered HTML with inline CSS and JS under a per-response CSP nonce.

atlas sends every original's CRC-32 in the manifest, so the Worker writes
the ZIP headers itself and pipes the files from R2 to the recipient without
touching their bytes: its CPU time stays tiny whatever the album weighs.
(Shares without CRCs are checksummed while they stream, which on the Free
plan's 10 ms CPU limit works for small shares only.) The ZIP reads one R2
object per item, which counts against the Worker's per-request subrequest
limit; very large albums may need the Paid plan.

## Setup

From the Mac, with Node.js installed:

```bash
atlas share setup
```

It logs in to Cloudflare in the browser, creates the bucket and the
lifecycle rule, generates both secrets, deploys the Worker and writes
`ATLAS_SHARE_URL` and `ATLAS_SHARE_TOKEN` into `/etc/atlas/atlas.env` on the
server. After a restart of atlas-server, `GET /v1/server` reports
`"sharing": true`.

### By hand

The same steps, run in `share/`. R2 must be enabled once in the Cloudflare
dashboard (R2 → Overview) before the first bucket can be created.

```bash
npm install
npx wrangler login
npx wrangler r2 bucket create atlas-share
npx wrangler r2 bucket lifecycle add atlas-share expire-shares s/ --expire-days 8 --force

WRANGLER_OUTPUT_FILE_PATH=deploy.ndjson npx wrangler deploy
URL=$(grep '"type":"deploy"' deploy.ndjson | grep -o 'https://[^"]*\.workers\.dev' | head -1)
rm deploy.ndjson

openssl rand -hex 32 | npx wrangler secret put SESSION_SECRET
TOKEN=$(openssl rand -hex 32)
echo "$TOKEN" | npx wrangler secret put SHARE_TOKEN
curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/health"   # {"ok":true,…}
```

Deploy comes first because `secret put` asks before creating a Worker that
does not exist; until both secrets are set the Worker answers `500`, never
open. An account that has never used Workers is asked once to pick its
`workers.dev` subdomain. `deploy` also prints the URL
(`https://atlas-share.<subdomain>.workers.dev`); the output file
(`WRANGLER_OUTPUT_FILE_PATH`, one JSON object per line, the `deploy` entry's
`targets`) is the stable way to read it in a script.

Then on the server, in `/etc/atlas/atlas.env`:

```bash
ATLAS_SHARE_URL=https://atlas-share.<subdomain>.workers.dev
ATLAS_SHARE_TOKEN=<the token>
```

and `sudo systemctl restart atlas-server`.

### Custom domain (optional)

A domain on the same Cloudflare account can replace the `workers.dev`
address: Workers & Pages → atlas-share → Settings → Domains & Routes → Add →
Custom domain (or `"routes": [{ "pattern": "share.example.com",
"custom_domain": true }]` in a local, uncommitted copy of `wrangler.jsonc`).
Set `ATLAS_SHARE_URL` to it; links use whatever host atlas-server calls.

## Development

```bash
npm test                 # unit tests and the routes against an in-memory bucket
npx tsc --noEmit
npx wrangler dev --local --var SHARE_TOKEN:dev --var SESSION_SECRET:dev
```

`wrangler dev --local` simulates R2 on disk (`.wrangler/`); nothing touches
Cloudflare.

## Costs

Within the R2 free tier for normal use: 10 GB stored, a million writes and
ten million reads a month, and no egress fees. A share holds storage for a
week at most. Workers' free plan covers 100,000 requests a day.
