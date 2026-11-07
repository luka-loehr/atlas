-- People the owner does not want to see (the school staff of a group
-- photo): out of People, search and the info panel. They keep their faces,
-- so the same stranger in another photo is recognized and stays hidden too
-- instead of turning up as someone new.
ALTER TABLE persons ADD COLUMN IF NOT EXISTS hidden BOOLEAN NOT NULL DEFAULT false;
