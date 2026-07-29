//! The host-Caddy admin interface (`http://localhost:2019`) plus the tunnel/DNS
//! checks. Every value interpolated into a remote shell here is validated
//! (`valid_host_label`, `valid_name`, `u16`) before it is used; the route JSON
//! is assembled from validated parts and passed to curl via `shq`.
//!
//! Steady-state `atlas dev --public` never needs the Cloudflare token: it only
//! talks to Caddy's localhost admin and relies on the pre-existing wildcard DNS
//! record. Caddy's admin API is localhost-only on the host.

use crate::project::{BuildCfg, branch_of_slug, dns_branch};
use crate::ssh::{shq, ssh_capture, ssh_ok};

const ADMIN: &str = "http://localhost:2019";

/// The stable Caddy `@id` handle for a project/branch route. `--`-delimited and
/// so free of the `__` a branch slug uses.
pub(crate) fn route_id(cfg: &BuildCfg, slug: &str) -> String {
    let branch = branch_of_slug(slug);
    if branch == "main" {
        format!("atlas-web--{}", cfg.name)
    } else {
        format!("atlas-web--{}--{}", cfg.name, dns_branch(&branch))
    }
}

/// Is Caddy's admin API reachable on the host?
pub(crate) fn caddy_admin_ok() -> bool {
    ssh_ok(&format!("curl -sf {ADMIN}/config/ >/dev/null 2>&1"))
}

/// Upsert (idempotent): delete any existing route with this id, then POST the
/// fresh one. `host`/`id` are validated and `port` is a u16, so the JSON cannot
/// carry an injection.
pub(crate) fn caddy_route_upsert(host: &str, port: u16, id: &str) -> bool {
    let route = format!(
        "{{\"@id\":\"{id}\",\"match\":[{{\"host\":[\"{host}\"]}}],\
         \"handle\":[{{\"handler\":\"reverse_proxy\",\
         \"upstreams\":[{{\"dial\":\"127.0.0.1:{port}\"}}]}}]}}"
    );
    ssh_ok(&format!(
        "curl -sf -X DELETE {ADMIN}/id/{id} >/dev/null 2>&1; \
         curl -sf -H 'Content-Type: application/json' -X POST \
         {ADMIN}/config/apps/http/servers/atlas/routes -d {body}",
        body = shq(&route),
    ))
}

/// Remove a route by id (ignoring a 404).
pub(crate) fn caddy_route_remove(id: &str) -> bool {
    ssh_ok(&format!(
        "curl -sf -X DELETE {ADMIN}/id/{id} >/dev/null 2>&1; true"
    ))
}

/// Does a route with this id currently exist?
pub(crate) fn caddy_route_exists(id: &str) -> bool {
    ssh_capture(&format!(
        "curl -sf {ADMIN}/id/{id} >/dev/null 2>&1 && echo yes"
    ))
    .trim()
        == "yes"
}

/// All host labels Caddy currently routes, extracted from the routes JSON in one
/// round trip. Used by `atlas ls` to resolve a project's public URL.
pub(crate) fn caddy_route_hosts() -> Vec<String> {
    let json = ssh_capture(&format!(
        "curl -sf {ADMIN}/config/apps/http/servers/atlas/routes"
    ));
    let mut hosts = Vec::new();
    let needle = "\"host\":[\"";
    let mut rest = json.as_str();
    while let Some(i) = rest.find(needle) {
        rest = &rest[i + needle.len()..];
        if let Some(end) = rest.find('"') {
            hosts.push(rest[..end].to_string());
            rest = &rest[end..];
        } else {
            break;
        }
    }
    hosts
}

/// Is the persistent named Cloudflare tunnel active on the host?
pub(crate) fn tunnel_active() -> bool {
    ssh_ok("systemctl is-active --quiet cloudflared")
}

/// Does the wildcard DNS record resolve? (WARN-only doctor check.) A proxied
/// wildcard hides the cfargotunnel CNAME behind Cloudflare's anycast IPs, so we
/// simply confirm the fixed probe host resolves to something.
pub(crate) fn wildcard_dns_ok() -> bool {
    ssh_ok("dig +short atlas-doctor.lukaloehr.com 2>/dev/null | grep -q .")
}
