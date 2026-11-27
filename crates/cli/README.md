# atlas CLI

`atlas` is a single-binary Rust CLI that acts both as a **standalone cross-platform
Atlas API & S3 client** (working on any Linux or macOS machine without SSH) and as
the **homelab build & server controller** over SSH/Wake-on-LAN.

## Standalone API & S3 Client

Authenticate once with `atlas auth login --url http://<atlas-host>:8787 --key-stdin`
(saved atomically to `~/.config/atlas/credentials.json` with `0700`/`0600`
permissions) or pass `ATLAS_URL` + `ATLAS_API_KEY` (`ATLK…:atls_…` or
`ATLAS_ACCESS_KEY_ID` + `ATLAS_SECRET_ACCESS_KEY` or `ATLAS_TOKEN`).

| command | what it does |
|---|---|
| `atlas auth login \| status \| whoami \| logout` | verify credentials against `/v1/server`, save `0600` `credentials.json`, inspect identity |
| `atlas buckets ls \| create <name> \| info <name> \| rm <name>` | manage `media`, `files`, and custom buckets (quotas, object counts, sizes) |
| `atlas files ls [bucket[/prefix]] [-r]` (alias `atlas s3`) | list buckets or objects with S3 prefix/delimiter folding |
| `atlas files put <local> <bucket/key>` | streaming upload with SigV4 (automatic 16 MiB S3 Multipart Upload above `--multipart-mb`, default 64 MiB) |
| `atlas files get <bucket/key> [out \| -] [--range A-B]` | atomic streaming download or Range slice to file or stdout |
| `atlas files cp <src> <dst> [-r]` | local↔remote or zero-reupload server-side `CopyObject` |
| `atlas files sync <src> <dst> [--delete] [--dry-run]` | incremental directory↔bucket sync verified by size and SHA-256 |
| `atlas files rm <bucket/key> [-r]` · `stat` · `search` · `presign` | single/batch delete, metadata & SHA-256 inspection, full-text search, online/offline SigV4 presigned URLs |
| `atlas photos search <q>` · `similar <id>` · `upload <paths...>` · `get <id>` · `people` · `albums` · `stats` | semantic & OCR photo search, SHA-256 deduplicated library upload, original/WebP thumbnail download |
| `atlas keys ls \| create <name> \| revoke <id> \| rm <id>` | mint scoped API/S3 keys (`--scopes`, `--buckets`, `--rps`, `--expires-days`) and revoke instantly |
| `atlas accounts ls \| create <name> \| info <id> \| rm <id>` | manage `service`, `member`, and `admin` accounts and storage quotas |
| `atlas openapi [--out FILE]` | fetch the live OpenAPI 3.1 specification (`GET /openapi.json`) |

---

## Homelab Server & Build Control

`atlas` also controls the atlas homelab server from a workstation. It wraps SSH for everyday access,
manages power via Wake-on-LAN, offloads project builds and dev servers to the
server's Docker engine, publishes dev servers on the tailnet or on stable
`your-domain.com` subdomains, and installs the Atlas services
([atlas-server](../server) and [atlas-ml](../ml)) on the server.

Everything goes over `ssh`. Project source comes from GitHub, not from this
machine. The binary is Unix-only — a bare `atlas` replaces its own process with
`ssh`, so you get a real interactive session, not a wrapper. Anything the
dispatcher does not recognize as a verb is passed through verbatim as a remote
command (`atlas nvidia-smi`).

For the full story — how builds sync, how the images are structured, the config
schema in depth, repo-hash namespacing, and the dev-networking design — see the
[builder README](../../builder/README.md).

## Command surface

### Machine

| command | what it does |
|---|---|
| `atlas` | interactive SSH session (execs `ssh -t <host>`) |
| `atlas <cmd ...>` | run any command on the server (`atlas nvidia-smi`) |
| `atlas boot` (`up`, `wake`) | Wake-on-LAN, wait until reachable (120 s) |
| `atlas shutdown` (`off`, `poweroff`) | `sudo poweroff`, wait until down (60 s) |
| `atlas restart` (`reboot`) | `sudo reboot`, wait for down then back up |
| `atlas status` | up/down + which route answered (LAN / tailnet) |
| `atlas doctor` | preflight: reachability, docker, disk, images, tunnel, Caddy, sudo |

`boot`/`shutdown`/`restart` are synchronous — they poll to the target state, so
they chain in scripts (`atlas boot && atlas build`).

### Build

All build-family commands need an `atlas.toml`.
Shared flags: `--branch B` / `-b B` (default `main`), `--local` / `-l` (build
the working tree, no push), `--path D` / `-p D` (subdir as its own root),
`--target T` / `-t T` (a named `[target.T]` section). `--` ends atlas flags.
`--local` ⊥ `--branch`;
`--path` ⊥ `--target`.

| command | what it does |
|---|---|
| `atlas build [-b B]` | build a pushed branch on atlas (fetched from GitHub); artifacts stay on atlas |
| `atlas build --local` | build the local working tree (uncommitted, no push) |
| `atlas build --path D` | build subdir D as its own root (its own `atlas.toml`) |
| `atlas build --target T` | build the named `[target.T]` from the root config |
| `atlas build ... -- ...` | everything after `--` goes to the build command |
| `atlas test [-b B] [-- a]` | run tests on atlas (`cargo`/`npm test`); exit code returns |
| `atlas exec [-b B] -- CMD` | fresh-sync, then run CMD in the build root on atlas |
| `atlas run [-b B] -- CMD` | run a BUILT artifact on atlas (no sync, no rebuild) |
| `atlas watch` | local: watch the working tree, re-run `build --local` on change |

`test`/`exec`/`run` share `--local` / `--path D` / `--target T` and run with
`--network host`. `exec`/`run` take a program and its arguments verbatim — for
shell features, invoke a shell: `atlas exec -- sh -c 'a && b'`.

### Serve

| command | what it does |
|---|---|
| `atlas dev [-b B]` | dev server on atlas, on the tailnet (private, stable URL) |
| `atlas dev [-b B] --public` | publish at `https://<name>.your-domain.com` (stable) |
| `atlas dev [-b B] url\|logs\|stop` | print URL / follow dev logs / stop + tear down this project's route |
| `atlas start [-b B]` | run the BUILT result of this branch (never builds) |
| `atlas start [-b B] status\|logs\|stop` | inspect / tear down the started app |
| `atlas deploy` | build + install atlas-server and atlas-ml on the server · `deploy logs\|status\|stop\|restart` |
| `atlas connect` | print the `atlas://connect?…` link that connects the iOS app (server address + token) |
| `atlas share setup` | deploy [atlas-share](../../share/) to your Cloudflare account for share links; asks which of your domains links live on (`atlas-share.<domain>`) or uses workers.dev. `--domain D`, `--workers-dev`, `--url U` skip the question |
| `atlas share status \| ls \| rm <id>` | is it live · live links with progress and time left · stop a link |
| `atlas share destroy` | remove everything setup made from Cloudflare (links, bucket, Worker with its cron, secrets and domains) and disconnect the server; `--yes` skips the question |

### Observe

| command | what it does |
|---|---|
| `atlas ls` | fleet: every project on atlas — branches, running, URL, disk |
| `atlas logs [-b B] [-f] [--dev\|--start]` | `docker logs` of this project's dev/start container (last 200 lines; `-f` follows) |
| `atlas health [-b B] [--local]` | HTTP-probe the dev/start URL (with `--local`: `127.0.0.1:<port>` on the server) at `health`; non-zero exit if unhealthy |
| `atlas open [-b B]` | open the dev/start URL in the local browser (runs macOS `open`) |
| `atlas info` | this project: name, repo, hash, remote dir, image, URL, secrets |

### Config

| command | what it does |
|---|---|
| `atlas secrets push [file]` | upload this project's env file (never in git, `0600` on atlas) |
| `atlas secrets list` / `secrets rm` | which projects have one · drop this project's |
| `atlas migrate [--force]` | converts a `.atlas-build.toml` config file to `atlas.toml` (deleting the source); `--force` overwrites an existing `atlas.toml` |
| `atlas help` (`-h`, `--help`) | usage |
| `atlas --version` (`-V`, `version`) | print the version |

## Configuration file — `atlas.toml`

Per-project config lives in an `atlas.toml` at the project root; the CLI walks
up from the current directory until it finds one — `atlas.toml` is the only
filename it looks for. It is a flat `key = value` list (not full TOML) with
quoted or bare values, `#` comments, and optional `[target.NAME]` sections.

Source comes from **GitHub**, not from this machine: the server clones the repo
and keeps a worktree per branch. Push before you build. `--branch B` / `-b B`
selects the branch (default `main`); `--local` builds the working tree instead.

```toml
name      = "my-app"         # required — project id + container prefix (A-Za-z0-9._-)
image     = "universal"      # required — builder key: universal | mobile
dir       = "web"            # subdir (relative to this file) the build/dev runs in
build     = "pnpm build"     # build command (required for `atlas build`)
artifacts = "dist"           # whitespace-separated paths, relative to `dir`, the build must produce (required for `atlas build`)
test      = "pnpm test"      # test command for `atlas test` (default: detect)
dev       = "pnpm dev --host 0.0.0.0 --port 3000"  # dev-server command
start     = "pnpm start"     # run the BUILT artifact, for `atlas start` (default: detect)
install   = "pnpm install"   # dep install before dev (default: detect from lockfile)
repo      = "https://..."    # git URL to clone (default: this checkout's origin)
port      = 3000             # port the server binds (default 3000; not 22, 2019, 5432, 8080, 8785-8787)
health    = "/api/health"    # path `atlas health` probes (default /)
```

See the [builder README](../../builder/README.md#configuration--atlastoml) for the
full schema table, `[target.NAME]` semantics, and lockfile-based install/start
detection.

### Repo-hash namespacing

Each project's remote directory and container names are keyed by `name` **and**
a short deterministic hash of the origin git URL —
`~/atlas-builds/<name>-<hash8>/`. Two different repos that happen to share a
`name` (e.g. a `test-harness` config that ships in both a frontend and a
backend repo) cannot clobber each other's build tree, state, or
containers. The hash is stable across machines, installs and Rust releases; the
tailnet dev port and the public subdomain label stay name-based on purpose (URL
stability). See [the builder README](../../builder/README.md#repo-hash-namespacing--why-a-name-is-not-enough).

## Dev networking — one-liner

`atlas dev` is **tailnet-private by default** (`tailscale serve` →
`https://<tailnet host>:<port>`, port derived from `name` so it never moves);
`atlas dev --public` publishes at a **stable** subdomain —
`https://<name>.your-domain.com` for `main`, `https://<name>-<dns-branch>.your-domain.com`
otherwise — via a persistent host Cloudflare Tunnel + host Caddy and a wildcard
`*.your-domain.com` DNS record. `atlas dev --public` needs no Cloudflare token at
runtime; it only upserts a Caddy route. If the tunnel or Caddy is down it prints
`run scripts/proxy/install.sh on atlas` and exits non-zero.

## Build & install

Requires Rust 1.88 or newer (edition 2024, let chains) and a Unix OS (the CLI
uses `exec()`; it does not build on Windows).

```bash
cargo install --path crates/cli    # from the repo root — installs `atlas` into ~/.cargo/bin
```

Client-side you need `ssh` (a host alias matching `ATLAS_SSH_HOST` with
non-interactive key auth), and `git` for reading a project's `origin` remote.
`--local` builds (and `atlas watch`) also need `rsync`, `atlas health` needs
`curl`, and `atlas share setup` / `share destroy` need Node.js (`npx`, for
Cloudflare's wrangler) and must run inside a checkout of this repository (or
with `ATLAS_SHARE_DIR` pointing at its `share/` directory).
Machine-level setup is covered in [docs/SETUP.md](../../docs/SETUP.md).

## Configuration (environment)

Every value resolves in order: environment variable → the optional file
`~/.config/atlas/env` (plain `KEY=VALUE` lines, `#` comments, optional quotes) →
a generic built-in default. The file keeps personal addresses out of shell
profiles and the repo.

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_SSH_HOST` | `atlas` | ssh host (alias from `~/.ssh/config`) |
| `ATLAS_LAN_ADDR` | `192.168.1.100:22` | LAN ssh route, `host:port` (empty = skip) |
| `ATLAS_TAILNET_ADDR` | `atlas.your-tailnet.ts.net:22` | tailnet ssh route, `host:port` (empty = skip); its host is also where `atlas dev` / `atlas start` publish — while it is still the placeholder, tailnet dev refuses to start |
| `ATLAS_WOL_MAC` | `aa:bb:cc:dd:ee:ff` | server NIC MAC for Wake-on-LAN (placeholder — `boot` warns until set) |
| `ATLAS_WOL_BROADCAST` | `192.168.1.255:9` | broadcast `addr:port` for the magic packet |
| `ATLAS_SERVER_URL` | tailnet host + `:8787` | atlas-server `host:port`, printed after `atlas deploy` and put into the `atlas connect` link |
| `ATLAS_DEV_DOMAIN` | *(empty)* | your Cloudflare-managed domain for `atlas dev --public` URLs (`<name>.<domain>`); empty = tailnet dev only. Bring-up: [`scripts/proxy/`](../../scripts/proxy/) |

The CLI relies on SSH `ControlMaster` multiplexing from `~/.ssh/config`
(`ControlPath ~/.ssh/cm/%r@%h:%p`, `ControlPersist`); it never sets conflicting
`-o ControlMaster` / `-S` flags of its own.

## Server prerequisites

- a systemd Linux with sshd on port 22 and Wake-on-LAN enabled — see
  [docs/SETUP.md](../../docs/SETUP.md)
- this repository cloned at `~/atlas` with a reachable git remote
  (`build`/`dev` build images from it; `deploy` resets it to `origin/main`)
- Docker Engine, with the SSH user in the `docker` group
- `git`, and credentials for any private repo you build (the server clones over
  https, so `~/.git-credentials` or a credential helper)
- passwordless sudo: `poweroff` and `reboot` (power commands), `chown`
  (`build`/`test`/`exec`/`run`), `tailscale serve` (`atlas dev` / `atlas start`),
  `sed` (`atlas connect`, `atlas share`), `systemctl` and `tee` (`atlas deploy`,
  `atlas share setup`/`destroy`), and for `atlas deploy` also `install`, `test`,
  `rm`, `mkdir` and `mv`; `atlas doctor` checks `sudo -n true`
- for `atlas dev --public`: the dev-subdomain proxy infra (host Caddy + a named
  Cloudflare Tunnel + a `*.your-domain.com` wildcard DNS record), installed once
  by [`scripts/proxy/`](../../scripts/proxy/) and verified by `atlas doctor`
- a Rust toolchain sourced from `~/.cargo/env` (only needed for `atlas deploy`)
