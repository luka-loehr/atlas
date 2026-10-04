-- One link per album that follows the album, and the password kept for the
-- link's lifetime (at most 7 days) so the app can show it again.
-- `live`: the manifest has been written at least once, so the link opens.
ALTER TABLE shares ADD COLUMN live boolean NOT NULL DEFAULT false;
UPDATE shares SET live = true WHERE state = 'ready';
