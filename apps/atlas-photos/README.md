# atlas-photos — the self-built Google Photos

Coming up next (foundation: `backend/`). Two parts:

- **server/** — Rust (axum + sqlx): timeline API (`/api/timeline/summary`
  month buckets + cursor pages with w/h), content-addressed asset URLs
  `/api/assets/<blake3>/{thumb/256,thumb/1024,original,stream}` with
  `Cache-Control: immutable`, HTTP-Range streaming for AVPlayer.
- **ios/** — SwiftUI: LazyVGrid timeline with month sections, NSCache +
  URLCache (immutable URLs = zero invalidation), progressive viewer
  (256 → 1024 → original), AVPlayer for videos.

Design decisions live in `backend/README.md`; the ingest fills the DB from
`~/takeout/photos/` on atlas.
