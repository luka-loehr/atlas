-- Atlas 0.6.0: Unified S3-compatible buckets, object catalog, multipart
-- uploads, accounts, scoped API/S3 keys, and lossless media + drive backfill.

-- --------------------------------------------------------------- accounts ----

CREATE TABLE IF NOT EXISTS accounts (
    id               TEXT PRIMARY KEY,
    name             TEXT UNIQUE NOT NULL,
    display_name     TEXT,
    role             TEXT NOT NULL DEFAULT 'service'
                     CHECK (role IN ('owner', 'admin', 'member', 'service')),
    status           TEXT NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active', 'suspended')),
    rate_limit_rps   INTEGER CHECK (rate_limit_rps IS NULL OR rate_limit_rps > 0),
    rate_limit_burst INTEGER CHECK (rate_limit_burst IS NULL OR rate_limit_burst > 0),
    quota_bytes      BIGINT  CHECK (quota_bytes IS NULL OR quota_bytes >= 0),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO accounts (id, name, display_name, role, status)
VALUES ('owner', 'owner', 'Owner', 'owner', 'active')
ON CONFLICT (id) DO NOTHING;

-- --------------------------------------------------------------- api_keys ----

CREATE TABLE IF NOT EXISTS api_keys (
    id               TEXT PRIMARY KEY,
    access_key_id    TEXT UNIQUE NOT NULL,
    name             TEXT NOT NULL,
    account_id       TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    sealed_secret    BYTEA NOT NULL,
    secret_sha256    BYTEA NOT NULL,
    scopes           TEXT[] NOT NULL DEFAULT '{read,write,delete,media:search}',
    buckets          TEXT[] NOT NULL DEFAULT '{}',
    rate_limit_rps   INTEGER CHECK (rate_limit_rps IS NULL OR rate_limit_rps > 0),
    rate_limit_burst INTEGER CHECK (rate_limit_burst IS NULL OR rate_limit_burst > 0),
    expires_at       TIMESTAMPTZ,
    revoked_at       TIMESTAMPTZ,
    last_used_at     TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS api_keys_account_idx ON api_keys (account_id);
CREATE INDEX IF NOT EXISTS api_keys_active_idx  ON api_keys (access_key_id) WHERE revoked_at IS NULL;

DROP TRIGGER IF EXISTS api_keys_notify ON api_keys;
CREATE TRIGGER api_keys_notify
    AFTER INSERT OR UPDATE OR DELETE ON api_keys
    FOR EACH STATEMENT EXECUTE FUNCTION atlas_notify('atlas_keys');

DROP TRIGGER IF EXISTS accounts_notify ON accounts;
CREATE TRIGGER accounts_notify
    AFTER INSERT OR UPDATE OR DELETE ON accounts
    FOR EACH STATEMENT EXECUTE FUNCTION atlas_notify('atlas_keys');

-- ---------------------------------------------------------------- buckets ----

CREATE TABLE IF NOT EXISTS buckets (
    name             TEXT PRIMARY KEY,
    kind             TEXT NOT NULL DEFAULT 'general'
                     CHECK (kind IN ('media', 'files', 'general')),
    owner_account_id TEXT NOT NULL DEFAULT 'owner' REFERENCES accounts(id) ON DELETE RESTRICT,
    quota_bytes      BIGINT CHECK (quota_bytes IS NULL OR quota_bytes >= 0),
    public_read      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO buckets (name, kind, owner_account_id)
VALUES
    ('media', 'media', 'owner'),
    ('files', 'files', 'owner')
ON CONFLICT (name) DO NOTHING;

-- ---------------------------------------------------------------- objects ----

CREATE TABLE IF NOT EXISTS objects (
    bucket           TEXT NOT NULL REFERENCES buckets(name) ON DELETE RESTRICT,
    key              TEXT NOT NULL,
    sha256           TEXT NOT NULL,
    etag             TEXT NOT NULL,
    size_bytes       BIGINT NOT NULL DEFAULT 0,
    content_type     TEXT NOT NULL DEFAULT 'application/octet-stream',
    custom_metadata  JSONB NOT NULL DEFAULT '{}'::jsonb,
    asset_id         TEXT REFERENCES assets(id) ON DELETE CASCADE,
    drive_file_id    BIGINT REFERENCES drive_files(id) ON DELETE CASCADE,
    owner_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL DEFAULT 'owner',
    trashed_at       TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bucket, key)
);

CREATE INDEX IF NOT EXISTS objects_prefix_idx
    ON objects (bucket, key text_pattern_ops)
    WHERE trashed_at IS NULL;

CREATE INDEX IF NOT EXISTS objects_list_idx
    ON objects (bucket, key)
    WHERE trashed_at IS NULL;

CREATE INDEX IF NOT EXISTS objects_sha256_idx
    ON objects (sha256);

CREATE INDEX IF NOT EXISTS objects_asset_idx
    ON objects (asset_id)
    WHERE asset_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS objects_drive_file_idx
    ON objects (drive_file_id)
    WHERE drive_file_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS objects_updated_idx
    ON objects (bucket, updated_at DESC)
    WHERE trashed_at IS NULL;

-- ------------------------------------------------------ multipart_uploads ----

CREATE TABLE IF NOT EXISTS multipart_uploads (
    upload_id        TEXT PRIMARY KEY,
    bucket           TEXT NOT NULL REFERENCES buckets(name) ON DELETE CASCADE,
    key              TEXT NOT NULL,
    content_type     TEXT NOT NULL DEFAULT 'application/octet-stream',
    custom_metadata  JSONB NOT NULL DEFAULT '{}'::jsonb,
    owner_account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL DEFAULT 'owner',
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS multipart_uploads_bucket_idx
    ON multipart_uploads (bucket, key, created_at);

CREATE TABLE IF NOT EXISTS multipart_parts (
    upload_id        TEXT NOT NULL REFERENCES multipart_uploads(upload_id) ON DELETE CASCADE,
    part_number      INTEGER NOT NULL CHECK (part_number BETWEEN 1 AND 10000),
    sha256           TEXT NOT NULL,
    etag             TEXT NOT NULL,
    size_bytes       BIGINT NOT NULL,
    temp_path        TEXT NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (upload_id, part_number)
);

-- ----------------------------------------- lossless backfill: media & files ----

-- 1) Project existing photo & video assets into the `media` bucket without
--    copying or moving a single file on disk.
INSERT INTO objects (
    bucket,
    key,
    sha256,
    etag,
    size_bytes,
    content_type,
    custom_metadata,
    asset_id,
    owner_account_id,
    trashed_at,
    created_at,
    updated_at
)
SELECT
    'media' AS bucket,
    coalesce(to_char(a.taken_at AT TIME ZONE 'UTC', 'YYYY/MM'), '0000/00')
        || '/' || a.id || '.' ||
        coalesce(
            nullif(lower(substring(a.orig_path from '\.([A-Za-z0-9]{1,8})$')), ''),
            CASE WHEN a.type = 'video' THEN 'mp4' ELSE 'jpg' END
        ) AS key,
    a.id AS sha256,
    '"' || substring(a.id from 1 for 32) || '"' AS etag,
    coalesce(a.size_bytes, 0) AS size_bytes,
    CASE
        WHEN a.type = 'video' THEN 'video/mp4'
        WHEN lower(a.orig_path) LIKE '%.png' THEN 'image/png'
        WHEN lower(a.orig_path) LIKE '%.webp' THEN 'image/webp'
        WHEN lower(a.orig_path) LIKE '%.heic' OR lower(a.orig_path) LIKE '%.heif' THEN 'image/heic'
        WHEN lower(a.orig_path) LIKE '%.gif' THEN 'image/gif'
        ELSE 'image/jpeg'
    END AS content_type,
    CASE
        WHEN a.orig_name IS NOT NULL AND a.orig_name <> ''
        THEN jsonb_build_object('original-name', a.orig_name)
        ELSE '{}'::jsonb
    END AS custom_metadata,
    a.id AS asset_id,
    'owner' AS owner_account_id,
    a.trashed_at,
    coalesce(a.ingested_at, now()) AS created_at,
    coalesce(a.ingested_at, now()) AS updated_at
FROM assets a
ON CONFLICT (bucket, key) DO NOTHING;

-- 2) Project existing drive folders & files into the `files` bucket using
--    their full folder path as the S3 object key.
WITH RECURSIVE folder_paths AS (
    SELECT
        id,
        parent_id,
        regexp_replace(trim(both '/' from name), '/+', '-', 'g') AS full_path
    FROM drive_folders
    WHERE parent_id IS NULL
    UNION ALL
    SELECT
        c.id,
        c.parent_id,
        fp.full_path || '/' || regexp_replace(trim(both '/' from c.name), '/+', '-', 'g')
    FROM drive_folders c
    JOIN folder_paths fp ON c.parent_id = fp.id
)
INSERT INTO objects (
    bucket,
    key,
    sha256,
    etag,
    size_bytes,
    content_type,
    custom_metadata,
    drive_file_id,
    owner_account_id,
    trashed_at,
    created_at,
    updated_at
)
SELECT
    'files' AS bucket,
    CASE
        WHEN df.trashed_at IS NOT NULL THEN
            coalesce(fp.full_path || '/', '')
            || regexp_replace(trim(both '/' from df.name), '/+', '-', 'g')
            || '.trashed-' || df.id::text
        ELSE
            coalesce(fp.full_path || '/', '')
            || regexp_replace(trim(both '/' from df.name), '/+', '-', 'g')
    END AS key,
    df.hash AS sha256,
    '"' || substring(df.hash from 1 for 32) || '"' AS etag,
    df.size_bytes,
    coalesce(df.mime, 'application/octet-stream') AS content_type,
    '{}'::jsonb AS custom_metadata,
    df.id AS drive_file_id,
    'owner' AS owner_account_id,
    df.trashed_at,
    coalesce(df.created_at, now()) AS created_at,
    coalesce(df.modified_at, now()) AS updated_at
FROM drive_files df
LEFT JOIN folder_paths fp ON fp.id = df.folder_id
WHERE trim(both '/' from df.name) <> ''
ON CONFLICT (bucket, key) DO NOTHING;
