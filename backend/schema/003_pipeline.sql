-- atlas backend — schema v3: photo pipeline (queue, faces/persons vectors,
-- captions/tags, geocode places, events, co-occurrence view).
-- Idempotent: safe to run any number of times via psql.
--
-- Live-shape adaptations (inspected 2026-07-20):
--   places : id/name/kind/lat/lon existed — add admin1, cc + natural-key
--            UNIQUE (name, admin1, cc) NULLS NOT DISTINCT for geocode upserts.
--   events : label/t_start/t_end/kind already cover title/starts_at/ends_at —
--            handlers use the EXISTING names (label, t_start, t_end);
--            only place_id is added here.
--   ingest_jobs : status CHECK exists and already matches the contract;
--            there is NO kind CHECK on the live table — nothing to extend.
--   tags   : did not exist — created here.

CREATE EXTENSION IF NOT EXISTS vector;

-- ------------------------------------------------------ 1. queue columns ----

ALTER TABLE ingest_jobs ADD COLUMN IF NOT EXISTS priority     INTEGER     NOT NULL DEFAULT 100;
ALTER TABLE ingest_jobs ADD COLUMN IF NOT EXISTS run_after    TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE ingest_jobs ADD COLUMN IF NOT EXISTS locked_by    TEXT;
ALTER TABLE ingest_jobs ADD COLUMN IF NOT EXISTS heartbeat_at TIMESTAMPTZ;
ALTER TABLE ingest_jobs ADD COLUMN IF NOT EXISTS created_at   TIMESTAMPTZ DEFAULT now();

-- claim() scan order: status='pending' AND run_after<=now() ORDER BY priority,id
CREATE INDEX IF NOT EXISTS ingest_jobs_claim_idx
    ON ingest_jobs (status, run_after, priority, id);

-- --------------------------------------------- 2. faces: 512-d embedding ----

ALTER TABLE faces ADD COLUMN IF NOT EXISTS embedding vector(512);

CREATE INDEX IF NOT EXISTS faces_embedding_hnsw
    ON faces USING hnsw (embedding vector_cosine_ops);

-- ------------------------------------------- 3. persons: online centroid ----

ALTER TABLE persons ADD COLUMN IF NOT EXISTS centroid   vector(512);
ALTER TABLE persons ADD COLUMN IF NOT EXISTS face_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE persons ADD COLUMN IF NOT EXISTS cover_face_id BIGINT
    REFERENCES faces(id) ON DELETE SET NULL;

-- -------------------------------------------------- 4. assets: captions ----

ALTER TABLE assets ADD COLUMN IF NOT EXISTS caption TEXT;

-- ------------------------------------------------------------- 5. tags ----

CREATE TABLE IF NOT EXISTS tags (
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    tag      TEXT NOT NULL,
    source   TEXT NOT NULL DEFAULT 'caption',
    PRIMARY KEY (asset_id, tag, source)
);
CREATE INDEX IF NOT EXISTS tags_tag_idx ON tags (tag);

-- -------------------------------------------------- 6a. places (geocode) ----
-- reverse_geocoder yields (name, admin1, cc); upsert key must treat NULLs as
-- equal so ON CONFLICT (name, admin1, cc) always resolves (PG15+ semantics).

ALTER TABLE places ADD COLUMN IF NOT EXISTS admin1 TEXT;
ALTER TABLE places ADD COLUMN IF NOT EXISTS cc     TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS places_natural_key
    ON places (name, admin1, cc) NULLS NOT DISTINCT;

-- ----------------------------------------------- 6b. events (event_scan) ----
-- Existing label/t_start/t_end serve as title/starts_at/ends_at; add only the
-- place link. Handlers wipe-and-rebuild auto events in one tx (idempotent).

ALTER TABLE events ADD COLUMN IF NOT EXISTS place_id BIGINT
    REFERENCES places(id) ON DELETE SET NULL;

-- --------------------------------------- 7. knowledge graph: co-occurrence ----
-- Derived, never materialized: pairs of persons sharing at least one asset.

CREATE OR REPLACE VIEW person_cooccurrence AS
SELECT f1.person_id                AS person_a,
       f2.person_id                AS person_b,
       count(DISTINCT f1.asset_id) AS shared_assets
FROM faces f1
JOIN faces f2
  ON f2.asset_id  = f1.asset_id
 AND f2.person_id > f1.person_id
WHERE f1.person_id IS NOT NULL
  AND f2.person_id IS NOT NULL
GROUP BY f1.person_id, f2.person_id;

-- ----------------------------------------------------------- 8. version ----

INSERT INTO schema_migrations (version) VALUES (3)
ON CONFLICT (version) DO NOTHING;
