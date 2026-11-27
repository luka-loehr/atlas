//! `atlas openapi` — fetch the server's OpenAPI 3.1 schema (`GET /openapi.json`).

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;

use crate::client::AtlasClient;
use crate::cmd::{argv_with_name, run_async};
use crate::{GREEN, RESET};

#[derive(Parser)]
#[command(
    name = "atlas openapi",
    about = "Fetch the Atlas server OpenAPI 3.1 specification (GET /openapi.json)"
)]
struct OpenApiCli {
    /// Write the schema to a file instead of printing to stdout
    #[arg(long, short = 'o')]
    out: Option<PathBuf>,
}

pub fn run(args: &[String]) {
    let cli = OpenApiCli::parse_from(argv_with_name("openapi", args));
    run_async(exec(cli.out));
}

async fn exec(out: Option<PathBuf>) -> Result<()> {
    let client = AtlasClient::from_env()?;
    let spec = client.get_text("/openapi.json").await?;

    // Pretty-print if valid JSON, otherwise emit as-is
    let formatted = match serde_json::from_str::<serde_json::Value>(&spec) {
        Ok(val) => serde_json::to_string_pretty(&val)? + "\n",
        Err(_) => spec,
    };

    if let Some(path) = out {
        tokio::fs::write(&path, formatted.as_bytes())
            .await
            .with_context(|| format!("failed to write {}", path.display()))?;
        println!("{GREEN}wrote{RESET} OpenAPI schema to {}", path.display());
    } else {
        print!("{formatted}");
    }
    Ok(())
}
