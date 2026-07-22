-- atlas backend — schema v7: extracted text for drive content search.
-- Filled by ingest/extract_drive_text.py (pdftotext + Office-XML strippers).
-- NULL = not yet processed, '' = processed but nothing extractable.

ALTER TABLE drive_files ADD COLUMN IF NOT EXISTS text TEXT;

INSERT INTO schema_migrations (version) VALUES (7) ON CONFLICT DO NOTHING;
