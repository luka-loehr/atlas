-- The timeline cache is told about changes to what it shows, nothing else.
-- The statement trigger fired on every statement that touched assets, even
-- one that changed no row or only a column the timeline does not show
-- (exif, preview_at, ...), and every firing threw the whole cache away.
-- Row triggers fire per changed row; Postgres folds the identical
-- notifications of one transaction into one.
DROP TRIGGER IF EXISTS assets_notify ON assets;
DROP TRIGGER IF EXISTS assets_notify_rows ON assets;
DROP TRIGGER IF EXISTS assets_notify_shown ON assets;
CREATE TRIGGER assets_notify_rows
    AFTER INSERT OR DELETE ON assets
    FOR EACH ROW EXECUTE FUNCTION atlas_notify('atlas_assets');
-- the columns of COLS and VISIBLE in crates/server/src/photos/mod.rs
CREATE TRIGGER assets_notify_shown
    AFTER UPDATE ON assets
    FOR EACH ROW WHEN (
           OLD.type        IS DISTINCT FROM NEW.type
        OR OLD.taken_at    IS DISTINCT FROM NEW.taken_at
        OR OLD.tz_offset_s IS DISTINCT FROM NEW.tz_offset_s
        OR OLD.width       IS DISTINCT FROM NEW.width
        OR OLD.height      IS DISTINCT FROM NEW.height
        OR OLD.duration_s  IS DISTINCT FROM NEW.duration_s
        OR OLD.favorite    IS DISTINCT FROM NEW.favorite
        OR OLD.thumbhash   IS DISTINCT FROM NEW.thumbhash
        OR OLD.archived    IS DISTINCT FROM NEW.archived
        OR OLD.trashed_at  IS DISTINCT FROM NEW.trashed_at
        OR OLD.locked      IS DISTINCT FROM NEW.locked
    )
    EXECUTE FUNCTION atlas_notify('atlas_assets');

-- Tags were written by the captioner, which is gone since 0008; they covered
-- only the photos from before it, so search ranked those above newer ones.
-- Events were the event scan's, gone the same way.
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS events;

-- Which recipe made an asset's thumbnails. 2: video posters of HDR clips
-- are tone-mapped to SDR (they were washed out); older video thumbnails are
-- redone by `atlas-server backfill thumbs`.
ALTER TABLE assets ADD COLUMN IF NOT EXISTS thumb_v SMALLINT NOT NULL DEFAULT 1;
