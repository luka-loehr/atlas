# atlas-photos — the "Storage" app: self-built Google Photos + Google Drive

Foundation: `backend/`. Two parts:

- **server/** — Rust (axum + sqlx): timeline API (`/api/timeline/summary`
  month buckets + cursor pages with w/h), content-addressed asset URLs
  `/api/assets/<blake3>/{thumb/256,thumb/1024,original,stream}` with
  `Cache-Control: immutable`, HTTP-Range streaming for AVPlayer — plus the
  drive domain under `/api/drive/*` (folder tree, content-addressed blobs at
  `~/drive/blobs/<sha256>`, upload/rename/move/trash, see `server/src/drive.rs`).
- **ios/** — SwiftUI, tabs `Fotos · Alben · Dateien · Suche`: LazyVGrid
  timeline with month sections, NSCache + URLCache (immutable URLs = zero
  invalidation), progressive viewer (256 → 1024 → original), AVPlayer for
  videos; the Dateien tab is a folder browser with QuickLook preview,
  fileImporter upload, rename/move/Papierkorb.

Design decisions live in `backend/README.md`; the ingests fill the DB from
`~/takeout/photos/` (photos) and the Takeout-Drive zip
(`ingest/ingest_drive.py`) on atlas.
