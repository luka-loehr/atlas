//! What atlas-server and atlas-ml share: how to reach the database, the
//! schema migrations, the job queue protocol both of them drain, and external
//! tools with a deadline.

pub mod db;
pub mod process;
pub mod queue;

/// The model behind every asset vector and every query vector:
/// WeMM-Embedding-2B. Each vector is stored under this name, and only rows
/// of this model are searched; a vector of another model lies in another
/// space and means nothing next to these.
pub const EMBED_MODEL: &str = "wemm2b";
/// Its full output size (the model allows Matryoshka truncation; Atlas keeps
/// all of it).
pub const EMBED_DIM: usize = 2048;

/// Structured logs to stderr (journald adds the timestamps). `ATLAS_LOG`
/// takes a tracing filter, e.g. `debug` or `atlas_server=debug,info`.
pub fn init_logging() {
    // onnxruntime narrates every arena allocation at info level
    let filter = std::env::var("ATLAS_LOG").unwrap_or_else(|_| "info,ort=warn".into());
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(filter))
        .with_target(false)
        .without_time()
        .init();
}

/// `$HOME`, which systemd sets from `User=`.
pub fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".into())
}

/// An environment variable, with empty treated as unset.
pub fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty())
}
