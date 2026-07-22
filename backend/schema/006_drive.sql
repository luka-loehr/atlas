-- atlas backend — schema v6: the drive domain ("Dateien" in the Storage app).
-- Same philosophy as assets: content-addressed blobs (SHA-256), dedupe by
-- construction. Blobs live at ~/drive/blobs/<hash>; rows reference them by
-- hash, so the same bytes under two names/folders are stored once. Blob
-- removal is refcounted in the server (delete GCs orphaned hashes).

CREATE TABLE IF NOT EXISTS drive_folders (
    id         BIGSERIAL PRIMARY KEY,
    parent_id  BIGINT REFERENCES drive_folders(id) ON DELETE CASCADE,  -- NULL = root
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (parent_id, name)
);
CREATE INDEX IF NOT EXISTS drive_folders_parent_idx ON drive_folders (parent_id);

CREATE TABLE IF NOT EXISTS drive_files (
    id          BIGSERIAL PRIMARY KEY,
    folder_id   BIGINT REFERENCES drive_folders(id) ON DELETE CASCADE,  -- NULL = root
    name        TEXT NOT NULL,
    hash        TEXT NOT NULL,              -- SHA-256 content hash = blob key
    size_bytes  BIGINT NOT NULL,
    mime        TEXT,
    modified_at TIMESTAMPTZ DEFAULT now(), -- source mtime (takeout) or upload time
    created_at  TIMESTAMPTZ DEFAULT now(),
    trashed_at  TIMESTAMPTZ,
    source      TEXT DEFAULT 'takeout'      -- takeout | iphone | ...
);
CREATE INDEX IF NOT EXISTS drive_files_folder_idx ON drive_files (folder_id) WHERE trashed_at IS NULL;
CREATE INDEX IF NOT EXISTS drive_files_hash_idx   ON drive_files (hash);
CREATE INDEX IF NOT EXISTS drive_files_recent_idx ON drive_files (modified_at DESC) WHERE trashed_at IS NULL;

INSERT INTO schema_migrations (version) VALUES (6) ON CONFLICT DO NOTHING;
