# atlas-share contract

How the three parts of link sharing talk to each other. Every part builds
against this file; change it first, then the code.

```
 Atlas app ──/v1/shares──▶ atlas-server ──admin API──▶ atlas-share (Cloudflare Worker + R2)
                                                              ▲
                                       recipient's browser ───┘  https://<worker>/s/<id>
```

- **atlas-server** owns shares: it decides what is shared, renders and uploads
  the files, and removes them when the link expires or is stopped.
- **atlas-share** is a Cloudflare Worker with one R2 bucket. It stores the
  files and serves the share page. It never talks to atlas, so links keep
  working while atlas is off.
- **Every link expires after at most 7 days** (`MAX_DAYS = 7`), enforced by
  atlas-server, by the Worker, by a daily Worker cron and by an R2 lifecycle
  rule. What is shared stops costing storage a week later at the latest.

## Share ids

22 characters of base62 from a CSPRNG (~131 bits): `[0-9A-Za-z]{22}`. The id
in the URL is the capability; a password is optional on top.

## R2 layout

Everything of a share lives under its own prefix, so removing a share is one
prefix delete and the lifecycle rule can expire by prefix:

| key | what |
|---|---|
| `s/<id>/share.json` | the manifest (below); written last, after every file |
| `s/<id>/t/<asset>` | thumbnail: WebP, long side 512 |
| `s/<id>/v/<asset>` | view: photos WebP, long side 2048; videos H.264 MP4 (≤1080p, faststart) |
| `s/<id>/o/<asset>` | the untouched original; only when `allow_download` |

`<asset>` is the atlas asset id (SHA-256 of the original, 64 hex).

## Worker admin API

Every route takes `Authorization: Bearer <SHARE_TOKEN>`; a missing or wrong
token is `401`. Bodies are JSON unless noted. A Worker without `SHARE_TOKEN`
answers `500` (never open); errors are `{"error":"…"}`.

| route | does |
|---|---|
| `GET /api/health` | `{"ok":true,"version":"…","max_days":7}` |
| `PUT /api/shares/<id>/files/<t\|v\|o>/<asset>` | stores the raw body (≤ 95 MB) with its `Content-Type` → `{"ok":true}` |
| `HEAD /api/shares/<id>/files/<t\|v\|o>/<asset>` | `200` + `Content-Length` when stored, else `404` (resume) |
| `POST /api/shares/<id>/files/<kind>/<asset>?uploads` | starts a multipart upload (`Content-Type` header = the file's) → `{"upload_id":"…"}` |
| `PUT /api/shares/<id>/files/<kind>/<asset>?upload_id=U&part=N` | one part (N from 1, ≤ 95 MB, all but the last the same size) → `{"etag":"…"}` |
| `POST /api/shares/<id>/files/<kind>/<asset>?upload_id=U&complete` | body `{"parts":[{"part":1,"etag":"…"}]}` → `{"ok":true}` |
| `PUT /api/shares/<id>` | writes the manifest (input below) → `{"url":"https://…/s/<id>"}` |
| `DELETE /api/shares/<id>` | deletes every object under `s/<id>/` → `{"deleted":n}` |

atlas-server sends files up to 16 MiB as one `PUT`, larger ones as 16 MiB parts, so the progress the app shows moves part by part.
Every file `PUT` (whole or part) must carry a `Content-Length` (R2 needs the
length up front): without one it is `411`, above 95 MB `413`. R2 requires
every part but the last to be at least 5 MiB.

### Manifest input (`PUT /api/shares/<id>`)

```json
{
  "title": "Lake Weekend",
  "expires_at": 1760000000,
  "allow_download": false,
  "password": null,
  "items": [
    {
      "id": "3f2a…64 hex",
      "kind": "photo",
      "w": 4032, "h": 3024,
      "taken": 1759000000,
      "duration": null,
      "name": "IMG_0042.HEIC",
      "bytes": 2345678,
      "view": "image/webp"
    }
  ]
}
```

- `expires_at` (unix seconds) must lie in the future and no more than
  `MAX_DAYS` days + 5 minutes ahead, else `400`.
- `password` is plaintext or null. The Worker stores only a PBKDF2-SHA256
  digest (`pbkdf2$<iterations>$<salt b64>$<hash b64>`, 100,000 iterations).
- `taken` is unix seconds in the photo's local wall time (shown as is,
  without converting time zones), or null. `duration` is seconds, videos only.
- `view` is the content type of the `v/` file (`image/webp` or `video/mp4`).
- `crc32` (optional, with `allow_download`): the original's CRC-32 as an
  unsigned integer. With it on every item, "Download all" pipes the files
  from R2 without reading them in the Worker.
- `bytes` is the original's size; it is shown next to the download button.

- Limits (else `400`): `title` ≤ 200 characters (may be empty), 1–20,000
  `items` with distinct `id`s, `name` 1–255 characters, `password` 1–1024
  characters.

The stored `share.json` is the input with `password` replaced by
`password_hash` (or null) and a `created_at` (unix seconds) added. Writing
the manifest of an existing share again keeps its `created_at`, and
`expires_at` may then also be no more than `MAX_DAYS` days + 5 minutes after
`created_at`, so a link can never be stretched past a week.

## Worker public routes

| route | does |
|---|---|
| `GET /s/<id>` | the gallery; the password gate first when the share has one; `404` page when unknown, `410` page when expired |
| `POST /s/<id>/unlock` | form field `password`; right → sets the cookie, `303` to `/s/<id>`; wrong → the gate again with an error (`403`); more than 10 tries a minute from one address, or 60 from anywhere, on one share → `429` with `Retry-After: 60` before the password is checked |
| `GET /s/<id>/zip` | every original as one ZIP named after the title (`Lake Weekend.zip`, RFC 5987); same checks as files (`404` unless live and unlocked), then `403` without `allow_download`; `HEAD` too. Streamed from R2 one object at a time: STORE, data descriptors (flag bit 3), UTF-8 names (bit 11), CRC-32 computed on the way, ZIP64 records only where a size, offset or count needs them, names de-duplicated ignoring case (`IMG_1.HEIC`, `IMG_1 (2).HEIC`), MS-DOS times from `taken`. Only originals present in the bucket are included; their sizes come from a listing, so `Content-Length` is exact. `Cache-Control: private, no-store`, no `Range` |
| `GET /s/<id>/f/<t\|v\|o>/<asset>` | the file, with `Range` support (one range: `206`/`416`), `HEAD`, `ETag`/`If-None-Match`; `404` unless the asset is in the manifest, the share is live and (with a password) the cookie is valid; after those checks `o` is `403` without `allow_download`, and is sent as an attachment named `name` (RFC 5987) |

- Cookie `as_<id>`: `HttpOnly; Secure; SameSite=Lax; Path=/s/<id>`, value
  `<expiry>.<HMAC-SHA256(SESSION_SECRET, "<id>.<expiry>") b64url>`, expiry the
  earlier of the share's and 24 hours ahead.
- Every page and file carries `X-Robots-Tag: noindex, nofollow` and pages are
  `Cache-Control: no-store`. Files are `private, max-age=86400`. Pages also
  carry `Strict-Transport-Security: max-age=31536000` (this host only) and
  `Cross-Origin-Opener-Policy: same-origin`.
- A password share on a Worker without `SESSION_SECRET` is a `500`, never
  open.
- A daily cron deletes every share whose `expires_at` has passed, and every
  `s/<id>/` prefix without a manifest whose files are older than `MAX_DAYS`
  + 1 days (an upload that never finished).

## atlas-server API (for the app)

All under `/v1`, bearer `ATLAS_TOKEN` as everywhere.

`GET /v1/server` gains `"sharing": true|false`, true when atlas-share is set up
(`ATLAS_SHARE_URL` and `ATLAS_SHARE_TOKEN`).

A share as the API returns it:

```json
{
  "id": "…22…", "title": "Lake Weekend",
  "url": "https://atlas-share.example.workers.dev/s/…",
  "created_at": "2026-10-04T12:00:00Z", "expires_at": "2026-10-11T12:00:00Z",
  "state": "uploading",
  "done_bytes": 1234567, "total_bytes": 98765432,
  "count": 391, "cover": "<asset id>|null",
  "album_id": 30, "allow_download": false, "has_password": false,
  "error": null,
  "password": null, "live": false
}
```

`state` is `uploading`, `ready` or `failed` (`error` says why). `live` is
true once the manifest has been written, i.e. the link opens; before that
the Worker answers `202` "Almost ready" (it finds files under the prefix but
no manifest) and the page refreshes itself, so the link can be handed out at
once. `password` is the link's password (or null), kept for the link's
lifetime so the owner's app can show it again.

**One link per album.** `POST` with an album that already has a live link
returns that link (a `failed` one starts uploading again). The link follows
the album: photos added or removed and a new title re-upload what is new and
rewrite the manifest, while the link keeps showing the previous contents.
Deleting the album ends its link. Photos that are archived, locked or
trashed leave every link that shows them.

Uploading runs on atlas alone; the app only asks and polls.

| route | does |
|---|---|
| `GET /v1/shares` | `{"shares":[…]}`, live ones, newest first |
| `POST /v1/shares` | body `{"title":"…","ids":["…"]}` or `{"title":"…","album":30}`, plus `"days":1–7` (default 7), `"allow_download":bool` (default false), `"password":"…"\|null` → the new share (`uploading`); `503 {"error":"sharing is not set up"}` without atlas-share |
| `GET /v1/shares/{id}` | one share (the app polls it while `uploading`) |
| `DELETE /v1/shares/{id}` | stops sharing: removes the files from R2 and the share → `{"deleted":true}` |

Only visible assets can be shared (not archived, locked or trashed).
