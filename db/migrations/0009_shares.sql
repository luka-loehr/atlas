-- Links shared through atlas-share (share/). A share is a snapshot of some
-- assets, uploaded to the owner's Cloudflare R2 and removed again when it
-- expires, at most 7 days after it was made.
CREATE TABLE shares (
    id             text PRIMARY KEY,            -- 22 base62 chars, the link's secret
    title          text NOT NULL,
    album_id       bigint REFERENCES albums (id) ON DELETE SET NULL,
    asset_ids      text[] NOT NULL,             -- in the order they are shown
    allow_download boolean NOT NULL DEFAULT false,
    -- kept only until the manifest is written; the Worker stores a digest
    password       text,
    has_password   boolean NOT NULL DEFAULT false,
    state          text NOT NULL DEFAULT 'uploading' CHECK (state IN ('uploading', 'ready', 'failed')),
    done_bytes     bigint NOT NULL DEFAULT 0,
    total_bytes    bigint NOT NULL DEFAULT 0,
    error          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL
);

CREATE INDEX shares_expires_idx ON shares (expires_at);
