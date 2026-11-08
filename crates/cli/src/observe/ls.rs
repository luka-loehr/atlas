//! `atlas ls`.

use crate::ssh::ssh_capture;
use crate::web::caddy_route_hosts;

/// Fleet overview of every project under ~/atlas-builds.
pub(crate) fn ls() {
    let emitter = r#"cd "$HOME/atlas-builds" 2>/dev/null || exit 0
for d in */; do d=${d%/}; [ "$d" = ".cache-universal" -o "$d" = ".cache-mobile" ] && continue
  [ -f "$d/meta.json" ] || [ -d "$d/state" ] || continue
  name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null); [ -z "$name" ] && name="$d"
  hash=$(sed -n 's/.*"hash":"\([^"]*\)".*/\1/p' "$d/meta.json" 2>/dev/null)
  br=$(ls "$d/state" 2>/dev/null | sed 's/\.json$//' | tr '\n' ',' | sed 's/,$//')
  run=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^atlas-(dev|start)-$name-$hash-" | sed -E "s/^atlas-(dev|start)-$name-$hash-/\1:/" | tr '\n' ',' | sed 's/,$//')
  disk=$(du -sh "$d" 2>/dev/null | cut -f1)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$hash" "$br" "$run" "$disk"
done"#;
    let out = ssh_capture(emitter);
    let lines: Vec<&str> = out.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        println!("no projects on atlas");
        return;
    }
    let hosts = caddy_route_hosts();

    struct Row {
        name: String,
        hash: String,
        built: String,
        running: String,
        url: String,
        disk: String,
    }
    let mut rows: Vec<Row> = Vec::new();
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        let name = f.first().copied().unwrap_or("").to_string();
        let hash = f.get(1).copied().unwrap_or("").to_string();
        let built = slugs_to_branches(f.get(2).copied().unwrap_or(""));
        let running = f.get(3).copied().unwrap_or("").replace(',', " ");
        let disk = f.get(4).copied().unwrap_or("").to_string();
        let url = public_url_for(&name, &hosts).unwrap_or_else(|| "—".to_string());
        rows.push(Row {
            name,
            hash: if hash.is_empty() { "?".into() } else { hash },
            built: if built.is_empty() {
                "—".into()
            } else {
                built
            },
            running: if running.trim().is_empty() {
                "—".into()
            } else {
                running
            },
            url,
            disk: if disk.is_empty() { "?".into() } else { disk },
        });
    }

    let w = |sel: &dyn Fn(&Row) -> &str, head: &str| -> usize {
        rows.iter()
            .map(|r| sel(r).len())
            .chain(std::iter::once(head.len()))
            .max()
            .unwrap_or(0)
    };
    let wn = w(&|r| &r.name, "PROJECT");
    let wh = w(&|r| &r.hash, "HASH");
    let wb = w(&|r| &r.built, "BUILT");
    let wr = w(&|r| &r.running, "RUNNING");
    let wu = w(&|r| &r.url, "URL");
    println!(
        "{:<wn$}  {:<wh$}  {:<wb$}  {:<wr$}  {:<wu$}  DISK",
        "PROJECT", "HASH", "BUILT", "RUNNING", "URL"
    );
    for r in &rows {
        println!(
            "{:<wn$}  {:<wh$}  {:<wb$}  {:<wr$}  {:<wu$}  {}",
            r.name, r.hash, r.built, r.running, r.url, r.disk
        );
    }
}

fn slugs_to_branches(csv: &str) -> String {
    csv.split(',')
        .filter(|s| !s.is_empty())
        .map(crate::project::branch_of_slug)
        .collect::<Vec<_>>()
        .join(", ")
}

/// The public host for a project name, if Caddy currently routes one (needs
/// ATLAS_DEV_DOMAIN to know what the hosts look like).
fn public_url_for(name: &str, hosts: &[String]) -> Option<String> {
    let domain = crate::config::dev_domain()?;
    let exact = format!("{name}.{domain}");
    let prefix = format!("{name}-");
    let suffix = format!(".{domain}");
    hosts
        .iter()
        .find(|h| **h == exact || (h.starts_with(&prefix) && h.ends_with(&suffix)))
        .map(|h| format!("https://{h}"))
}
