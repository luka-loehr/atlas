//! The queue and the schema against a real Postgres (with pgvector). Runs
//! only when ATLAS_TEST_DATABASE_URL names a database it may wipe, e.g.
//!
//!   docker run -d --rm -e POSTGRES_USER=atlas -e POSTGRES_PASSWORD=test \
//!     -e POSTGRES_DB=atlas -p 127.0.0.1:55432:5432 pgvector/pgvector:pg17
//!   ATLAS_TEST_DATABASE_URL=postgres://atlas:test@127.0.0.1:55432/atlas \
//!     cargo test -p atlas-core --test queue_db -- --test-threads=1

use std::time::Duration;

use atlas_core::queue::{self, MAX_ATTEMPTS, MAX_HEALS};
use deadpool_postgres::Pool;

async fn database() -> Option<Pool> {
    let url = std::env::var("ATLAS_TEST_DATABASE_URL").ok()?;
    // SAFETY: set before any thread of this test reads the environment
    unsafe { std::env::set_var("ATLAS_DATABASE_URL", &url) };
    let pool = atlas_core::db::pool(4).unwrap();
    let c = pool.get().await.unwrap();
    c.batch_execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public; CREATE EXTENSION IF NOT EXISTS vector;")
        .await
        .unwrap();
    drop(c);
    atlas_core::db::migrate(&pool).await.unwrap();
    Some(pool)
}

async fn status(c: &tokio_postgres::Client, id: i64) -> (String, i32, i32, Option<String>) {
    let r = c.query_one("SELECT status, attempts, heals, error FROM ingest_jobs WHERE id = $1", &[&id]).await.unwrap();
    (r.get(0), r.get::<_, Option<i32>>(1).unwrap_or(0), r.get(2), r.get(3))
}

async fn claim_one(c: &tokio_postgres::Client, worker: &str, kind: &str) -> queue::Job {
    c.execute("UPDATE ingest_jobs SET run_after = now() WHERE status = 'pending'", &[]).await.unwrap();
    queue::claim(c, worker, &[kind], 1).await.unwrap().pop().expect("a job to claim")
}

#[tokio::test]
async fn a_job_that_keeps_failing_ends_stuck_and_blocks_nothing() {
    let Some(pool) = database().await else { return };
    let c = pool.get().await.unwrap();
    queue::enqueue(&c, queue::THUMB, "asset", "bad", 10).await.unwrap();
    queue::enqueue(&c, queue::THUMB, "asset", "good", 100).await.unwrap();

    let mut id = 0;
    for _ in 0..MAX_ATTEMPTS {
        let job = claim_one(&c, "server:test:1", queue::THUMB).await;
        assert_eq!(job.owner_id, "bad", "the failing job has the higher priority");
        id = job.id;
        queue::fail(&c, job.id, "corrupt").await.unwrap();
    }
    assert_eq!(status(&c, id).await.0, "failed");
    // the other job is not held up
    assert_eq!(claim_one(&c, "server:test:1", queue::THUMB).await.owner_id, "good");

    // the healer leaves a fresh failure alone, retries an old one ...
    assert_eq!(queue::heal(&c).await.unwrap(), queue::Healed::default());
    for heal in 1..=MAX_HEALS {
        c.execute("UPDATE ingest_jobs SET updated_at = now() - interval '7 hours' WHERE id = $1", &[&id]).await.unwrap();
        assert_eq!(queue::heal(&c).await.unwrap().retried, 1);
        let (state, attempts, heals, _) = status(&c, id).await;
        assert_eq!((state.as_str(), attempts, heals), ("pending", 0, heal));
        for _ in 0..MAX_ATTEMPTS {
            let job = claim_one(&c, "server:test:1", queue::THUMB).await;
            queue::fail(&c, job.id, "corrupt").await.unwrap();
        }
    }
    // ... and parks it once its heals are used up
    assert_eq!(queue::heal(&c).await.unwrap().stuck, 1);
    assert_eq!(status(&c, id).await.0, "stuck");
    assert!(queue::claim(&c, "server:test:1", &[queue::THUMB], 1).await.unwrap().is_empty());

    // what it waited for is back: it starts over
    queue::ensure(&c, queue::THUMB, "asset", "bad", 10).await.unwrap();
    let (state, attempts, heals, error) = status(&c, id).await;
    assert_eq!((state.as_str(), attempts, heals, error), ("pending", 0, 0, None));
}

#[tokio::test]
async fn crashed_and_stopped_workers_give_their_jobs_back() {
    let Some(pool) = database().await else { return };
    let c = pool.get().await.unwrap();
    for owner in ["a", "b", "c"] {
        queue::enqueue(&c, queue::EMBED, "asset", owner, 100).await.unwrap();
    }
    let crashed = claim_one(&c, "ml:111:embed", queue::EMBED).await;
    let stopped = claim_one(&c, "ml:222:embed", queue::EMBED).await;
    let stale = claim_one(&c, "server:x:9", queue::EMBED).await;

    // a clean shutdown hands its job back unspent
    assert_eq!(queue::release(&c, "ml:222:embed").await.unwrap(), 1);
    assert_eq!(status(&c, stopped.id).await.0, "pending");
    assert_eq!(status(&c, stopped.id).await.1, 0);

    // a new atlas-ml finds what the crashed one held: an attempt spent
    assert_eq!(queue::recover(&c, "ml:").await.unwrap(), 1);
    let (state, attempts, _, error) = status(&c, crashed.id).await;
    assert_eq!((state.as_str(), attempts), ("pending", 1));
    assert_eq!(error.as_deref(), Some("its worker stopped during the job"));

    // a job whose heartbeat stopped is reaped; one that crashes its worker
    // every time ends failed instead of looping
    c.execute("UPDATE ingest_jobs SET heartbeat_at = now() - interval '11 minutes' WHERE id = $1", &[&stale.id])
        .await
        .unwrap();
    assert_eq!(queue::reap(&c).await.unwrap(), 1);
    for _ in 1..MAX_ATTEMPTS {
        c.execute(
            "UPDATE ingest_jobs SET status = 'running', heartbeat_at = now() - interval '11 minutes' WHERE id = $1",
            &[&stale.id],
        )
        .await
        .unwrap();
        queue::reap(&c).await.unwrap();
    }
    assert_eq!(status(&c, stale.id).await.0, "failed");
}

#[tokio::test]
async fn deferrals_are_counted_and_unknown_kinds_parked() {
    let Some(pool) = database().await else { return };
    let c = pool.get().await.unwrap();
    queue::enqueue(&c, queue::FACES, "asset", "x", 100).await.unwrap();
    let job = claim_one(&c, "ml:1:faces", queue::FACES).await;
    assert_eq!(job.defers, 0);
    queue::defer(&c, job.id, Duration::ZERO, Some("no thumbnail yet")).await.unwrap();
    assert_eq!(claim_one(&c, "ml:1:faces", queue::FACES).await.defers, 1);

    queue::enqueue(&c, "caption", "asset", "x", 100).await.unwrap();
    assert_eq!(queue::heal(&c).await.unwrap().stuck, 1);
    let r = c.query_one("SELECT status, error FROM ingest_jobs WHERE kind = 'caption'", &[]).await.unwrap();
    assert_eq!(r.get::<_, String>(0), "stuck");
    assert_eq!(r.get::<_, Option<String>>(1).as_deref(), Some("no worker runs jobs of this kind"));
}

#[tokio::test]
async fn the_timeline_hears_only_about_what_it_shows() {
    let Some(pool) = database().await else { return };
    let c = pool.get().await.unwrap();
    c.execute(
        "INSERT INTO assets (id, type, orig_path, taken_at) VALUES ('t1', 'photo', '/x.jpg', now())",
        &[],
    )
    .await
    .unwrap();
    let mut heard = atlas_core::db::listen(&["atlas_assets"]);
    // the listener connects in the background
    tokio::time::sleep(Duration::from_millis(500)).await;
    while heard.try_recv().is_ok() {}

    let quiet = |sql: &'static str| {
        let c = &c;
        async move { c.execute(sql, &[]).await.unwrap() }
    };
    quiet("UPDATE assets SET favorite = favorite WHERE false").await;
    quiet("UPDATE assets SET favorite = favorite").await;
    quiet("UPDATE assets SET preview_at = now(), thumb_v = 2, exif = '{}'::jsonb").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(heard.try_recv().is_err(), "a change to nothing shown must not drop the cache");

    quiet("UPDATE assets SET favorite = NOT favorite").await;
    let channel = tokio::time::timeout(Duration::from_secs(5), heard.recv()).await.expect("notified");
    assert_eq!(channel, Some("atlas_assets"));
    quiet("DELETE FROM assets").await;
    assert!(tokio::time::timeout(Duration::from_secs(5), heard.recv()).await.is_ok());
}

#[tokio::test]
async fn tags_and_events_are_gone() {
    let Some(pool) = database().await else { return };
    let c = pool.get().await.unwrap();
    let r = c.query_one("SELECT to_regclass('tags') IS NULL, to_regclass('events') IS NULL", &[]).await.unwrap();
    assert!(r.get::<_, bool>(0) && r.get::<_, bool>(1));
}
