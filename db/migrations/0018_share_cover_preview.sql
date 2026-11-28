-- 0018: Allow password-protected share links to opt into showing a cover photo
-- in OpenGraph link previews, and optionally pin a specific cover asset.

ALTER TABLE shares ADD COLUMN IF NOT EXISTS show_cover BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE shares ADD COLUMN IF NOT EXISTS cover_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;
