-- The people a face must never be assigned to: someone took it away from
-- them (POST /faces/unassign). Matching skips them, and a face found again
-- in the same place on a re-analysis carries the list over (atlas-ml).
ALTER TABLE faces ADD COLUMN IF NOT EXISTS vetoed BIGINT[] NOT NULL DEFAULT '{}';
