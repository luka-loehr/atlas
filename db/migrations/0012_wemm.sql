-- WeMM-Embedding-2B replaces Qwen3-VL-Embedding-2B (Atlas 0.4.0). The two
-- models map into different spaces, so no old vector can stand next to a new
-- one: they are dropped, and every asset without a vector of the new model
-- is queued to be embedded again.
--
-- The re-run sits behind fresh uploads (10 / 100) and the hourly repairs
-- (200), stills before clips, which take several stills' time each. atlas-ml
-- works it off on the GPU whenever it runs; the queue lives in Postgres and
-- picks up where it stopped after a restart or a power-off.
DELETE FROM embeddings WHERE model <> 'wemm2b';

INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
SELECT 'embed', 'asset', a.id, CASE WHEN a.type = 'video' THEN 320 ELSE 300 END
  FROM assets a
 WHERE NOT EXISTS (SELECT 1 FROM embeddings e
                    WHERE e.owner_type = 'asset' AND e.owner_id = a.id AND e.model = 'wemm2b')
ON CONFLICT (kind, owner_type, owner_id) DO UPDATE
    SET status = 'pending', attempts = 0, defers = 0, heals = 0, error = NULL, stuck_at = NULL,
        run_after = now(), locked_by = NULL, heartbeat_at = NULL,
        priority = EXCLUDED.priority, updated_at = now()
  WHERE ingest_jobs.status <> 'running';
