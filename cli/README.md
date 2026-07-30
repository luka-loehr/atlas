# atlas CLI

`atlas` is a single-binary Rust CLI (std only, zero dependencies) that controls
the atlas homelab server from a workstation. It wraps SSH for everyday access,
manages power via Wake-on-LAN, offloads project builds and dev servers to the
server's Docker engine, publishes dev servers on the tailnet or on stable
`lukaloehr.com` subdomains, and installs the companion control-plane
[api](../api).

Everything goes over `ssh`. Project source comes from GitHub, not from this
machine. The binary is Unix-only — a bare `atlas` replaces its own process with
`ssh`, so you get a real interactive session, not a wrapper. Anything the
dispatcher does not recognize as a verb is passed through verbatim as a remote
command (`atlas nvidia-smi`).

For the full story — how builds sync, how the images are structured, the config
schema in depth, repo-hash namespacing, and the dev-networking design — see the
[builder README](../builder/README.md).

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
| `atlas dev [-b B] --public` | publish at `https://<name>.lukaloehr.com` (stable) |
| `atlas dev [-b B] url\|logs\|stop` | print URL / follow dev logs / stop + tear down this project's route |
| `atlas start [-b B]` | run the BUILT result of this branch (never builds) |
| `atlas start [-b B] status\|logs\|stop` | inspect / tear down the started app |
| `atlas api` | build + install the control-plane API · `api logs\|status\|stop\|restart` |

### Observe

| command | what it does |
|---|---|
| `atlas ls` | fleet: every project on atlas — branches, running, URL, disk |
| `atlas logs [-b B] [-f] [--dev\|--start]` | `docker logs` of this project's dev/start container |
| `atlas health [-b B] [--local]` | HTTP-probe the dev/start URL at `health`; non-zero exit if unhealthy |
| `atlas open [-b B]` | open the dev/start URL in the local browser |
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
artifacts = "web/dist"       # whitespace-separated paths the build must produce
dev       = "pnpm dev --host 0.0.0.0 --port 3000"  # dev-server command
start     = "pnpm start"     # run the BUILT artifact, for `atlas start` (default: detect)
install   = "pnpm install"   # dep install before dev/start (default: detect from lockfile)
repo      = "https://..."    # git URL to clone (default: this checkout's origin)
port      = 3000             # port the server binds (default 3000)
health    = "/api/health"    # path `atlas health` probes (default /)
```

See the [builder README](../builder/README.md#configuration--atlastoml) for the
full schema table, `[target.NAME]` semantics, and lockfile-based install/start
detection.

### Repo-hash namespacing

Each project's remote directory and container names are keyed by `name` **and**
a short deterministic hash of the origin git URL —
`~/atlas-builds/<name>-<hash8>/`. Two different repos that happen to share a
`name` (e.g. the `rt-harness` config that ships in both `dairo-frontend` and
`dairo-backend`) cannot clobber each other's build tree, state, or
containers. The hash is stable across machines, installs and Rust releases; the
tailnet dev port and the public subdomain label stay name-based on purpose (URL
stability). See [the builder README](../builder/README.md#repo-hash-namespacing--why-a-name-is-not-enough).

## Dev networking — one-liner

`atlas dev` is **tailnet-private by default** (`tailscale serve` →
`https://<tailnet host>:<port>`, port derived from `name` so it never moves);
`atlas dev --public` publishes at a **stable** subdomain —
`https://<name>.lukaloehr.com` for `main`, `https://<name>-<dns-branch>.lukaloehr.com`
otherwise — via a persistent host Cloudflare Tunnel + host Caddy and a wildcard
`*.lukaloehr.com` DNS record. `atlas dev --public` needs no Cloudflare token at
runtime; it only upserts a Caddy route. If the tunnel or Caddy is down it prints
`run scripts/proxy/install.sh on atlas` and exits non-zero.

## Build & install

Requires a Rust toolchain with edition-2024 support and a Unix OS (the CLI uses
`exec()`; it does not build on Windows).

```bash
cargo install --path cli    # from the repo root — installs `atlas` into ~/.cargo/bin
```

Client-side you need `ssh` (a host alias matching `ATLAS_SSH_HOST` with
non-interactive key auth), and `git` for reading a project's `origin` remote.
Machine-level setup is covered in [docs/SETUP.md](../docs/SETUP.md).

## Configuration (environment)

Every value resolves in order: environment variable → the optional file
`~/.config/atlas/env` (plain `KEY=VALUE` lines, `#` comments, optional quotes) →
a generic built-in default. The file keeps personal addresses out of shell
profiles and the repo.

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_SSH_HOST` | `atlas` | ssh host (alias from `~/.ssh/config`) |
| `ATLAS_LAN_ADDR` | `192.168.1.100:22` | LAN ssh route, `host:port` (empty = skip) |
| `ATLAS_TAILNET_ADDR` | `atlas.your-tailnet.ts.net:22` | tailnet ssh route, `host:port` (empty = skip) |
| `ATLAS_WOL_MAC` | `aa:bb:cc:dd:ee:ff` | server NIC MAC for Wake-on-LAN (placeholder — `boot` warns until set) |
| `ATLAS_WOL_BROADCAST` | `192.168.1.255:9` | broadcast `addr:port` for the magic packet |
| `ATLAS_API_URL` | tailnet host + `:8787` | API server `host:port`, printed after `atlas api` |

The CLI relies on SSH `ControlMaster` multiplexing from `~/.ssh/config`
(`ControlPath ~/.ssh/cm/%r@%h:%p`, `ControlPersist`); it never sets conflicting
`-o ControlMaster` / `-S` flags of its own.

## Server prerequisites

- a systemd Linux with sshd on port 22 and Wake-on-LAN enabled — see
  [docs/SETUP.md](../docs/SETUP.md)
- this repository cloned at `~/atlas` with a reachable git remote
  (`build`/`dev` build images from it; `api` resets it to `origin/main`)
- Docker Engine, with the SSH user in the `docker` group
- `git`, and credentials for any private repo you build (the server clones over
  https, so `~/.git-credentials` or a credential helper)
- passwordless sudo for `poweroff`, `reboot`, `systemctl`, `install`, `tee`
  and `chown`, plus `tailscale serve` for `atlas dev`
- for `atlas dev --public`: the dev-subdomain proxy infra (host Caddy + a named
  Cloudflare Tunnel + a `*.lukaloehr.com` wildcard DNS record), installed once
  by [`scripts/proxy/`](../scripts/proxy/) and verified by `atlas doctor`
- a Rust toolchain sourced from `~/.cargo/env` (only needed for `atlas api`)
