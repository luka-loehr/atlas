//! `atlas info`.

use crate::config::tailnet_host;
use crate::project::{host_label, load_config, valid_host_label};
use crate::serve::{port_key, tailnet_port};
use crate::ssh::ssh_ok;
use crate::state::built_branches;
use crate::{DIM, RESET};

pub(crate) fn info() {
    let cfg = load_config();
    let slug = "main";
    let label = host_label(&cfg, slug);
    let public = match crate::config::dev_domain() {
        None => "(ATLAS_DEV_DOMAIN unset — tailnet only)".into(),
        Some(d) if valid_host_label(&label) => format!("https://{label}.{d}"),
        Some(_) => format!("(invalid host label from name '{}')", cfg.name),
    };

    println!("{:<12}{}", "name", cfg.name);
    println!("{:<12}{}", "repo", cfg.canonical_url);
    println!("{:<12}{}", "hash", cfg.repo_hash);
    println!("{:<12}~/{}", "remote dir", cfg.base_dir());
    println!("{:<12}{}", "image", cfg.image);
    println!("{:<12}{}   health {}", "port", cfg.port, cfg.health);
    println!("{:<12}{}        {DIM}(public){RESET}", "dev url", public);
    if let Some(host) = tailnet_host() {
        let port = tailnet_port(&port_key(&cfg, slug, "dev"));
        println!("{:<12}https://{host}:{port}   {DIM}(tailnet){RESET}", "");
    }

    let built = built_branches(&cfg);
    println!(
        "{:<12}{}",
        "built",
        if built.is_empty() {
            "—".into()
        } else {
            built.join(", ")
        }
    );

    let hashed = cfg.secrets_file();
    let legacy = cfg.legacy_secrets_file();
    let has_hashed = ssh_ok(&format!("test -f \"$HOME/{hashed}\""));
    let has_legacy = !has_hashed && ssh_ok(&format!("test -f \"$HOME/{legacy}\""));
    if has_hashed {
        println!("{:<12}pushed        {DIM}(~/{hashed}){RESET}", "secrets");
    } else if has_legacy {
        println!(
            "{:<12}pushed (un-hashed ~/{legacy} — re-push to namespace)",
            "secrets"
        );
    } else {
        println!("{:<12}not pushed", "secrets");
    }
}
