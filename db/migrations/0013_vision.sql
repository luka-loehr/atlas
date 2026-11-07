-- Atlas 0.5.0: the vision stage. What used to be the face stage now sees
-- everything the search needs from the pixels:
--
--   * faces at two scales (a close-up and the fifth face of a group photo),
--     in many frames of a video, not only its poster
--   * animals (dogs, cats, horses, birds), grouped into individuals like
--     people, so a pet can be named
--   * text, read off signs, screenshots and documents
--
-- Nobody's name is lost: persons are never deleted by the stage, a face that
-- is detected again inherits the person of the face it replaces, and a face
-- of a named person the new detector does not find again stays as it was.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- a person or a pet: 'person', 'dog', 'cat', 'horse', 'bird'
ALTER TABLE persons ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'person';
-- an animal's look (pet-recognition-large, 512 dimensions); people keep
-- `centroid`
ALTER TABLE persons ADD COLUMN IF NOT EXISTS look vector(512);

-- a detection: a human face (kind 'person', ArcFace `embedding`) or an
-- animal (its species as kind, pet-recognition `look`)
ALTER TABLE faces ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'person';
ALTER TABLE faces ADD COLUMN IF NOT EXISTS look vector(512);
-- where in a video it was seen, seconds from the start (NULL for a still)
ALTER TABLE faces ADD COLUMN IF NOT EXISTS frame_s REAL;
-- which recognizer made `embedding`: the faces of one model are only ever
-- compared with each other ('arcface-r50' before 0.5.0, 'adaface-ir101')
ALTER TABLE faces ADD COLUMN IF NOT EXISTS model TEXT NOT NULL DEFAULT 'arcface-r50';
-- its width in pixels of the frame it was found in: small faces carry less
-- identity and need a closer match
ALTER TABLE faces ADD COLUMN IF NOT EXISTS width_px REAL;
CREATE INDEX IF NOT EXISTS faces_model_idx ON faces (model, kind) WHERE person_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS faces_unassigned_idx ON faces (kind) WHERE person_id IS NULL;
CREATE INDEX IF NOT EXISTS persons_kind_idx ON persons (kind) WHERE merged_into IS NULL;

-- everything legible in an asset, line by line
CREATE TABLE IF NOT EXISTS asset_text (
    asset_id   TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    text       TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS asset_text_trgm_idx ON asset_text USING gin (lower(text) gin_trgm_ops);

-- every asset goes through the new stage once: behind fresh uploads and the
-- hourly repairs, stills before clips
INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
SELECT 'faces', 'asset', a.id, CASE WHEN a.type = 'video' THEN 330 ELSE 310 END
  FROM assets a
ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
    SET status = 'pending', attempts = 0, defers = 0, heals = 0, error = NULL, stuck_at = NULL,
        run_after = now(), locked_by = NULL, heartbeat_at = NULL,
        priority = EXCLUDED.priority, updated_at = now()
  WHERE ingest_jobs.status <> 'running';
