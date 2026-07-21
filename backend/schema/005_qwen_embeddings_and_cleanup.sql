-- 005: SigLIP2 -> Qwen3-VL-Embedding-2B migration + dead-feature cleanup.
--
-- Applied out-of-band on the production box during the embedding migration
-- (2026-07-21) and the follow-up audit; this file captures those changes so a
-- fresh setup (001..004 then this) reproduces the current schema. Idempotent.
--
--  * embeddings: image-only SigLIP2 (vector(768)) -> multimodal Qwen3-VL
--    (vector(2048), photos + videos in one text/image/video space). Search is
--    an EXACT fp32 cosine scan at this library size (~27k) — deliberately no
--    ANN index (an HNSW would only add an approximation error for no win while
--    the query embedding itself costs 1-3 s on CPU).
--  * captions were dropped (the generated sentences were ~90% junk); the
--    "caption" GPU stage now stores ONLY tags. assets.caption is therefore
--    dead. faces.cluster_id was superseded by person_id + persons.centroid.
--  * /api/graph was removed from the client, taking the person_cooccurrence
--    view with it. The dead faces HNSW index (0 scans) was write-amplification.

-- embeddings -> Qwen 2048-dim, old SigLIP index gone
DROP INDEX IF EXISTS embeddings_siglip_hnsw;
ALTER TABLE embeddings ALTER COLUMN vec TYPE vector(2048);

-- dead columns (100% NULL after the feature removals)
ALTER TABLE assets DROP COLUMN IF EXISTS caption;
ALTER TABLE faces  DROP COLUMN IF EXISTS cluster_id;

-- dead objects
DROP INDEX IF EXISTS faces_embedding_hnsw;      -- 0 scans; clustering is Python-side
DROP VIEW  IF EXISTS person_cooccurrence;       -- only the removed /api/graph read it

-- tags are produced by the Qwen2.5-VL vision model, not by a "caption" step
ALTER TABLE tags ALTER COLUMN source SET DEFAULT 'qwen2.5-vl';

INSERT INTO schema_migrations (version) VALUES (5) ON CONFLICT DO NOTHING;
