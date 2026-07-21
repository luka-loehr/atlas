-- 002_photo_state.sql — per-asset archive / trash / lock state.
--
-- Replaces the album-based hiding (special albums 'Trash' / 'Locked Folder')
-- with first-class columns so the timeline / search / summary / stats filters
-- become a single partial-index scan instead of a NOT EXISTS anti-join over
-- album_assets. The dedicated buckets (/api/archive, /api/trash, /api/locked)
-- read these columns directly. Re-runnable.

BEGIN;

ALTER TABLE assets
    ADD COLUMN IF NOT EXISTS archived   boolean     NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS trashed_at timestamptz,
    ADD COLUMN IF NOT EXISTS locked     boolean     NOT NULL DEFAULT false;

-- Main-stream timeline: newest-first over the visible set only. The partial
-- predicate keeps the index tiny (archived/trashed/locked rows are not indexed)
-- and matches the WHERE used by timeline/summary/search/stats exactly.
CREATE INDEX IF NOT EXISTS assets_timeline_idx
    ON assets (taken_at DESC)
    WHERE NOT archived AND trashed_at IS NULL AND NOT locked;

-- Dedicated buckets.
CREATE INDEX IF NOT EXISTS assets_archived_idx
    ON assets (taken_at DESC) WHERE archived;
CREATE INDEX IF NOT EXISTS assets_trashed_idx
    ON assets (trashed_at DESC) WHERE trashed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS assets_locked_idx
    ON assets (taken_at DESC) WHERE locked;

-- Migrate the legacy special albums into columns.
UPDATE assets a
   SET locked = true
  FROM album_assets aa
  JOIN albums al ON al.id = aa.album_id
 WHERE aa.asset_id = a.id
   AND al.title IN ('Locked Folder', 'Gesperrter Ordner');

UPDATE assets a
   SET trashed_at = now()
  FROM album_assets aa
  JOIN albums al ON al.id = aa.album_id
 WHERE aa.asset_id = a.id
   AND a.trashed_at IS NULL
   AND al.title IN ('Trash', 'Papierkorb', 'Bin');

INSERT INTO schema_migrations (version) VALUES (2) ON CONFLICT DO NOTHING;

COMMIT;
