//! The hourly check-up of the pipeline. Whatever went wrong, the library
//! converges: jobs whose photo or file is gone are dropped, every asset gets
//! the jobs its stage needs (a crash between storing a photo and queueing
//! its work, a job deleted by hand), and the queue's own healing runs
//! (failed jobs retried later, for good: 'stuck', see `queue::heal`).

use anyhow::Result;
use atlas_core::queue;

use crate::App;

/// Below what the phone uploads: repairs never get in front of real work.
const REPAIR_PRIORITY: i32 = queue::PRIORITY_DEFAULT + 100;

#[derive(Debug, Default)]
pub struct Report {
    pub dropped: u64,
    pub queued: u64,
    pub healed: queue::Healed,
}

pub async fn run(app: &App) -> Result<Report> {
    let c = app.pool.get().await?;
    let report = repair(&c).await?;
    if report.queued > 0 {
        app.jobs_wake.notify_waiters();
    }
    Ok(report)
}

async fn repair(c: &tokio_postgres::Client) -> Result<Report> {
    let mut report = Report { healed: queue::heal(c).await?, ..Report::default() };

    // jobs whose owner is gone can never succeed
    report.dropped += c
        .execute(
            "DELETE FROM ingest_jobs j
              WHERE j.status <> 'running' AND j.owner_type = 'asset'
                AND NOT EXISTS (SELECT 1 FROM assets a WHERE a.id = j.owner_id)",
            &[],
        )
        .await?;
    report.dropped += c
        .execute(
            "DELETE FROM ingest_jobs j
              WHERE j.status <> 'running' AND j.owner_type = 'drive_file'
                AND NOT EXISTS (SELECT 1 FROM drive_files f WHERE f.id::text = j.owner_id)",
            &[],
        )
        .await?;

    // every asset has its thumbnail and metadata jobs; one with a thumbnail
    // also its model jobs, one with a location its geocoding
    let missing = [
        (vec![queue::THUMB, queue::META], "TRUE"),
        (vec![queue::EMBED, queue::FACES], "a.thumbhash IS NOT NULL"),
        (vec![queue::GEOCODE], "a.lat IS NOT NULL AND a.lon IS NOT NULL"),
    ];
    for (kinds, condition) in missing {
        report.queued += c
            .execute(
                &format!(
                    "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
                     SELECT k.kind, 'asset', a.id, $2 FROM assets a CROSS JOIN unnest($1::text[]) AS k(kind)
                      WHERE {condition}
                        AND NOT EXISTS (SELECT 1 FROM ingest_jobs j
                                         WHERE j.kind = k.kind AND j.owner_type = 'asset' AND j.owner_id = a.id)
                     ON CONFLICT (kind, owner_type, owner_id) DO NOTHING"
                ),
                &[&kinds, &REPAIR_PRIORITY],
            )
            .await?;
    }
    // an embedding that is done must have left a vector of the current
    // model: one written by an older model (a worker still on the previous
    // version when the model changed) or lost since is made again
    report.queued += c
        .execute(
            "UPDATE ingest_jobs j
                SET status = 'pending', attempts = 0, defers = 0, heals = 0, error = NULL, stuck_at = NULL,
                    run_after = now(), locked_by = NULL, heartbeat_at = NULL, priority = $3, updated_at = now()
              WHERE j.kind = $1 AND j.owner_type = 'asset' AND j.status = 'done'
                AND NOT EXISTS (SELECT 1 FROM embeddings e
                                 WHERE e.owner_type = 'asset' AND e.owner_id = j.owner_id AND e.model = $2)",
            &[&queue::EMBED, &atlas_core::EMBED_MODEL, &REPAIR_PRIORITY],
        )
        .await?;
    report.queued += c
        .execute(
            "INSERT INTO ingest_jobs (kind, owner_type, owner_id, priority)
             SELECT $1, 'drive_file', f.id::text, $2 FROM drive_files f
              WHERE f.text IS NULL
                AND NOT EXISTS (SELECT 1 FROM ingest_jobs j
                                 WHERE j.kind = $1 AND j.owner_type = 'drive_file' AND j.owner_id = f.id::text)
             ON CONFLICT (kind, owner_type, owner_id) DO NOTHING",
            &[&queue::DRIVE_TEXT, &REPAIR_PRIORITY],
        )
        .await?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Against a real Postgres, as atlas-core's queue_db tests:
    /// ATLAS_TEST_DATABASE_URL=postgres://… cargo test -p atlas-server heal -- --test-threads=1
    #[tokio::test]
    async fn missing_jobs_are_queued_and_orphans_dropped() {
        let Ok(url) = std::env::var("ATLAS_TEST_DATABASE_URL") else { return };
        // SAFETY: set before any thread of this test reads the environment
        unsafe { std::env::set_var("ATLAS_DATABASE_URL", &url) };
        let pool = atlas_core::db::pool(2).unwrap();
        let c = pool.get().await.unwrap();
        c.batch_execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION IF NOT EXISTS vector;")
            .await
            .unwrap();
        drop(c);
        atlas_core::db::migrate(&pool).await.unwrap();
        let c = pool.get().await.unwrap();
        c.batch_execute(
            "INSERT INTO assets (id, type, orig_path, thumbhash, lat, lon)
                  VALUES ('new', 'photo', '/n.jpg', NULL, NULL, NULL),
                         ('thumbed', 'photo', '/t.jpg', '\\x01', 48.1, 11.5),
                         ('current', 'photo', '/c.jpg', '\\x01', NULL, NULL),
                         ('older', 'photo', '/o.jpg', '\\x01', NULL, NULL);
             INSERT INTO ingest_jobs (kind, owner_type, owner_id, status)
                  VALUES ('thumb', 'asset', 'thumbed', 'done'), ('meta', 'asset', 'thumbed', 'done'),
                         ('thumb', 'asset', 'gone', 'failed');",
        )
        .await
        .unwrap();
        // two assets whose pipeline is done, one embedded by an older model
        for id in ["current", "older"] {
            for kind in ["thumb", "meta", "embed", "faces"] {
                c.execute(
                    "INSERT INTO ingest_jobs (kind, owner_type, owner_id, status) VALUES ($1, 'asset', $2, 'done')",
                    &[&kind, &id],
                )
                .await
                .unwrap();
            }
        }
        let zero = pgvector::Vector::from(vec![0.0f32; atlas_core::EMBED_DIM]);
        c.execute(
            "INSERT INTO embeddings (owner_type, owner_id, model, vec) VALUES ('asset', 'current', $1, $3), ('asset', 'older', $2, $3)",
            &[&atlas_core::EMBED_MODEL, &"qwen3vl", &zero],
        )
        .await
        .unwrap();

        let report = repair(&c).await.unwrap();
        assert_eq!(report.dropped, 1, "the job of an asset that no longer exists");
        let jobs: Vec<(String, String)> = c
            .query("SELECT owner_id, kind FROM ingest_jobs WHERE status = 'pending' ORDER BY 1, 2", &[])
            .await
            .unwrap()
            .iter()
            .map(|r| (r.get(0), r.get(1)))
            .collect();
        let want = [
            ("new", "meta"),
            ("new", "thumb"),
            ("older", "embed"),
            ("thumbed", "embed"),
            ("thumbed", "faces"),
            ("thumbed", "geocode"),
        ];
        assert_eq!(jobs, want.map(|(o, k)| (o.to_string(), k.to_string())));
        assert_eq!(report.queued, 6);
        // a second check-up finds nothing to do
        let again = repair(&c).await.unwrap();
        assert_eq!((again.queued, again.dropped), (0, 0));
    }
}
