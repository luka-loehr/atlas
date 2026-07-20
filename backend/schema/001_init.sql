-- atlas backend — schema v1
-- One Postgres for everything: media library, knowledge-graph layers,
-- vectors. Domain tables ARE the graph nodes; `edges` links them across
-- domains; `embeddings` holds all vectors (HNSW).

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------- media ----

CREATE TABLE IF NOT EXISTS assets (
    id          TEXT PRIMARY KEY,          -- BLAKE3 content hash
    type        TEXT NOT NULL CHECK (type IN ('photo', 'video')),
    taken_at    TIMESTAMPTZ,               -- truth: takeout JSON photoTakenTime
    tz_offset_s INTEGER,
    width       INTEGER,
    height      INTEGER,
    duration_s  DOUBLE PRECISION,          -- videos
    lat         DOUBLE PRECISION,
    lon         DOUBLE PRECISION,
    camera      TEXT,
    orig_path   TEXT NOT NULL,             -- originals/YYYY/MM/<hash>_name.ext
    orig_name   TEXT,
    size_bytes  BIGINT,
    favorite    BOOLEAN DEFAULT FALSE,
    description TEXT,
    source      TEXT DEFAULT 'takeout',    -- takeout | iphone | ...
    ingested_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS assets_taken_at_idx ON assets (taken_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS assets_type_idx     ON assets (type);
CREATE INDEX IF NOT EXISTS assets_geo_idx      ON assets (lat, lon) WHERE lat IS NOT NULL;

-- albums come straight from takeout folders
CREATE TABLE IF NOT EXISTS albums (
    id    BIGSERIAL PRIMARY KEY,
    title TEXT UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS album_assets (
    album_id BIGINT REFERENCES albums(id) ON DELETE CASCADE,
    asset_id TEXT   REFERENCES assets(id) ON DELETE CASCADE,
    PRIMARY KEY (album_id, asset_id)
);

-- ------------------------------------------------------- graph backbone ----

CREATE TABLE IF NOT EXISTS persons (
    id            BIGSERIAL PRIMARY KEY,
    display_name  TEXT,                    -- from google people-tags / contacts
    contact_email TEXT,
    is_me         BOOLEAN DEFAULT FALSE,
    merged_into   BIGINT REFERENCES persons(id)  -- entity resolution
);

CREATE TABLE IF NOT EXISTS places (
    id   BIGSERIAL PRIMARY KEY,
    name TEXT,
    kind TEXT,                             -- city | poi | country | home ...
    lat  DOUBLE PRECISION,
    lon  DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS events (
    id      BIGSERIAL PRIMARY KEY,
    label   TEXT,                          -- "Kroatien-Trip Juli 2024"
    t_start TIMESTAMPTZ NOT NULL,
    t_end   TIMESTAMPTZ NOT NULL,
    kind    TEXT DEFAULT 'auto'            -- auto (clustered) | calendar | manual
);
CREATE INDEX IF NOT EXISTS events_time_idx ON events (t_start, t_end);

-- faces detected in assets (insightface), clustered to persons
CREATE TABLE IF NOT EXISTS faces (
    id         BIGSERIAL PRIMARY KEY,
    asset_id   TEXT REFERENCES assets(id) ON DELETE CASCADE,
    person_id  BIGINT REFERENCES persons(id),
    cluster_id INTEGER,                    -- pre-naming cluster
    bbox       REAL[4],                    -- x, y, w, h (relative)
    quality    REAL
);
CREATE INDEX IF NOT EXISTS faces_asset_idx  ON faces (asset_id);
CREATE INDEX IF NOT EXISTS faces_person_idx ON faces (person_id);

-- generic cross-domain edges: every domain row is a node (type, id-as-text)
CREATE TABLE IF NOT EXISTS edges (
    src_type   TEXT NOT NULL,
    src_id     TEXT NOT NULL,
    dst_type   TEXT NOT NULL,
    dst_id     TEXT NOT NULL,
    rel        TEXT NOT NULL,              -- shows | part_of | taken_at_place | ...
    props      JSONB DEFAULT '{}'::jsonb,
    confidence REAL DEFAULT 1.0,
    created_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (src_type, src_id, rel, dst_type, dst_id)
);
CREATE INDEX IF NOT EXISTS edges_src_idx ON edges (src_type, src_id);
CREATE INDEX IF NOT EXISTS edges_dst_idx ON edges (dst_type, dst_id);
CREATE INDEX IF NOT EXISTS edges_rel_idx ON edges (rel);

-- -------------------------------------------------------------- vectors ----

-- all embeddings, any owner, any model. one HNSW per (model) via partial
-- indexes as models are added; siglip2 image vectors are the first citizen.
CREATE TABLE IF NOT EXISTS embeddings (
    owner_type TEXT NOT NULL,              -- asset | face | mail_chunk | doc_chunk
    owner_id   TEXT NOT NULL,
    model      TEXT NOT NULL,              -- siglip2 | arcface | text-bge-m3 ...
    vec        vector(768) NOT NULL,
    PRIMARY KEY (owner_type, owner_id, model)
);
CREATE INDEX IF NOT EXISTS embeddings_siglip_hnsw
    ON embeddings USING hnsw (vec vector_cosine_ops)
    WHERE model = 'siglip2';

-- ------------------------------------------------------------ pipelines ----

-- resumable batch work queue: every ingested file spawns its jobs; workers
-- pick up whatever is pending whenever atlas is awake (on-demand friendly)
CREATE TABLE IF NOT EXISTS ingest_jobs (
    id         BIGSERIAL PRIMARY KEY,
    kind       TEXT NOT NULL,              -- thumb | embed | faces | whisper | caption
    owner_type TEXT NOT NULL,
    owner_id   TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'running', 'done', 'failed')),
    attempts   INTEGER DEFAULT 0,
    error      TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (kind, owner_type, owner_id)
);
CREATE INDEX IF NOT EXISTS ingest_jobs_pending_idx
    ON ingest_jobs (kind, id) WHERE status = 'pending';

-- ---------------------------------------------------------------- meta -----

CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INTEGER PRIMARY KEY,
    applied_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO schema_migrations (version) VALUES (1) ON CONFLICT DO NOTHING;
