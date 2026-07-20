-- 004: EXIF-Details für das Viewer-Info-Sheet.
-- Der Meta-Worker legt hier das interessante Subset der exiftool-Ausgabe ab
-- (iso, f_number, exposure_time, focal_len, lens) — der Server reicht es via
-- GET /api/assets/{id}/info durch. Idempotent.

ALTER TABLE assets ADD COLUMN IF NOT EXISTS exif JSONB;

INSERT INTO schema_migrations (version) VALUES (4) ON CONFLICT DO NOTHING;
