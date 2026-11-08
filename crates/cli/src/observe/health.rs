//! `atlas health`.

use std::process::{Command, exit};

use super::open::resolve_url;
use crate::build::take_branch;
use crate::project::{load_config, slug_of};
use crate::ssh::ssh_capture;
use crate::{GREEN, RED, RESET};

pub(crate) fn health(argv: &[String]) {
    let (branch, rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let local = rest.iter().any(|a| a == "--local");
    let cfg = load_config();
    let path = &cfg.health;

    if local {
        let target = format!("http://127.0.0.1:{}{path}", cfg.port);
        let code = ssh_capture(&format!(
            "curl -sS -o /dev/null -m 5 -w '%{{http_code}}' {target} 2>/dev/null"
        ));
        report_health(code.trim(), &target);
    } else {
        let Some(url) = resolve_url(&cfg, &slug) else {
            eprintln!("{RED}nothing running for {} @ {branch}{RESET}", cfg.name);
            exit(1);
        };
        let target = format!("{url}{path}");
        let out = Command::new("curl")
            .args([
                "-sS",
                "-o",
                "/dev/null",
                "-m",
                "5",
                "-w",
                "%{http_code}",
                &target,
            ])
            .output();
        let code = out
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        report_health(&code, &target);
    }
}

fn report_health(code: &str, target: &str) {
    let n: u32 = code.parse().unwrap_or(0);
    if (200..=399).contains(&n) {
        println!("{GREEN}healthy {n}{RESET}  {target}");
    } else {
        let shown = if code.is_empty() {
            "no response".to_string()
        } else {
            code.to_string()
        };
        eprintln!("{RED}unhealthy {shown}{RESET}  {target}");
        exit(1);
    }
}
