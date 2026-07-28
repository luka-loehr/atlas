# atlas CLI

`atlas` is a single-binary Rust CLI (std only, zero dependencies) that controls
the atlas homelab server from a workstation. It wraps SSH for everyday access,
handles power management via Wake-on-LAN, offloads project builds and dev
servers to the server's Docker engine, and installs the companion control-plane
server [api](../api).

Everything goes over `ssh` and `rsync`. The binary is Unix-only — a bare
`atlas` replaces its own process with `ssh`, so you get a real interactive
session, not a wrapper.

## Commands

| command | what it does |
|---|---|
| `atlas` | interactive SSH session (execs `ssh -t <host>`) |
| `atlas <cmd ...>` | run any command on the server (`atlas nvidia-smi`) |
| `atlas boot` (`up`, `wake`) | send a Wake-on-LAN magic packet, wait until SSH answers (120 s timeout) |
| `atlas shutdown` (`off`, `poweroff`) | `sudo poweroff` over SSH, wait until port 22 is down (60 s) |
| `atlas restart` (`reboot`) | `sudo reboot`, wait for the box to go down and come back |
| `atlas status` | up/down, plus which route answered (LAN or tailnet) |
| `atlas build [args...]` | build the current project on the server in a builder image; extra args are appended to the build command |
| `atlas dev` | start the project's dev server on the server, published on the tailnet |
| `atlas dev --public` (`--tunnel`) | expose it through a public cloudflared quick tunnel instead |
| `atlas dev url` / `dev logs` / `dev stop` | print whichever URL is live / follow the dev-server logs / stop server, tunnel and serve config |
| `atlas secrets push [file]` | upload this project's env file to the server (never synced, `0600`) |
| `atlas secrets list` / `secrets rm` | which projects have one (never the contents) / drop this project's |
| `atlas api` | build + install the control-plane API server (systemd service) |
| `atlas api logs\|status\|stop\|restart` | manage the `atlas-api` service |
| `atlas help` | usage |

`boot`, `shutdown` and `restart` are synchronous — they poll until the machine
actually reaches the target state, so they chain in scripts
(`atlas boot && atlas build`).

Reachability is a 700 ms TCP probe of the configured `host:port` (22 by
default), first on `ATLAS_LAN_ADDR`, then on `ATLAS_TAILNET_ADDR` (either
route can be disabled by setting it empty).
Wake-on-LAN only works from inside the LAN; from elsewhere, wake the box via
your router's remote-access feature, then use the CLI over the tailnet.
`shutdown`/`restart` deliberately ignore ssh's exit code (the connection drops
mid-command) and trust the port probe instead.

## Build & install

Requires a Rust toolchain with edition-2024 support and a Unix OS (the CLI
uses `exec()`; it does not build on Windows).

```bash
cargo install --path cli    # from the repo root — installs `atlas` into ~/.cargo/bin
```

Client-side you also need `ssh` (with a host alias matching `ATLAS_SSH_HOST`
and non-interactive key auth) and `rsync`. Server-side prerequisites are
listed below; machine-level setup is covered in [docs/SETUP.md](../docs/SETUP.md).

## Configuration

Every value resolves in order: environment variable → the optional file
`~/.config/atlas/env` (plain `KEY=VALUE` lines, `#` comments, optional quotes)
→ a generic built-in default. The file keeps personal addresses out of shell
profiles and the repo.

| Variable | Default | Purpose |
|---|---|---|
| `ATLAS_SSH_HOST` | `atlas` | ssh/rsync host (alias from `~/.ssh/config`) |
| `ATLAS_LAN_ADDR` | `192.168.1.100:22` | LAN ssh route, `host:port` (empty = skip this route) |
| `ATLAS_TAILNET_ADDR` | `atlas.your-tailnet.ts.net:22` | tailnet ssh route, `host:port` (empty = skip) |
| `ATLAS_WOL_MAC` | `aa:bb:cc:dd:ee:ff` | server NIC MAC for Wake-on-LAN (placeholder — `boot` warns until you set the real one) |
| `ATLAS_WOL_BROADCAST` | `192.168.1.255:9` | broadcast `addr:port` for the magic packet |
| `ATLAS_API_URL` | tailnet host + `:8787` | API server `host:port`, printed after `atlas api` |

## Remote builds (`atlas build`)

Per-project configuration lives in a `.atlas-build.toml`; the CLI walks up
from the current directory until it finds one, and the directory containing it
is the sync root. The file is a flat `key = value` list (not full TOML) —
quoted or bare values, `#` comments.

```toml
name      = "my-app"         # required — remote dir + container names (A-Za-z0-9._-)
image     = "universal"      # required — builder key: universal | mobile
dir       = "."              # subdir (relative to this file) the build runs in
build     = "npm run build"  # build command (required for `atlas build`)
dev       = "npm run dev"    # dev-server command (required for `atlas dev`)
install   = "npm ci"         # dependency install for `atlas dev` (default: detect from the lockfile)
port      = 3000             # port the dev server listens on (default 3000)
artifacts = "dist"           # whitespace-separated paths to copy back (required for `atlas build`)
```

Both keys resolve to targets of the single [`builder/universal`](../builder)
Dockerfile, so they share layers: `universal` → `atlas-universal-builder` for
`build` and `atlas-universal-dev` (the one with `cloudflared` in it) for `dev`,
`mobile` → `atlas-universal-mobile` for both. Any other value is rejected.

`atlas build` then:

1. wakes the server if it is asleep;
2. ensures the builder image exists on the server — if missing, it is built
   from [`builder/universal`](../builder) in the server's `~/atlas` checkout
   (after a `git pull --ff-only`);
3. rsyncs the project to `~/atlas-builds/<name>` on the server, excluding
   `.git`, `target`, `node_modules`, `.next`, `build`;
4. runs the build command in the container — as root, with a per-image cache
   volume (`~/atlas-builds/.cache-<image>` mounted at `/cache`, wired up for
   cargo/npm/pub/gradle so later builds start warm), then chowns the tree back
   to the SSH user;
5. rsyncs each `artifacts` path back into the local project. This uses
   `--delete`: local artifact directories are replaced by the server's copy.

`name`, `image`, `dir` and `artifacts` end up inside remote shell commands, so
the CLI enforces a conservative charset (`A-Za-z0-9._-`, first character
alphanumeric for `name`/`image`); paths must be relative (no leading `/` or
`-`) and must not contain `..` components.

## Remote dev servers (`atlas dev`)

`atlas dev` syncs the project like `build`, then starts `atlas-dev-<name>`:
the install step for the project's lockfile followed by `<dev>`, with
`--network host`, `HOST=0.0.0.0` and `PORT=<port>`.

By default the dev server is published **on the tailnet only**, via
`tailscale serve` on the server:

```
https://<tailnet host>:<port>      # e.g. https://atlas.your-tailnet.ts.net:20841
```

The host comes from `ATLAS_TAILNET_ADDR`; the port is derived from the project
`name` (FNV-1a, band 20000–20999), so it is the same on every restart and two
projects do not collide. That matters for everything that has to know the URL
up front — OAuth redirect URIs, webhook targets, Next.js `allowedDevOrigins`.
It is a port and not a path prefix because frameworks emit absolute asset URLs
(`/_next/static/…`) that a prefix would break. `tailscaled` runs on the host,
not in the container, so the CLI sets this over SSH with `sudo tailscale serve`
(passwordless sudo, same as the post-build `chown`). No wait loop is needed:
the URL is computed, not discovered — it answers 502 until the dev server is
actually up (`atlas dev logs`).

`atlas dev --public` (or `--tunnel`) skips that and starts a second container,
`atlas-tunnel-<name>`, running a `cloudflared` quick tunnel (no Cloudflare
account needed) against `http://localhost:<port>`. The CLI polls its logs for
up to 60 s and prints the `https://….trycloudflare.com` URL. That URL is
public, unauthenticated and random again on every start — hence opt-in. If
`ATLAS_TAILNET_ADDR` is unset or still the placeholder, `atlas dev` says so and
falls back to the tunnel.

Re-running `atlas dev` re-syncs and restarts everything, including the serve
config, so switching between the two modes is just the flag. The synced source
lives at `~/atlas-builds/<name>` on the server if you want to edit it in place
(a later re-sync overwrites those edits).

Security note: `--network host` opens the dev port on every server interface
regardless of mode. Containers use `--restart unless-stopped` and the serve
config is persistent host state — both survive reboots until `atlas dev stop`,
which removes the containers *and* turns the serve port off.

## Project secrets (`atlas secrets`)

Env files are deliberately excluded from the build sync (`.env`, `.env.*`;
`.env.example` and `.env.sample` are the two exceptions). Everything under
`~/atlas-builds` is an rsync mirror of the workstation, so a secret parked
there would be rewritten by every sync — or, being excluded from it, go
silently stale.

`atlas secrets push [file]` streams the file (default `.env.local`, else
`.env`) over ssh **stdin** — the contents never appear in a shell argument
(`/proc/*/cmdline` is world-readable) and never touch an intermediate file. It
lands as `~/atlas-secrets/<name>.env`, mode `0600` in a `0700` directory,
outside the synced tree. `atlas build` and `atlas dev` then pass it to
`docker run --env-file` at run time, so the values are environment variables in
the container rather than a file on disk. If a project has a local env file but
nothing in the store, both commands say so before starting.

`atlas secrets list` prints name, size and mtime — never the contents.
`atlas secrets rm` drops the current project's file.

## Control-plane API (`atlas api`)

Bare `atlas api` installs or updates the [api](../api) server on the machine:
it runs `git fetch` + `git reset --hard origin/main` in the server's `~/atlas`
checkout (this discards any local changes there), builds `api/` with the
server's Rust toolchain, installs the binary to `/usr/local/bin/atlas-api`,
installs `atlas-api.service`, and enables + restarts it. Afterwards the metrics
endpoint is `http://<ATLAS_API_URL>/api/metrics` (port 8787 by default).

The predecessor `atlas-agent` unit is disabled and removed as part of the same
run, but only *after* the new binary and unit are in place — a build that fails
on the server must not leave the box with no control plane, since this is the
same SSH path that manages its power. An existing `/etc/atlas-agent.env` is
moved to `/etc/atlas-api.env` in the same step and its `ATLAS_AGENT_*`
variables are rewritten to `ATLAS_API_*`; without that the server would come up
token-less and read-only, which fails silently.

`api logs` follows `journalctl -u atlas-api`. `api stop` and `api restart` map
to the corresponding `sudo systemctl` calls and exit non-zero if the call
failed. `api status` prints the first 12 lines of `systemctl status` and does
not treat an inactive unit as an error — that is an answer, not a failure.

## Server prerequisites

- a systemd Linux with sshd on port 22 and Wake-on-LAN enabled — see
  [docs/SETUP.md](../docs/SETUP.md)
- this repository cloned at `~/atlas` with a reachable git remote
  (`build`/`dev` build images from it; `api` resets it to `origin/main`)
- Docker Engine, with the SSH user in the `docker` group
- `rsync`
- passwordless sudo for `poweroff`, `reboot`, `systemctl`, `install`, `cp`,
  `mv`, `rm` and `chown`, plus `tailscale serve` for `atlas dev`
- a Rust toolchain sourced from `~/.cargo/env` (only needed for `atlas api`)
