//! The ingest stages that run inside the server. Each one is idempotent:
//! derived files are written atomically and overwritten freely, metadata
//! only fills columns that are still NULL, so a job re-run after a crash
//! changes nothing it should not.

pub mod backfill;
pub mod drive_text;
pub mod geocode;
pub mod meta;
pub mod preview;
pub mod thumb;
pub mod video;
pub mod worker;
