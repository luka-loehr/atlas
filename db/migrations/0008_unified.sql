-- 0008: the unified server.
--
--  * thumbhash: a ~25 byte placeholder shipped inside the timeline, so the
--    grid paints a blurred preview before any thumbnail request returns.
--  * taken_src: where taken_at came from (sidecar | exif | filename | upload).
--  * preview_at: set once a streaming rendition of a video exists.
--  * change notifications: the server keeps the timeline precomputed in
--    memory and has to hear about writes from every process (workers, the
--    import CLI, psql), so the tables announce them.
--  * the caption and event-scan stages are gone: their queue rows go with
--    them (the tags and events they produced stay).
--  * merged persons: faces follow the merge, so every query can join on
--    faces.person_id directly instead of resolving merged_into each time.

ALTER TABLE assets ADD COLUMN IF NOT EXISTS thumbhash  BYTEA;
ALTER TABLE assets ADD COLUMN IF NOT EXISTS taken_src  TEXT;
ALTER TABLE assets ADD COLUMN IF NOT EXISTS preview_at TIMESTAMPTZ;

ALTER TABLE albums ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();

CREATE INDEX IF NOT EXISTS album_assets_asset_idx ON album_assets (asset_id);
CREATE INDEX IF NOT EXISTS assets_favorite_idx ON assets (taken_at DESC) WHERE favorite;

CREATE OR REPLACE FUNCTION atlas_notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify(TG_ARGV[0], '');
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS assets_notify ON assets;
CREATE TRIGGER assets_notify
    AFTER INSERT OR UPDATE OR DELETE ON assets
    FOR EACH STATEMENT EXECUTE FUNCTION atlas_notify('atlas_assets');

DROP TRIGGER IF EXISTS ingest_jobs_notify ON ingest_jobs;
CREATE TRIGGER ingest_jobs_notify
    AFTER INSERT ON ingest_jobs
    FOR EACH STATEMENT EXECUTE FUNCTION atlas_notify('atlas_jobs');

DELETE FROM ingest_jobs WHERE kind IN ('caption', 'event_scan');

-- faces of a merged cluster move to the surviving person (follow chains)
WITH RECURSIVE chain AS (
    SELECT id, merged_into AS target FROM persons WHERE merged_into IS NOT NULL
  UNION ALL
    SELECT c.id, p.merged_into FROM chain c JOIN persons p ON p.id = c.target
    WHERE p.merged_into IS NOT NULL
), final AS (
    SELECT c.id, c.target FROM chain c JOIN persons p ON p.id = c.target
    WHERE p.merged_into IS NULL
)
UPDATE faces f SET person_id = final.target FROM final WHERE f.person_id = final.id;

UPDATE persons p SET face_count = c.n, centroid = c.a
FROM (SELECT person_id, count(*) AS n, avg(embedding) AS a
      FROM faces WHERE person_id IS NOT NULL GROUP BY person_id) c
WHERE p.id = c.person_id AND p.merged_into IS NULL;

-- Semantic search runs against an in-memory copy of every vector; the
-- server refreshes it incrementally from rows newer than its last load.
ALTER TABLE embeddings ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE INDEX IF NOT EXISTS embeddings_updated_idx ON embeddings (model, updated_at);

DROP TRIGGER IF EXISTS embeddings_notify ON embeddings;
CREATE TRIGGER embeddings_notify
    AFTER INSERT OR UPDATE OR DELETE ON embeddings
    FOR EACH STATEMENT EXECUTE FUNCTION atlas_notify('atlas_embeddings');
