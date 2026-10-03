-- Atlas schema baseline (version 7).
--
-- One Postgres for everything: the media library, the drive, the graph that
-- links them, and every vector. Domain tables are the graph nodes; `edges`
-- links them across domains; `embeddings` holds the vectors.
--
-- This is the schema as it stood after the first seven incremental
-- migrations. A database that already recorded version 7 skips this file;
-- a fresh one gets the whole shape in one step. Later migrations build on it.

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------- media ----

CREATE TABLE assets (
    id          TEXT PRIMARY KEY,           -- SHA-256 of the exact bytes
    type        TEXT NOT NULL CHECK (type IN ('photo', 'video')),
    taken_at    TIMESTAMPTZ,
    tz_offset_s INTEGER,
    width       INTEGER,
    height      INTEGER,
    duration_s  DOUBLE PRECISION,
    lat         DOUBLE PRECISION,
    lon         DOUBLE PRECISION,
    camera      TEXT,
    orig_path   TEXT NOT NULL,
    orig_name   TEXT,
    size_bytes  BIGINT,
    favorite    BOOLEAN DEFAULT FALSE,
    description TEXT,
    source      TEXT DEFAULT 'takeout',
    ingested_at TIMESTAMPTZ DEFAULT now(),
    archived    BOOLEAN NOT NULL DEFAULT FALSE,
    trashed_at  TIMESTAMPTZ,
    locked      BOOLEAN NOT NULL DEFAULT FALSE,
    exif        JSONB
);
CREATE INDEX assets_taken_at_idx ON assets (taken_at DESC NULLS LAST);
CREATE INDEX assets_type_idx     ON assets (type);
CREATE INDEX assets_geo_idx      ON assets (lat, lon) WHERE lat IS NOT NULL;
CREATE INDEX assets_timeline_idx ON assets (taken_at DESC)
    WHERE NOT archived AND trashed_at IS NULL AND NOT locked;
CREATE INDEX assets_archived_idx ON assets (taken_at DESC) WHERE archived;
CREATE INDEX assets_trashed_idx  ON assets (trashed_at DESC) WHERE trashed_at IS NOT NULL;
CREATE INDEX assets_locked_idx   ON assets (taken_at DESC) WHERE locked;

CREATE TABLE albums (
    id    BIGSERIAL PRIMARY KEY,
    title TEXT UNIQUE NOT NULL
);
CREATE TABLE album_assets (
    album_id BIGINT REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT   REFERENCES assets(id) ON DELETE CASCADE,
    PRIMARY KEY (album_id, asset_id)
);

CREATE TABLE tags (
    asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    tag      TEXT NOT NULL,
    source   TEXT NOT NULL DEFAULT 'qwen2.5-vl',
    PRIMARY KEY (asset_id, tag, source)
);
CREATE INDEX tags_tag_idx ON tags (tag);

-- ------------------------------------------------------- graph backbone ----

CREATE TABLE persons (
    id            BIGSERIAL PRIMARY KEY,
    display_name  TEXT,
    contact_email TEXT,
    is_me         BOOLEAN DEFAULT FALSE,
    merged_into   BIGINT REFERENCES persons(id),
    centroid      vector(512),
    face_count    INTEGER NOT NULL DEFAULT 0,
    cover_face_id BIGINT
);

CREATE TABLE places (
    id     BIGSERIAL PRIMARY KEY,
    name   TEXT,
    kind   TEXT,
    lat    DOUBLE PRECISION,
    lon    DOUBLE PRECISION,
    admin1 TEXT,
    cc     TEXT
);
CREATE UNIQUE INDEX places_natural_key ON places (name, admin1, cc) NULLS NOT DISTINCT;

CREATE TABLE events (
    id       BIGSERIAL PRIMARY KEY,
    label    TEXT,
    t_start  TIMESTAMPTZ NOT NULL,
    t_end    TIMESTAMPTZ NOT NULL,
    kind     TEXT DEFAULT 'auto',
    place_id BIGINT REFERENCES places(id) ON DELETE SET NULL
);
CREATE INDEX events_time_idx ON events (t_start, t_end);

CREATE TABLE faces (
    id        BIGSERIAL PRIMARY KEY,
    asset_id  TEXT REFERENCES assets(id) ON DELETE CASCADE,
    person_id BIGINT REFERENCES persons(id),
    bbox      REAL[],                       -- x1, y1, x2, y2 (relative)
    quality   REAL,
    embedding vector(512)
);
CREATE INDEX faces_asset_idx  ON faces (asset_id);
CREATE INDEX faces_person_idx ON faces (person_id);
ALTER TABLE persons ADD CONSTRAINT persons_cover_face_id_fkey
    FOREIGN KEY (cover_face_id) REFERENCES faces(id) ON DELETE SET NULL;

-- generic cross-domain edges: every domain row is a node (type, id-as-text)
CREATE TABLE edges (
    src_type   TEXT NOT NULL,
    src_id     TEXT NOT NULL,
    dst_type   TEXT NOT NULL,
    dst_id     TEXT NOT NULL,
    rel        TEXT NOT NULL,               -- depicts | taken_at | part_of
    props      JSONB DEFAULT '{}'::jsonb,
    confidence REAL DEFAULT 1.0,
    created_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (src_type, src_id, rel, dst_type, dst_id)
);
CREATE INDEX edges_src_idx ON edges (src_type, src_id);
CREATE INDEX edges_dst_idx ON edges (dst_type, dst_id);
CREATE INDEX edges_rel_idx ON edges (rel);

-- -------------------------------------------------------------- vectors ----

CREATE TABLE embeddings (
    owner_type TEXT NOT NULL,
    owner_id   TEXT NOT NULL,
    model      TEXT NOT NULL,
    vec        vector(2048) NOT NULL,
    PRIMARY KEY (owner_type, owner_id, model)
);

-- ---------------------------------------------------------------- drive ----

CREATE TABLE drive_folders (
    id         BIGSERIAL PRIMARY KEY,
    parent_id  BIGINT REFERENCES drive_folders(id) ON DELETE CASCADE,  -- NULL = root
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (parent_id, name)
);
CREATE INDEX drive_folders_parent_idx ON drive_folders (parent_id);

CREATE TABLE drive_files (
    id          BIGSERIAL PRIMARY KEY,
    folder_id   BIGINT REFERENCES drive_folders(id) ON DELETE CASCADE, -- NULL = root
    name        TEXT NOT NULL,
    hash        TEXT NOT NULL,              -- SHA-256 = blob key
    size_bytes  BIGINT NOT NULL,
    mime        TEXT,
    modified_at TIMESTAMPTZ DEFAULT now(),
    created_at  TIMESTAMPTZ DEFAULT now(),
    trashed_at  TIMESTAMPTZ,
    source      TEXT DEFAULT 'takeout',
    text        TEXT                        -- NULL = not extracted yet
);
CREATE INDEX drive_files_folder_idx ON drive_files (folder_id) WHERE trashed_at IS NULL;
CREATE INDEX drive_files_hash_idx   ON drive_files (hash);
CREATE INDEX drive_files_recent_idx ON drive_files (modified_at DESC) WHERE trashed_at IS NULL;

-- ------------------------------------------------------------ job queue ----

CREATE TABLE ingest_jobs (
    id           BIGSERIAL PRIMARY KEY,
    kind         TEXT NOT NULL,
    owner_type   TEXT NOT NULL,
    owner_id     TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'running', 'done', 'failed')),
    attempts     INTEGER DEFAULT 0,
    error        TEXT,
    updated_at   TIMESTAMPTZ DEFAULT now(),
    priority     INTEGER NOT NULL DEFAULT 100,
    run_after    TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by    TEXT,
    heartbeat_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ DEFAULT now(),
    UNIQUE (kind, owner_type, owner_id)
);
CREATE INDEX ingest_jobs_pending_idx ON ingest_jobs (kind, id) WHERE status = 'pending';
CREATE INDEX ingest_jobs_claim_idx   ON ingest_jobs (status, run_after, priority, id);
