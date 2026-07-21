# atlas-photos pipeline — ops runbook

Two always-on workers on **atlas** that drain the `ingest_jobs` queue in Postgres
(container `atlas-postgres`, `127.0.0.1:5432`, db/user `atlas`):

| Service        | Jobs                                  | Image base              |
|----------------|---------------------------------------|-------------------------|
| `pipeline-cpu` | thumb, meta, geocode, event_scan      | python:3.12-slim        |
| `pipeline-gpu` | embed (Qwen3-VL-Embedding-2B), faces (InsightFace), caption→tags (vLLM Qwen2.5-VL-3B-AWQ) | vllm/vllm-openai:latest |

The pipeline **source is mounted** into the containers at `/app` (read-only), not
baked into the images. Deploying new code:

```bash
cd ~/atlas && git pull
docker compose -p atlas-pipeline restart
```

Rebuild only when *dependencies* change (Dockerfile edits):

```bash
cd ~/atlas/apps/atlas-photos/pipeline
docker compose up -d --build
```

## First start

```bash
cd ~/atlas/apps/atlas-photos/pipeline
docker compose up -d --build
```

Expectations:

- `vllm/vllm-openai:latest` pull is **large** (~10 GB download, ~20 GB on disk);
  the CPU image is ~1 GB. One-time cost.
- On its **first start the GPU container downloads ~6 GB of models**
  (Qwen3-VL-Embedding-2B, buffalo_l, Qwen2.5-VL-3B-AWQ) into `/home/atlas/models`
  before the worker loop begins — watch `docker logs -f pipeline-gpu`.
  Subsequent starts skip this (idempotent check).
- Requires migration 003 to be applied (queue columns, faces.embedding,
  persons.centroid, tags, caption column).

## Autostart — "power button is all"

Both services use `restart: unless-stopped` and the Docker daemon is enabled at
boot (`systemctl is-enabled docker`). Power the box on → Docker starts → both
workers start → the reaper self-heals any jobs that were mid-flight at power
loss. There is nothing else to start, ever. (`unless-stopped` also means an
explicit `docker compose stop` survives reboots — the workers stay down until
you `start` them again.)

## Watching it work

```bash
docker logs -f pipeline-cpu
docker logs -f pipeline-gpu
docker stats pipeline-gpu          # VRAM pressure shows as host RAM here; use nvidia-smi for VRAM
nvidia-smi                          # exactly ONE model resident at a time by design
```

Queue depth by kind/status:

```bash
docker exec -it atlas-postgres psql -U atlas -d atlas -c \
  "SELECT kind, status, count(*) FROM ingest_jobs GROUP BY 1,2 ORDER BY 1,2;"
```

Failures (gave up after 5 attempts):

```bash
docker exec -it atlas-postgres psql -U atlas -d atlas -c \
  "SELECT id, kind, owner_id, attempts, left(error, 120) FROM ingest_jobs WHERE status='failed' ORDER BY updated_at DESC LIMIT 20;"
```

## Re-indexing a single asset

Every handler is idempotent, so re-running is always safe. Flip the job(s) back
to pending (the `<sha256>` is `assets.id`):

```sql
-- one stage for one asset:
UPDATE ingest_jobs SET status='pending', attempts=0, error=NULL, run_after=now()
WHERE kind='caption' AND owner_type='asset' AND owner_id='<sha256>';

-- everything for one asset:
UPDATE ingest_jobs SET status='pending', attempts=0, error=NULL, run_after=now()
WHERE owner_type='asset' AND owner_id='<sha256>';
```

If no job row exists yet (new stage for an old asset), insert one — the unique
key makes it a no-op if it's already there:

```sql
INSERT INTO ingest_jobs (kind, owner_type, owner_id, status)
VALUES ('embed', 'asset', '<sha256>', 'pending')
ON CONFLICT (kind, owner_type, owner_id) DO NOTHING;
```

Workers pick pending jobs up within one loop iteration (≤ ~30 s).

## Crash safety — why power-off at ANY moment is fine

- **Claiming** is a single atomic `UPDATE ... FOR UPDATE SKIP LOCKED` statement:
  a job is claimed exactly once, no matter how many workers race.
- Running jobs **heartbeat every 60 s**. A **reaper** (at every worker startup
  and every 5 min) resets jobs whose heartbeat is older than 10 minutes back to
  `pending`. So a job orphaned by a crash/power cut is re-queued automatically
  at the next boot — no manual intervention.
- Every handler is **idempotent** (pure upserts, or delete-then-insert per
  asset in one transaction). A job that ran halfway and is retried produces the
  same end state, never duplicates.
- Failures retry with backoff (`attempts * 5 min`), giving up into `failed`
  after 5 attempts — visible via the SQL above, never silently looping.
- `event_scan` is a self-perpetuating singleton: instead of finishing it
  re-schedules itself 6 h out, so the queue itself keeps it alive forever.

Net effect: yanking the power cord mid-caption costs you at most 10 minutes of
reaper timeout after the next boot. Nothing is lost, nothing is duplicated.

## GPU sequencing (8 GB VRAM)

One GPU worker process drains stages strictly in sequence — all `embed`, then
all `faces`, then all `caption` — loading one model at a time and freeing VRAM
between stages. The vLLM engine only exists while caption jobs are pending.
If `nvidia-smi` ever shows two models resident, that is a bug.
