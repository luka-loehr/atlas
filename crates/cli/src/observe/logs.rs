//! `atlas logs`.

use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

use crate::build::take_branch;
use crate::config::ssh_host;
use crate::project::{load_config, slug_of};
use crate::serve::start_name;
use crate::ssh::ssh_ok;
use crate::{RED, RESET};

pub(crate) fn logs(argv: &[String]) {
    let (branch, rest) = take_branch(argv);
    let slug = slug_of(&branch);
    let cfg = load_config();
    let follow = rest.iter().any(|a| a == "--follow" || a == "-f");
    let want_dev = rest.iter().any(|a| a == "--dev");
    let want_start = rest.iter().any(|a| a == "--start");

    let dev = format!("atlas-dev-{}-{slug}", cfg.slug_id());
    let start = start_name(&cfg, &slug);
    let dev_up = container_running(&dev);
    let start_up = container_running(&start);

    let container = if want_dev {
        dev.clone()
    } else if want_start {
        start.clone()
    } else if dev_up {
        dev.clone()
    } else if start_up {
        start.clone()
    } else {
        dev.clone()
    };

    if !ssh_ok(&format!("docker inspect {container} >/dev/null 2>&1")) {
        eprintln!(
            "{RED}no dev/start container for {} @ {branch}{RESET} — atlas dev | atlas start",
            cfg.name
        );
        exit(1);
    }

    if follow {
        let err = Command::new("ssh")
            .args(["-t", ssh_host(), &format!("docker logs -f {container}")])
            .exec();
        eprintln!("ssh: {err}");
        exit(1);
    }
    Command::new("ssh")
        .args([ssh_host(), &format!("docker logs --tail 200 {container}")])
        .status()
        .ok();
}

fn container_running(name: &str) -> bool {
    ssh_ok(&format!("docker ps -q --filter name=^{name}$ | grep -q ."))
}
